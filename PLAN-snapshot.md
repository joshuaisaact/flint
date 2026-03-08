# Snapshot/Restore Implementation Plan

## Goal
Save full VM state to two files (vmstate + memory). Restore from those files without booting a kernel. Target: ~5ms restore time.

## Design Decisions
1. **Simple binary format** — write KVM structs directly with magic header + version. No serde framework. Bump version on format change, reject old snapshots.
2. **Full snapshots only** — no diff/dirty page tracking. Boot once, snapshot, restore many.
3. **mmap(MAP_PRIVATE) for memory restore** — lazy demand-paging, near-instant regardless of VM size.
4. **No cross-host restore** — same machine only, no CPUID normalization.

## Binary File Format

### vmstate file
```
Offset 0:   Header (32 bytes)
              magic:          [8]u8 = "FLINTSNP"
              version:        u32 = 1
              mem_size:       u64 = guest memory in bytes
              device_count:   u32 = number of virtio devices
              _reserved:      [8]u8 = zeroes

            VcpuState section
              mp_state:       kvm_mp_state (4 bytes)
              regs:           kvm_regs (144 bytes)
              sregs:          kvm_sregs (312 bytes)
              xcrs:           kvm_xcrs
              lapic:          kvm_lapic_state (1024 bytes)
              cpuid:          nent:u32 + pad:u32 + entries
              msrs:           nmsrs:u32 + pad:u32 + entries
              vcpu_events:    kvm_vcpu_events (~64 bytes)

            VmState section
              irqchip[0]:     kvm_irqchip (PIC master)
              irqchip[1]:     kvm_irqchip (PIC slave)
              irqchip[2]:     kvm_irqchip (IOAPIC)
              pit2:           kvm_pit_state2
              clock:          kvm_clock_data

            DeviceState section (per device)
              device_type:    u32 (1=net, 2=blk, 19=vsock)
              mmio_base:      u64
              irq:            u32
              transport state: status, features_sel, driver_features, queue_sel,
                               interrupt_status, config_generation
              per queue (3 max): size, ready, desc/avail/used addrs, last_avail_idx, next_used_idx
              backend config:  blk: disk_path + capacity
                               net: tap_name + mac
                               vsock: guest_cid + uds_path

            SerialState section (10 bytes)
              ier, iir, lcr, mcr, lsr, msr, scr, dll, dlh, irq_pending
```

### memory file
Raw dump of guest memory (mem_size bytes). On restore: `mmap(MAP_PRIVATE)` for demand-paging.

## State Save/Restore Ordering

### vCPU save order (MP_STATE first, vcpu_events last)
1. KVM_GET_MP_STATE (triggers internal KVM state flush)
2. KVM_GET_REGS
3. KVM_GET_SREGS
4. KVM_GET_XCRS
5. KVM_GET_LAPIC
6. KVM_GET_CPUID2
7. KVM_GET_MSRS
8. KVM_GET_VCPU_EVENTS (last)

### vCPU restore order (CPUID first, vcpu_events last)
1. KVM_SET_CPUID2 (must be first — configures available MSRs)
2. KVM_SET_MP_STATE
3. KVM_SET_REGS
4. KVM_SET_SREGS
5. KVM_SET_XCRS
6. KVM_SET_LAPIC (must follow SREGS — needs APIC base)
7. KVM_SET_MSRS (TSC before TSC_DEADLINE)
8. KVM_SET_VCPU_EVENTS (last)

### VM restore: create irqchip/PIT first, then SET state on top
- KVM_CREATE_IRQCHIP → KVM_SET_IRQCHIP x3
- KVM_CREATE_PIT2 → KVM_SET_PIT2
- KVM_SET_CLOCK

## Pause/Resume Mechanism

Use `kvm_run.immediate_exit = 1` to make KVM_RUN return EINTR. The run loop checks an atomic `paused` flag. After pausing, snapshot can safely run (vCPU is stopped).

VmRuntime struct holds all live state + atomics:
```zig
const VmRuntime = struct {
    vcpu: *Vcpu,
    vm: *const Vm,
    mem: *Memory,
    serial: *Serial,
    devices: *DeviceArray,
    device_count: u32,
    paused: std.atomic.Value(bool),
};
```

