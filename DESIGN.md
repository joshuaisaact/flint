# Flint

A lightweight KVM-based Virtual Machine Monitor (VMM) written in Zig, designed for fast, secure code execution sandboxes.

## Prior art

### zvm (github.com/tw4452852/zvm)
- ~3,700 lines Zig, most feature-complete existing Zig VMM
- Has virtio-blk (MMIO), virtio-net (PCI + vhost-net), VFIO passthrough, dual-arch (x86+ARM)
- Uses `@cImport("linux/kvm.h")` for KVM structs/constants
- Comptime arch dispatch via `switch (builtin.target.cpu.arch)`
- Uses `ioeventfd`/`irqfd` for kernel-bypass virtio notifications
- Weaknesses: pervasive global mutable state (module-level `var`), no tests, `@import("root")` hub pattern, `unreachable` for unhandled IO, no fd wrapper types, auto-generated ABI files checked in

### zvisor (github.com/b0bleet/zvisor)
- ~2,500 lines Zig, simpler/less capable
- Serial, i8042 stub, IOAPIC stub. No virtio.
- Manual vtable pattern (`AccelVTable` with `*anyopaque`) for hypervisor abstraction
- Uses qboot firmware for boot (not direct Linux boot protocol like Firecracker)
- Weaknesses: single vCPU only, wrong e820 map, no virtio, hardcoded CPUID, no tests, global state

### Ymir tutorial (hv.smallkirby.com)
- Type-1 bare-metal hypervisor (Intel VT-x, not KVM) -- different architecture from Flint
- Useful Zig idioms: packed structs for register mapping, `@bitCast` for struct<->int, naked calling convention for guest code, comptime MSR constraint application
- ~32 chapters covering UEFI boot through Linux guest with initramfs

## Design principles

1. **No global mutable state** -- all state flows through struct fields, not module-level `var`
2. **Fd-holding wrapper types** -- `Kvm`, `Vm`, `Vcpu` structs own their fds with `deinit()` cleanup
3. **Generic ioctl helper** -- eliminate repetitive errno checking at every call site
4. **Tagged union device dispatch** -- not vtables, not linear scan of function pointers
5. **`@cImport` for KVM ABI** -- import kernel headers directly for ioctl constants/structs
6. **Hand-written boot_params** -- packed structs for on-wire layout, named constants for byte offsets
7. **Comptime arch dispatch** -- start x86-only but structure for future multi-arch
8. **Tests from day one** -- at minimum for boot param setup and device register logic
9. **`unreachable` never for guest IO** -- log and ignore unknown accesses
10. **Explicit imports** -- no `@import("root")` hub pattern, pass dependencies through init/fields

## Architecture

```
/dev/kvm fd  ->  Kvm   (system-level: version, create VM)
  VM fd      ->  Vm    (VM-level: memory regions, create vCPU, irqs)
    vCPU fd  ->  Vcpu  (vCPU-level: run, get/set regs)
```

### File structure

```
src/
  main.zig          -- entry point, arg parsing, register setup, run loop
  api.zig           -- REST API server (Unix socket, HTTP/1.1, JSON)
  memory.zig        -- guest physical memory management (mmap regions)
  tests.zig         -- unit tests
  kvm/
    abi.zig         -- @cImport("linux/kvm.h") + ioctl helper
    system.zig      -- Kvm (system fd, CPUID, capabilities)
    vm.zig          -- Vm (VM fd, memory regions, IRQ chip, PIT, TSS)
    vcpu.zig        -- Vcpu (vCPU fd, registers, CPUID, run)
  boot/
    params.zig      -- boot protocol constants and packed structs
    loader.zig      -- bzImage + initrd loading into guest memory
  devices/
    serial.zig      -- 16550 UART emulation (COM1, IRQ 4)
    virtio.zig      -- virtio common constants (MMIO offsets, status, features)
    virtio/
      mmio.zig      -- virtio-mmio v2 transport layer
      blk.zig       -- virtio-blk device backend
      net.zig       -- virtio-net device backend (TAP)
      vsock.zig     -- virtio-vsock device backend (AF_UNIX relay)
      queue.zig     -- split virtqueue (desc table, avail/used rings)
```

### Memory model

- Guest memory: direct `mmap` (anonymous, private). Not allocator-backed.
- Host state: explicit `std.mem.Allocator` passed through.
- MMIO gap at `0xD0000000` (768MB) for device MMIO regions.

### Concurrency

- Thread per vCPU, blocking `KVM_RUN` loop
- No async -- simple and proven
- Mutex on shared device state where needed

## Build phases

### Phase 1: Boot to serial output -- DONE
- KVM ioctl wrapper (create VM, vCPU, memory regions)
- Load a Linux kernel (bzImage)
- Set up boot_params + initial registers
- vCPU run loop handling IO exits
- Serial port emulation (print to stdout)
- 64-bit long mode entry (PML4 page tables, EFER, startup_64)
- CPUID passthrough (KVM_GET_SUPPORTED_CPUID / KVM_SET_CPUID2)
- In-kernel IRQCHIP + PIT
- **Result: Linux 6.8.0-31-generic boots to VFS panic in ~1 second**

### Phase 2: Boot to userspace -- DONE
- initrd loading (placed high in RAM, page-aligned, respects initrd_addr_max)
- Serial TX interrupt support (IER/IIR + IRQ 4 injection via KVM_IRQ_LINE)
- Intel compatibility (KVM_SET_TSS_ADDR / KVM_SET_IDENTITY_MAP_ADDR)
- xloadflags validation for 64-bit entry
- Overflow-safe guest memory bounds checks
- Malicious bzImage hardening (setup_sects bounds check)
- E820 map with proper VGA/ROM hole coverage
- Named constants for all boot protocol offsets and control register bits
- 18 unit tests (memory, boot params, serial)
- **Result: boots to busybox initramfs, runs shell scripts, ~1 second to userspace**

