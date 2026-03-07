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
6. **Hand-written boot_params** -- only the fields we actually use, not the whole C header
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
  main.zig          -- entry point, arg parsing, orchestration
  kvm/
    abi.zig         -- @cImport("linux/kvm.h") + ioctl helper
    system.zig      -- Kvm (system fd wrapper)
    vm.zig          -- Vm (VM fd wrapper)
    vcpu.zig        -- Vcpu (vCPU fd wrapper + run loop)
  boot/
    params.zig      -- boot_params extern structs (hand-written, minimal)
    loader.zig      -- kernel + initrd loading into guest memory
  devices/
    device.zig      -- Device tagged union + IO dispatch
    serial.zig      -- 16550A UART emulation
  arch/
    index.zig       -- comptime arch selector
    x86/
      setup.zig     -- x86 VM init, register setup, CPUID
  memory.zig        -- guest physical memory management (mmap regions)
```

### Device emulation via tagged union

```zig
const Device = union(enum) {
    serial: Serial,
    virtio_block: VirtioBlock,
    virtio_net: VirtioNet,

    pub fn handle_io(self: *Device, port: u16, data: []u8, is_write: bool) void {
        switch (self.*) {
            inline else => |*dev| dev.handle_io(port, data, is_write),
        }
    }
};
```

Small, closed, known-at-comptime set. `inline else` generates per-variant dispatch resolved at comptime.

### Memory model

- Guest memory: direct `mmap` (anonymous, private). Not allocator-backed.
- Host state: explicit `std.mem.Allocator` passed through.
- MMIO gap at `0xD0000000` (768MB) for device MMIO regions.

### Concurrency

- Thread per vCPU, blocking `KVM_RUN` loop
- No async -- simple and proven
- Mutex on shared device state where needed

## Build phases

### Phase 1: Boot to serial output
- KVM ioctl wrapper (create VM, vCPU, memory regions)
- Load a Linux kernel (bzImage)
- Set up boot_params + initial registers
- vCPU run loop handling IO exits
- Serial port emulation (print to stdout)
- **Target: ~500 lines, see "Linux version ..." from inside a VM**

### Phase 2: Boot a real kernel
- Full bzImage loader (parse setup header, protocol versions)
- Command line passing
- initrd loading
- Proper CPUID/MSR setup
- In-kernel IRQCHIP + PIT

### Phase 3: Storage + networking
- virtio-mmio transport layer
- virtio-block (backed by a file)
- virtio-net (backed by TAP device, vhost-net acceleration)
- `ioeventfd`/`irqfd` for kernel-bypass notifications

### Phase 4: Production concerns
- REST API server (Unix socket, JSON)
- Seccomp filters
- Jailer (namespaces, cgroups)
- Rate limiters on virtio devices
- VM snapshotting / restore
- vsock support
- Metrics / logging

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
