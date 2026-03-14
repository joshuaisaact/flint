# Flint

A lightweight KVM-based microVMM written in Zig, designed for fast AI agent code execution sandboxes.

## What it does

Flint boots a Linux microVM in under a second, or restores one from a snapshot in under 50ms. Each VM is a fully isolated sandbox where AI agents can execute arbitrary code, read/write files, and communicate with the host over vsock.

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

- **Fast boot**: Linux 6.x to userspace in ~650ms via direct boot protocol (bzImage + initrd)
- **Snapshot restore**: Save/restore full VM state in ~10ms (demand-paged via MAP_PRIVATE mmap)
- **VM pool**: Pre-warm pool of snapshot-restored VMs with acquire/release API and HTTP health checks
- **Sandbox API**: Execute commands, upload/download files inside VMs via REST, graceful shutdown
- **virtio devices**: virtio-blk (disk), virtio-net (TAP networking), virtio-vsock (host communication)
- **Security**: KVM hardware isolation, seccomp BPF (44 syscall whitelist with argument filtering), mount namespaces, pivot_root, cgroups v2, privilege drop, CPUID filtering
- **Zero dependencies**: Pure Zig + Linux syscalls, no libc runtime in the guest agent

## Building

Requires Zig 0.16+ and Linux with KVM support.

```bash
zig build              # builds flint (host VMM) and flint-agent (guest daemon)
zig build test         # run unit tests (26 tests)
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

# Restore from snapshot
flint --restore --vmstate-path snap.vmstate --mem-path snap.mem --api-sock /tmp/flint.sock
```

### VM pool (warm start)

```bash
# Start a pool of 4 pre-restored VMs
flint pool --vmstate-path snap.vmstate --mem-path snap.mem \
  --pool-size 4 --pool-sock /tmp/pool.sock

# Acquire a VM, use it, release it
curl -X POST --unix-socket /tmp/pool.sock http://localhost/pool/acquire
# {"id":0,"api_sock":"/tmp/flint-pool-vm-0.sock"}

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
```

stdout/stderr in exec responses are base64-encoded.

```bash
# Graceful shutdown (sends poweroff to guest agent, waits up to 5s)
curl -X PUT --unix-socket /tmp/flint.sock http://localhost/actions \
  -d '{"action_type": "SendCtrlAltDel"}'
```

## Architecture

See [DESIGN.md](DESIGN.md) for full architecture, design decisions, and build phase history.

## Security model

Flint uses defense in depth:

1. **KVM hardware isolation** -- guest runs in a separate address space enforced by CPU virtualization
2. **Seccomp BPF** -- VMM process limited to 44 syscalls with argument-level filtering
3. **Mount namespace + pivot_root** -- VMM sees only its jail directory
4. **Cgroups v2** -- CPU and memory limits per VM
5. **Privilege drop** -- VMM drops to unprivileged UID/GID after setup
6. **Process-per-VM** -- pool VMs are separate processes, no shared mutable state

## Status

This is a learning project. The core VMM works end-to-end (boot, snapshot/restore, pool, sandbox API), but it has not been hardened for production use. See DESIGN.md Phase 4 for what's done and what remains.
