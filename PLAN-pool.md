# VM Pool / Warm Start Plan

## Goal

Pre-restore a pool of VMs from a snapshot so that acquiring a sandbox is
near-instant (~5ms mmap + device re-open) instead of paying full boot cost
(~1s). The pool manager replenishes automatically as VMs are consumed.

## Architecture

**Process-per-VM** (industry consensus: Firecracker, Lambda, E2B all do this).
Each VM is a separate Flint process with its own seccomp/jail/cgroup. A pool
manager process orchestrates them.

```
flint pool --snapshot vmstate --mem snapshot.mem \
           --pool-size 4 --pool-sock /tmp/pool.sock \
           [--disk disk.img] [--tap tap%d] [--vsock-uds /tmp/vsock]
           [--jail /srv/jail --jail-uid 1000 --jail-gid 1000]

Pool manager (parent)                    Clients
  |                                        |
  |--- spawn ---> flint --restore          |
  |               --api-sock /tmp/vm-0     |
  |                                        |
  |--- spawn ---> flint --restore          |
  |               --api-sock /tmp/vm-1     |
  |                                        |
  |  POST /acquire  <-----------------    |
  |  { "api_sock": "/tmp/vm-0" }  ------> |
  |                                        |
  |  (client talks directly to vm-0)       |
  |                                        |
  |  POST /release {id: 0}  <-----------  |
  |  kill vm-0, spawn replacement          |
```

## Pool manager API (Unix socket, HTTP/1.1)

```
POST /pool/acquire
  → 200 { "id": "vm-0", "api_sock": "/tmp/vm-0.sock" }
  → 503 { "error": "pool exhausted" }

POST /pool/release
  { "id": "vm-0" }
  → 200 {}

GET /pool/status
  → 200 { "ready": 3, "in_use": 1, "total": 4, "replenishing": 0 }

PUT /pool/config
  { "pool_size": 8 }
  → 200 {}
```

After acquire, the client talks directly to the VM's existing API socket
(GET /vm, PATCH /vm, PUT /snapshot/create, etc). The pool manager doesn't
proxy — it just tracks ownership and lifecycle.

## VM lifecycle in pool

```
                spawn
EMPTY ───────────────> STARTING ──────────> READY
                         |                    |
                     (boot fail)          acquire
                         |                    |
                         v                    v
                       FAILED              IN_USE
                                              |
                                          release
                                              |
                                              v
                                           KILLED ──> (respawn → STARTING)
```

- **STARTING**: Flint child process launched, restoring from snapshot
- **READY**: VM running, API socket responsive, waiting for acquire
- **IN_USE**: Handed to a client
- **KILLED**: Process killed after release (no recycling — clean security boundary)

## Implementation

### New file: `src/pool.zig`

Pool manager state and logic. Runs as a mode of the flint binary
(`flint pool ...`), not a separate binary.

```zig
const VmSlot = struct {
    id: u16,
    state: enum { empty, starting, ready, in_use, failed },
    pid: ?linux.pid_t,
    api_sock_path: [128]u8,
    api_sock_len: u8,
};

const Pool = struct {
    slots: [MAX_POOL_SIZE]VmSlot,
    pool_size: u16,

    // Snapshot config (shared across all VMs)
    vmstate_path: [*:0]const u8,
    mem_path: [*:0]const u8,
    disk_path: ?[*:0]const u8,
    // ... other device paths

    fn init(config) Pool
    fn acquire() ?*VmSlot        // find READY slot, mark IN_USE
    fn release(id: u16) void     // kill process, mark EMPTY, trigger replenish
    fn replenish() void          // spawn VMs for EMPTY slots up to pool_size
    fn spawnVm(slot: *VmSlot) !void  // fork+exec flint --restore
    fn reapChildren() void       // waitpid(WNOHANG), handle unexpected exits
    fn healthCheck(slot) bool    // connect to API sock, GET /vm
};
```

### Child process spawning

Use `fork()` + `execve()` via raw linux syscalls (consistent with codebase).
Each child runs: `flint --restore --vmstate-path X --mem-path Y --api-sock /tmp/pool-vm-{id}.sock [--disk ...] [--jail ...]`

