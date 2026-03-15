# Flint

A lightweight KVM-based microVMM written in Zig, designed for fast AI agent code execution sandboxes. Think Firecracker, but in Zig — zero external dependencies, pure Linux syscalls.

## What it does

Flint boots a Linux microVM in 84ms (with a minimal kernel) or restores one from a snapshot in ~10ms. Each VM is a fully isolated sandbox where AI agents can execute arbitrary code, read/write files, and communicate with the host over vsock.

```
AI Agent
  |  HTTP (Unix socket)
  v
Flint post-boot API (/sandbox/exec, /sandbox/write, /sandbox/read)
  |  vsock (length-prefixed JSON)
  v
flint-agent (inside VM) --> fork+exec --> user command
```

## Features

- **Fast boot**: ~84ms to userspace with a minimal kernel (or ~650ms with a stock distro kernel)
- **Snapshot restore**: Save/restore full VM state in ~10ms (demand-paged via MAP_PRIVATE mmap)
- **VM pool**: Pre-warm pool of snapshot-restored VMs with acquire/release API, per-VM disk CoW isolation (FICLONE on btrfs/XFS, read/write fallback), and HTTP health checks
- **Sandbox API**: Execute commands, upload/download files inside VMs via REST, graceful shutdown
- **Epoll-based I/O**: Device fd polling via epoll instead of blind polling, vsock write backpressure buffering
- **virtio devices**: virtio-blk (disk), virtio-net (TAP networking), virtio-vsock (host communication)
- **Security**: KVM hardware isolation, seccomp BPF (44 syscall whitelist with argument filtering), mount namespaces, pivot_root, cgroups v2, privilege drop, CPUID filtering
- **Zero dependencies**: Pure Zig + Linux syscalls, no libc runtime in the guest agent

## Building

Requires Zig 0.16+ (nightly) and Linux with KVM support.

```bash
zig build              # builds flint (host VMM) and flint-agent (guest daemon)
zig build test         # run unit tests
zig build integration-test  # run integration tests (requires /dev/kvm + kernel at /tmp/vmlinuz-minimal)
```

## Usage

### Boot a VM via CLI

```bash
# Direct boot with kernel + initrd
flint bzImage initrd.cpio.gz

# With disk and networking
flint bzImage initrd.cpio.gz --disk rootfs.img --tap tap0

# With vsock for host<->guest communication
flint bzImage initrd.cpio.gz --vsock-cid 3 --vsock-uds /tmp/flint-vsock
```

### Boot via REST API

```bash
# Start API server
flint --api-sock /tmp/flint.sock

# Configure and boot
curl -X PUT --unix-socket /tmp/flint.sock http://localhost/boot-source \
  -d '{"kernel_image_path": "bzImage", "initrd_path": "initrd.cpio.gz"}'
curl -X PUT --unix-socket /tmp/flint.sock http://localhost/actions \
  -d '{"action_type": "InstanceStart"}'
```

### Snapshot and restore

```bash
# Pause, snapshot, resume
curl -X PATCH --unix-socket /tmp/flint.sock http://localhost/vm \
  -d '{"state": "Paused"}'
curl -X PUT --unix-socket /tmp/flint.sock http://localhost/snapshot/create \
  -d '{"snapshot_path": "snap.vmstate", "mem_file_path": "snap.mem"}'

# Restore from snapshot (~10ms)
flint --restore --vmstate-path snap.vmstate --mem-path snap.mem --api-sock /tmp/flint.sock
```

### VM pool (warm start)

```bash
# Start a pool of 4 pre-restored VMs (with per-VM disk isolation)
flint pool --vmstate-path snap.vmstate --mem-path snap.mem --disk rootfs.img \
  --pool-size 4 --pool-sock /tmp/pool.sock

# Acquire a VM, use it, release it
curl -X POST --unix-socket /tmp/pool.sock http://localhost/pool/acquire \
  -d '{"timeout_ms": 300000}'
# {"id":0,"api_sock":"/tmp/flint-pool-vm-0.sock"}
# VM auto-expires after 5 minutes if not released

curl -X POST --unix-socket /tmp/pool.sock http://localhost/pool/release \
  -d '{"id": 0}'
```

### Sandbox API (code execution)

When vsock is configured and flint-agent is running inside the VM:

```bash
# Execute a command
curl -X POST --unix-socket /tmp/flint.sock http://localhost/sandbox/exec \
  -d '{"cmd": "echo hello world", "timeout": 30}'
# {"ok":true,"exit_code":0,"stdout":"aGVsbG8gd29ybGQK","stderr":""}

# Write a file (base64-encoded data)
curl -X POST --unix-socket /tmp/flint.sock http://localhost/sandbox/write \
  -d '{"path": "/tmp/code.py", "data": "cHJpbnQoImhpIik=", "mode": 493}'

# Read a file
curl -X POST --unix-socket /tmp/flint.sock http://localhost/sandbox/read \
  -d '{"path": "/tmp/code.py"}'

# Graceful shutdown (sends poweroff to guest agent, waits up to 5s)
curl -X PUT --unix-socket /tmp/flint.sock http://localhost/actions \
  -d '{"action_type": "SendCtrlAltDel"}'
```

stdout/stderr in exec responses are base64-encoded.

## Architecture

See [docs/DESIGN.md](docs/DESIGN.md) for full architecture, design decisions, and build phase history.

## Security model

Flint uses defense in depth:

1. **KVM hardware isolation** -- guest runs in a separate address space enforced by CPU virtualization
2. **Seccomp BPF** -- VMM process limited to 44 syscalls with argument-level filtering (blocks CLONE_NEWUSER, AF_INET, PROT_EXEC)
3. **Mount namespace + pivot_root** -- VMM sees only its jail directory
4. **Cgroups v2** -- CPU and memory limits per VM
5. **Privilege drop** -- VMM drops to unprivileged UID/GID after setup
6. **Process-per-VM** -- pool VMs are separate processes, no shared mutable state
7. **CPUID filtering** -- hides host features the VMM doesn't emulate (CET, SGX, WAITPKG)

## Status

The core VMM works end-to-end: boot, snapshot/restore, pool, sandbox API, security hardening. Built with AI agents and human architecture/review. Not hardened for production use — see [docs/DESIGN.md](docs/DESIGN.md) for what's done and what remains.
