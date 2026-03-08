# Seccomp + Jailer Implementation Plan

## Goal
Lock down the VMM process so a KVM escape still can't reach the host. In-process `--jail` flag (~150-200 lines), not a separate binary.

## Design Decisions
1. **In-process jailer** — a `--jail` flag that does setup before dropping privileges and continuing with normal VMM startup. No separate binary (Firecracker uses one for organizational reasons, not security ones — pivot_root is equally strong either way).
2. **Cgroups v2 only** — no v1 support. v1 is legacy. Just filesystem writes.
3. **Seccomp BPF with KILL_PROCESS** — not ERRNO, not LOG. Violations = instant death. Use LOG mode during development/audit only.
4. **No user namespaces** — require real root for setup (like Firecracker), then drop to real unprivileged UID/GID. User namespaces add complexity and have a history of privilege escalation bugs.
5. **No daemonization** — let systemd or the caller handle process management.

## Jail Setup Sequence

Must happen in this order (each step requires privileges from the previous):

```
1. close_range(3, MAX, 0)           — close inherited FDs (prevent leaks)
2. unshare(CLONE_NEWNS | CLONE_NEWPID)  — new mount + PID namespaces
3. mount(NULL, "/", NULL, MS_SLAVE|MS_REC, NULL)  — stop mount propagation
4. mount(jail_dir, jail_dir, NULL, MS_BIND|MS_REC, NULL)  — bind mount jail
5. chdir(jail_dir)
6. mkdir("old_root")
7. pivot_root(".", "old_root")       — swap filesystem roots
8. chdir("/")
9. umount2("old_root", MNT_DETACH)  — detach host filesystem
10. rmdir("old_root")
11. mknod("/dev/kvm", ...)           — create device node inside jail
12. mknod("/dev/net/tun", ...)       — only if networking requested
13. Write cgroup limits              — memory.max, cpu.max, pids.max
14. setgid(gid) + setuid(uid)        — drop privileges (LAST before seccomp)
15. Install seccomp BPF filter        — point of no return
16. Continue with normal VMM startup  — open /dev/kvm, etc.
```

Seccomp is applied last because the setup steps above require privileged syscalls (mount, mknod, setuid) that the filter would block.

## CLI Interface

```
flint --jail <dir> --jail-uid <uid> --jail-gid <gid> [--jail-cgroup <name>] <kernel> [initrd]
```

- `--jail <dir>` — path to an empty directory that becomes the jail root. Must contain the kernel, initrd, and disk images (or they get bind-mounted in).
- `--jail-uid <uid>` / `--jail-gid <gid>` — unprivileged user to drop to.
- `--jail-cgroup <name>` — optional cgroup under `/sys/fs/cgroup/` for resource limits.

API mode: `--jail` works with `--api-sock` — the socket path is relative to the jail root.

## Seccomp BPF Filter

### Approach
Hand-coded BPF filter array. Zig 0.16 has `std.os.linux.seccomp` constants (RET, MODE, data struct, AUDIT.ARCH) but NOT sock_filter/sock_fprog/BPF opcodes — we define those ourselves.

### Filter structure
```
1. Load arch → verify x86_64, else KILL_PROCESS
2. Load syscall nr
3. Jump table: if nr == allowed_syscall[i], jump to ALLOW
4. Default: KILL_PROCESS
```

### Syscall whitelist (minimum viable)

Based on strace audit of Flint + Firecracker's filter + Zig 0.16 runtime needs:

#### Core VMM (always needed)
```
read            (0)    — kvm_run fd, sockets, files
write           (1)    — serial console (stdout), sockets, files
close           (3)    — fd cleanup
mmap            (9)    — guest memory, kvm_run mapping, thread stacks
mprotect        (10)   — thread stack guard pages
munmap          (11)   — cleanup
brk             (12)   — Zig allocator may use for small allocs
ioctl           (16)   — ALL KVM interaction, socket FIONBIO, TAP setup
lseek           (8)    — disk image
openat          (257)  — open files (Zig uses openat, not open)
fcntl           (72)   — O_NONBLOCK, F_GETFL/F_SETFL
```

#### Virtio-blk
```
pread64         (17)   — disk reads at offset
pwrite64        (18)   — disk writes at offset
fsync           (74)   — flush to storage
```

#### Virtio-net
```
readv           (19)   — TAP device reads
writev          (20)   — TAP device writes
```

#### Networking / API socket
```
socket          (41)   — create Unix socket
bind            (49)   — bind API socket
listen          (50)   — listen on API socket
accept4         (288)  — accept connections
connect         (42)   — vsock UDS connect
sendto          (44)   — socket write
recvfrom        (45)   — socket read
```

#### Threading (API server thread)
```
clone           (56)   — spawn thread
futex           (202)  — ALL synchronization (mutex, condvar, thread join)
set_tid_address (218)  — clone setup for thread exit notification
arch_prctl      (158)  — TLS (thread-local storage) on x86_64
sigaltstack     (131)  — Zig sets up alt signal stack per thread
sched_yield     (24)   — lock contention, spinLoopHint
```

