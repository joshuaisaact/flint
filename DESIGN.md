# Flint: Firecracker in Zig

A lightweight, production-grade Virtual Machine Monitor (VMM) using KVM, written in Zig.

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
```

```
  devices/
    serial.zig      -- 16550 UART emulation (COM1, IRQ 4)
    virtio.zig      -- virtio common constants (MMIO offsets, status, features)
    virtio/
      mmio.zig      -- virtio-mmio v2 transport layer
      blk.zig       -- virtio-blk device backend
      net.zig       -- virtio-net device backend (TAP)
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

#### Future networking enhancements (Phase 4)
- vhost-net kernel acceleration
- `ioeventfd`/`irqfd` for kernel-bypass notifications

### Phase 4: Production concerns
- REST API server (Unix socket, JSON)
- Seccomp filters
- Jailer (namespaces, cgroups)
- Rate limiters on virtio devices
- VM snapshotting / restore
- vsock support
- Metrics / logging
- CPUID filtering (topology, HYPERVISOR bit, VMX/SMX)
- Multi-vCPU support (thread per vCPU, mutex on shared device state)

## What Firecracker has that existing Zig VMMs don't

- REST API / Unix socket control plane
- Seccomp filtering
- Jailer (namespace + cgroup isolation)
- Rate limiters on virtio devices
- VM snapshotting / restore
- Proper virtio device reset / cleanup
- vsock support
- Metrics / logging infrastructure
- Production hardening and operational maturity

This is where Flint's value lies -- not just another KVM wrapper, but a production-grade microVMM.