### Phase 3: Storage -- DONE
- virtio-mmio v2 (modern) transport layer with full register interface
- virtio-blk device backend (pread/pwrite against a backing file)
- Split virtqueue implementation (descriptor table, available ring, used ring)
- MMIO exit handling in run loop with IRQ injection
- Kernel cmdline auto-extended with `virtio_mmio.device=` for device discovery
- Security hardening: sector bounds validation, host-side used_idx (TOCTOU prevention),
  queue size validation (power-of-2), bounded avail ring processing, O_CLOEXEC on all fds
- **Result: guest mounts ext4 disk images via /dev/vda, reads/writes/flushes work correctly**

### Phase 3b: Networking -- DONE
- virtio-net device backend with TAP device (IFF_TAP | IFF_NO_PI | IFF_VNET_HDR)
- Multiple virtqueue support (RX + TX queues)
- Non-blocking RX polling via readv between VM exits
- TX via writev scatter-gather on TAP fd
- Locally-administered MAC address generation from TAP name
- virtio_net_hdr_v1 (12 bytes) with TUNSETVNETHDRSZ
- Multi-device MMIO support: tagged union dispatch, per-device IRQ/MMIO slots
- Explicit CLI flags: `--disk <path>`, `--tap <name>`
- **Result: virtio-net initializes TAP, handles TX/RX frames between guest and host**

### Phase 3c: REST API -- DONE
- Unix domain socket HTTP/1.1 server using Zig stdlib (std.Io, std.http.Server, std.json)
- Firecracker-compatible pre-boot configuration endpoints:
  - PUT /boot-source (kernel_image_path, initrd_path, boot_args)
  - PUT /drives/{id} (path_on_host)
  - PUT /network-interfaces/{id} (host_dev_name)
  - PUT /machine-config (mem_size_mib)
  - GET /machine-config
  - PUT /vsock (guest_cid, uds_path)
  - PUT /actions (InstanceStart)
- Two-phase lifecycle: configure via API, then InstanceStart triggers boot
- Both CLI and API boot modes supported (`--api-sock <path>` flag)
- **Result: full VM configuration and boot via curl against Unix socket**

### Phase 4a: vsock -- DONE
- virtio-vsock device backend (device ID 19, 3 queues: RX + TX + EVT)
- Userspace vsock (Firecracker model): guest connects to host CID 2, port P,
  VMM connects to `{uds_path}_{P}` on the host via AF_UNIX
- 44-byte virtio vsock header (virtio spec v1.2) with full field parsing
- Connection state machine with 64 simultaneous connections
- Flow control: buf_alloc / fwd_cnt credit-based system
- All vsock operations: REQUEST, RESPONSE, RST, SHUTDOWN, RW, CREDIT_UPDATE/REQUEST
- Non-blocking host socket I/O with EAGAIN handling
- CLI flags: `--vsock-cid <cid> --vsock-uds <path>`
- API endpoint: PUT /vsock
- **Result: guest↔host bidirectional communication via AF_VSOCK sockets**

### Phase 4: Sandbox runtime (in progress)

Priority order optimized for AI agent code execution sandbox use case:

1. ~~**vsock (virtio-socket)**~~ -- DONE (Phase 4a)

2. ~~**VM snapshotting / restore**~~ -- DONE. Save full VM state (vCPU registers, interrupt
   controllers, device transport state, serial) to binary vmstate file + raw memory file.
   Restore via mmap(MAP_PRIVATE) demand-paging for near-instant restore regardless of VM
   size. CLI: `--save-on-halt`, `--restore`, `--vmstate-path`, `--mem-path`.
   API endpoints (pause/resume, snapshot create/load) still TODO.

3. **VM pool / warm start** -- pre-fork a pool of restored VMs ready for immediate use.
   Combined with snapshots, this gives near-instant sandbox provisioning.

4. **Seccomp + jailer** -- syscall filtering and namespace/cgroup isolation for the VMM
   process itself. Defense in depth: even if a guest escapes KVM, the VMM is sandboxed.

5. **Higher-level sandbox API** -- extend the REST API with sandbox-oriented endpoints:
   execute code, stream stdout/stderr, upload/download files, set timeouts and resource
   limits. This is the interface AI agents actually talk to.

6. **Rate limiters** -- throttle virtio-blk and virtio-net I/O to enforce resource limits
   per sandbox instance.

7. **Metrics / logging** -- structured telemetry for sandbox lifecycle, resource usage,
   and error tracking.

#### Future enhancements
- vhost-net kernel acceleration for networking
- `ioeventfd`/`irqfd` for kernel-bypass virtio notifications
- Multi-vCPU support (thread per vCPU, mutex on shared device state)
- CPUID filtering (topology, HYPERVISOR bit, VMX/SMX)

## Target use case

Flint is designed as the VM layer for **AI agent code execution sandboxes** -- similar to
E2B or Cloudflare's sandbox environments. Each sandbox is a lightweight microVM that:

- Boots in <1 second (or <50ms with snapshot restore)
- Runs arbitrary code from AI agents in full Linux isolation
- Communicates with the host via vsock (no IP networking overhead)
- Can be pooled and recycled for high throughput
- Is secured by KVM hardware isolation + seccomp + namespaces