The pool manager does NOT jail itself — each child process sets up its own
jail via the existing `--jail` flag.

### Replenishment

Background thread (or main loop poll) checks for EMPTY slots and spawns
replacements. Two strategies:

1. **Eager** (default): Always maintain pool_size READY VMs. As soon as one
   is released/killed, start a replacement. Simple, predictable.

2. **Lazy**: Only replenish when pool drops below a low-water mark. Saves
   resources when load is low. Configurable later.

Start with eager — it's simpler and the snapshot restore is so fast (~5ms
mmap) that the cost of pre-warming is negligible.

### Health checking

After spawning a child, the pool manager needs to know when it's READY.
Options:

1. **Poll API socket**: Try `GET /vm` until it responds. Simple, works with
   existing infrastructure.
2. **Child signals parent**: Child writes a byte to a pipe when ready.
   Lower latency but more plumbing.

Start with option 1 — poll with short interval (10ms). The restore path
takes ~5-20ms, so a few polls is fine.

### TAP device naming

Each VM needs its own TAP device. Use a pattern like `--tap tap%d` where
`%d` is replaced with the slot ID. The pool manager generates the name
per-slot: `tap0`, `tap1`, etc.

Or: if networking isn't needed for the sandbox use case (vsock is the
primary communication channel), TAP can be omitted entirely.

### Vsock UDS paths

Each VM needs unique vsock UDS paths. Use `--vsock-uds /tmp/pool-vm-{id}-vsock`
so guest connections to CID 2 port P land on `/tmp/pool-vm-0-vsock_P` etc.

### Process cleanup

- On release: `kill(pid, SIGKILL)` + `waitpid(pid)` + unlink API socket
- On pool shutdown: kill all children, wait, unlink sockets
- SIGCHLD handler or periodic `waitpid(WNOHANG)` reaps unexpected exits
  and marks slots as FAILED → EMPTY for replenishment

## CLI interface

```
flint pool \
  --vmstate-path snapshot.vmstate \
  --mem-path snapshot.mem \
  --pool-size 4 \
  --pool-sock /tmp/pool.sock \
  [--disk disk.img] \
  [--tap tap%d] \
  [--vsock-cid 3] \
  [--vsock-uds /tmp/vm-%d-vsock] \
  [--jail /srv/jail --jail-uid 1000 --jail-gid 1000] \
  [--jail-cgroup flint-vm-%d]
```

## Implementation order

1. **VmSlot + Pool struct** — state management, acquire/release logic
2. **spawnVm** — fork+exec child Flint process in restore mode
3. **reapChildren** — waitpid loop for cleanup
4. **Health check polling** — detect when child is READY
5. **Pool API server** — HTTP on Unix socket (reuse api.zig patterns)
6. **CLI integration** — `pool` subcommand in main.zig
7. **Replenishment thread** — background spawning of replacements
8. **Tests** — pool state machine, acquire/release lifecycle

## Gotchas

- `fork()` is available via `linux.fork()` (raw syscall). `execve()` via
  `linux.execve()`. No need for std.process.Child.
- After fork, child inherits all fds — pool manager should close unnecessary
  fds before exec (or use O_CLOEXEC everywhere, which we already do).
- SIGCHLD can interrupt `accept()` and other blocking calls. Use SA_RESTART
  or handle EINTR in the API server loop.
- Each child's `--api-sock` path must be unique and predictable so the pool
  manager can connect for health checks.
- The snapshot memory file is shared (MAP_PRIVATE COW per child) — it must
  remain on disk for the pool's lifetime. Don't unlink it.
- Pool manager runs as root (needs to spawn jailed children). It should
  drop privileges for its own API socket handling after setting up signal
  handlers.
- `waitpid` with WNOHANG: check all children periodically, not just on
  SIGCHLD (signals can coalesce).

## Not in scope (yet)

- Dynamic pool resizing based on demand
- Multiple snapshot templates (different OS/configs)
- Metrics / telemetry for pool utilization
- Graceful drain (wait for IN_USE VMs before shutdown)
- userfaultfd for compressed memory restore
