# Sandbox Agent Daemon Plan

## Goal

Enable AI agents to execute code inside Flint VMs. A small daemon
runs inside the guest, connects to the host over vsock, and executes
commands on demand.

## Architecture

```
AI Agent (client)
    |
    | HTTP (Unix socket)
    v
Per-VM API server (host, Flint post-boot API)
    |
    | vsock (guest→host, UDS relay)
    v
flint-agent (guest daemon, in initrd)
    |
    | fork+exec
    v
User command (inside VM)
```

## vsock Connection Model (Firecracker-style, guest-initiates)

1. Host creates Unix listener on `{vsock_uds}_1024` BEFORE VM boots
2. Guest daemon starts at boot, connects to vsock CID 2, port 1024
3. VMM relays: guest vsock → host UDS `{vsock_uds}_1024`
4. Host accepts the connection — persistent control channel established
5. Host sends commands, daemon executes, sends results back

## Protocol

Length-prefixed JSON over the vsock connection. Each message:
- 4 bytes: little-endian u32 payload length
- N bytes: JSON payload

### Commands

**exec** — run a command, return output after exit
```json
→ {"id":1,"method":"exec","cmd":"/bin/sh","args":["-c","echo hello"],"timeout":30}
← {"id":1,"ok":true,"exit_code":0,"stdout":"aGVsbG8K","stderr":""}
```
stdout/stderr are base64-encoded (handles binary output).
timeout is seconds, enforced guest-side via alarm/kill.

**write_file** — write data to a file in the guest
```json
→ {"id":2,"method":"write_file","path":"/tmp/code.py","data":"cHJpbnQoJ2hpJyk=","mode":493}
← {"id":2,"ok":true}
```
data is base64-encoded. mode is octal permissions as decimal.

**read_file** — read a file from the guest
```json
→ {"id":3,"method":"read_file","path":"/tmp/output.txt"}
← {"id":3,"ok":true,"data":"cmVzdWx0Cg=="}
```

**ping** — health check
```json
→ {"id":4,"method":"ping"}
← {"id":4,"ok":true}
```

### Error response
```json
← {"id":1,"ok":false,"error":"command not found"}
```

## Guest Daemon (flint-agent)

Separate Zig binary, compiled static for x86_64-linux. Added to the
initrd and started from init script.

~300 lines of Zig:
- Open AF_VSOCK socket, connect to CID 2 port 1024
- Read loop: read 4-byte length, read JSON payload, dispatch
- exec: fork+exec with pipe for stdout/stderr, waitpid, base64 encode
- write_file/read_file: standard file I/O
- Timeouts: alarm() or kill child after N seconds

### Building

Add as a second exe in build.zig. Compile with `-target x86_64-linux`
and `-OReleaseSafe` for small binary size.

### Initrd Integration

Repack the existing initrd.cpio.gz with flint-agent added:
```bash
mkdir initrd-work && cd initrd-work
zcat ../initrd.cpio.gz | cpio -idm
cp ../zig-out/bin/flint-agent ./usr/bin/
# Add to init script: /usr/bin/flint-agent &
find . | cpio -o -H newc | gzip > ../initrd.cpio.gz
```

## Host-Side Sandbox API

New endpoints on the per-VM post-boot API:

```
POST /sandbox/exec    {"cmd": "...", "timeout": 30}
  → 200 {"ok":true, "exit_code": 0, "stdout": "base64...", "stderr": "base64..."}

POST /sandbox/write   {"path": "...", "data": "base64...", "mode": 493}
  → 200 {"ok":true}

POST /sandbox/read    {"path": "..."}
  → 200 {"ok":true, "data": "base64..."}
```

The host-side API is a thin proxy: it injects the "method" field and
forwards the agent's JSON response directly. stdout/stderr remain
base64-encoded — clients decode them.

### Connection Management

The post-boot API server needs a connection to the guest daemon:
1. Before entering the post-boot API loop, listen on `{vsock_uds}_1024`
2. Accept one connection (blocks briefly — daemon connects fast after boot)
3. Store the connected fd in VmRuntime
4. Sandbox API handlers write commands to this fd and read responses

For pool-restored VMs: the daemon reconnects on restore (vsock
connections don't survive snapshots), so the listener must be set up
before restore completes.

## Implementation Order

1. **flint-agent binary** — guest daemon, vsock connect, command dispatch
2. **build.zig** — add flint-agent as second target
3. **Repack initrd** — add agent binary, update init script
4. **Host-side vsock listener** — accept daemon connection in API server
5. **Sandbox API endpoints** — POST /sandbox/exec, /sandbox/write, /sandbox/read
6. **End-to-end test** — boot VM, exec command, get output
7. **Pool integration** — make it work with pool acquire/release flow

## Gotchas

- AF_VSOCK needs `#include <linux/vm_sockets.h>` — in Zig use raw
  syscall with sockaddr_vm struct (family=40, cid, port)
- Guest daemon must retry vsock connect on ECONNREFUSED (VMM may not
  be ready when daemon starts early in boot)
- Base64 encoding in Zig: std.base64 should be available
- The daemon is a separate binary with its own main() — can't share
  code with the VMM (different address spaces)
- Static linking required (guest may not have libc)
- Snapshot restore: daemon must reconnect — add reconnect loop
- The initrd is currently prebuilt; we need a way to repack it