API server runs in a separate thread post-boot (std.Thread.spawn).

## MSR List (minimum viable)
- MSR_IA32_TSC (0x10)
- MSR_IA32_APICBASE (0x1B)
- MSR_IA32_SYSENTER_CS/ESP/EIP (0x174-0x176)
- MSR_IA32_MISC_ENABLE (0x1A0)
- MSR_IA32_TSC_ADJUST (0x3B)
- MSR_IA32_TSC_DEADLINE (0x6E0) — must restore AFTER TSC
- MSR_STAR (0xC0000081)
- MSR_LSTAR (0xC0000082)
- MSR_CSTAR (0xC0000083)
- MSR_SYSCALL_MASK (0xC0000084)
- MSR_KERNEL_GS_BASE (0xC0000102)

## Implementation Order

### Step 1: KVM ioctls (vcpu.zig, vm.zig) ✅
Add get/set wrappers for all state listed above. Pure additions, no existing code changes.

### Step 2: Memory.initFromFile (memory.zig) ✅
Add `initFromFile()` — open file, validate size, mmap(MAP_PRIVATE). Small addition.

### Step 3: Device snapshot methods (serial.zig, queue.zig, mmio.zig) ✅
Add snapshotSave/snapshotRestore to each. Pure additions to existing structs.

### Step 4: snapshot.zig (new file) ✅
Create save() and load() orchestrator. Depends on steps 1-3.

### Step 5+6: CLI paths (main.zig) ✅
Added `--restore` boot path (skips kernel load, calls snapshot.load()), `--save-on-halt` (saves snapshot when guest halts), `--vmstate-path`/`--mem-path` for file paths. VmRuntime/pause deferred to Step 7 (only needed for live API-triggered snapshots).

### Step 7: API endpoints (api.zig)
Add PATCH /vm, PUT /snapshot/create, PUT /snapshot/load. Run API server post-boot in thread. Needs VmRuntime struct + pause mechanism.

### Step 8: Tests (tests.zig) ✅
Serial snapshot round-trip, queue snapshot round-trip, header validation.

## Files to Create/Modify

| File | Action | What |
|------|--------|------|
| `src/snapshot.zig` | CREATE | Save/load orchestrator, header, binary format |
| `src/kvm/vcpu.zig` | MODIFY | 10+ KVM ioctl wrappers for vCPU state |
| `src/kvm/vm.zig` | MODIFY | 6 KVM ioctl wrappers for VM state |
| `src/memory.zig` | MODIFY | initFromFile() for mmap restore |
| `src/devices/serial.zig` | MODIFY | snapshotSave/Restore |
| `src/devices/virtio/mmio.zig` | MODIFY | snapshotSave/Restore (transport + backend) |
| `src/devices/virtio/queue.zig` | MODIFY | snapshotSave/Restore |
| `src/main.zig` | MODIFY | VmRuntime, pause, --restore path |
| `src/api.zig` | MODIFY | PATCH /vm, snapshot endpoints, post-boot thread |
| `src/tests.zig` | MODIFY | Snapshot unit tests |

## Gotchas
- CPUID must be set before MSRs on restore (determines valid MSRs)
- TSC must be set before TSC_DEADLINE (deadline is relative to TSC)
- LAPIC must follow SREGS (needs APIC base MSR)
- IRQ chip/PIT must be created before SET (SET overwrites state on existing device)
- Device fds (disk, TAP, vsock) are reopened fresh on restore from saved paths
- Vsock connections are NOT saved (ephemeral)
- Reset kvm_run.immediate_exit = 0 before re-entering run loop after pause
- Use raw linux syscalls for file I/O (consistent with rest of codebase)
- Zig 0.16 atomics: std.atomic.Value(bool), load(.acquire), store(.release)
- kvm_irqchip has an opaque union in Zig's cImport — use raw [520]u8 and hardcoded ioctl numbers
- packed struct can't contain [N]u8 arrays in Zig — use manual serialization for snapshot header
- Zig test runner treats any std.log.err as a test failure — use log.warn for expected error paths