#### Signal handling
```
rt_sigaction    (13)   — install signal handlers
rt_sigprocmask  (14)   — block/unblock signals
rt_sigreturn    (15)   — return from signal handler (REQUIRED or infinite loop)
```

#### Process lifecycle
```
exit            (60)   — thread exit
exit_group      (231)  — process exit
restart_syscall (219)  — kernel injects this after interrupted sleeps
gettid          (186)  — thread ID for logging
```

#### Snapshot save
```
ftruncate       (77)   — create snapshot file
newfstatat      (262)  — file metadata
```

#### Clock
```
clock_gettime   (228)  — timestamps for logging
```

**Total: ~39 syscalls.** Firecracker allows ~48 across 3 thread types.

### Development/audit mode
Use `SECCOMP_RET_LOG` instead of `KILL_PROCESS` as default action. Run full test suite, check `dmesg | grep seccomp` for any blocked syscalls we missed. Then switch to KILL_PROCESS.

## Zig Implementation Details

### BPF structs (not in stdlib, must define)
```zig
const SockFilter = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

const SockFprog = extern struct {
    len: u16,
    filter: [*]const SockFilter,
};
```

### BPF opcodes (not in stdlib)
```zig
const BPF_LD  = 0x00;  const BPF_JMP = 0x05;  const BPF_RET = 0x06;
const BPF_W   = 0x00;  const BPF_ABS = 0x20;  const BPF_K   = 0x00;
const BPF_JEQ = 0x10;  const BPF_JGE = 0x30;
```

### Stdlib available
- `std.os.linux.seccomp(SET_MODE_FILTER, 0, &prog)` — install filter
- `std.os.linux.prctl(PR.SET_NO_NEW_PRIVS, 1, 0, 0, 0)` — required before filter
- `std.os.linux.seccomp.RET.ALLOW`, `.KILL_PROCESS`, `.LOG`
- `std.os.linux.seccomp.data` — seccomp_data struct (nr, arch, args fields)
- `std.os.linux.AUDIT.ARCH.X86_64` — arch constant for filter
- `std.os.linux.CLONE.NEWNS`, `.NEWPID` — namespace flags
- `std.os.linux.unshare(flags)` — create namespaces
- `std.os.linux.pivot_root(new, old)` — swap filesystem roots
- `std.os.linux.mount(src, target, fs, flags, data)` — mount
- `std.os.linux.umount2(target, flags)` — unmount
- `std.os.linux.MS.BIND`, `.REC`, `.SLAVE` — mount flags
- `std.os.linux.MNT.DETACH` — unmount flag

### Error checking pattern
All linux.* syscall wrappers return `usize`. Check via:
```zig
const rc = linux.unshare(flags);
const signed: isize = @bitCast(rc);
if (signed < 0) return error.UnshareFailed;
```

## Implementation Order

### Step 1: seccomp.zig (new file)
BPF structs, opcodes, filter builder, `installFilter()`. Testable in isolation — install a filter that blocks a known-bad syscall, verify the process survives allowed calls.

### Step 2: jail.zig (new file)
`setup()` function implementing the 16-step sequence above. Takes jail dir, uid, gid, cgroup name. Pure syscall sequence, no complex logic.

### Step 3: CLI integration (main.zig)
Parse `--jail`, `--jail-uid`, `--jail-gid`, `--jail-cgroup`. Call `jail.setup()` before any KVM operations. Paths in the jail are relative to jail root after pivot_root.

### Step 4: Audit with strace + LOG mode
Run full boot + API + snapshot cycle under strace to verify whitelist. Use SECCOMP_RET_LOG to catch any missing syscalls without crashing.

### Step 5: Tests
- Seccomp filter blocks disallowed syscall (e.g., ptrace)
- Seccomp filter allows required syscalls
- Filter rejects wrong architecture

## Files to Create/Modify

| File | Action | What |
|------|--------|------|
| `src/seccomp.zig` | CREATE | BPF filter builder + installer |
| `src/jail.zig` | CREATE | Namespace/pivot_root/cgroup/privilege drop |
| `src/main.zig` | MODIFY | --jail flags, call jail.setup() early in startup |

## Gotchas
- `pivot_root` requires new_root to be a mount point — bind-mount it on itself first
- `mknod` requires CAP_MKNOD — must happen before dropping privileges
- `close_range(3, MAX, 0)` — Zig might not have a wrapper, use raw `linux.syscall3`
- Cgroup writes must happen before pivot_root (need access to `/sys/fs/cgroup`)
- `PR_SET_NO_NEW_PRIVS` must be set before installing seccomp filter (or be root)
- Seccomp filters survive fork/exec — once installed, can't be removed
- `restart_syscall` (219) is injected by the kernel, not called by userspace — must be in whitelist or interrupted sleeps cause SIGSYS
- `rt_sigreturn` (15) — without it, any signal delivery causes infinite fault loop
- CLONE_NEWPID only affects children (not the calling process) — first fork after unshare gets PID 1
- Device nodes need correct major/minor: /dev/kvm is 10,232; /dev/net/tun is 10,200
