const std = @import("std");
const Kvm = @import("kvm/system.zig");
const Vm = @import("kvm/vm.zig");
const Vcpu = @import("kvm/vcpu.zig");
const Memory = @import("memory.zig");
const loader = @import("boot/loader.zig");
const Serial = @import("devices/serial.zig");
const VirtioMmio = @import("devices/virtio/mmio.zig");
const virtio = @import("devices/virtio.zig");
const abi = @import("kvm/abi.zig");
const c = abi.c;
const boot_params = @import("boot/params.zig");

const log = std.log.scoped(.flint);

const DEFAULT_MEM_SIZE = 512 * 1024 * 1024; // 512 MB
const DEFAULT_CMDLINE = "earlyprintk=serial,ttyS0,115200 console=ttyS0 nokaslr reboot=k panic=1 pci=off nomodules";

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.skip(); // program name

    const kernel_path = args.next() orelse {
        std.debug.print("usage: flint <kernel> [initrd] [--disk <path>] [--tap <name>] [cmdline]\n", .{});
        std.process.exit(1);
    };

    // Parse remaining args
    var initrd_path: ?[*:0]const u8 = null;
    var disk_path: ?[*:0]const u8 = null;
    var tap_name: ?[*:0]const u8 = null;
    var cmdline: [*:0]const u8 = DEFAULT_CMDLINE;
    var got_initrd = false;

    while (args.next()) |arg| {
        const len = std.mem.indexOfSentinel(u8, 0, arg);
        const s = arg[0..len];
        if (std.mem.eql(u8, s, "--disk")) {
            disk_path = args.next() orelse {
                std.debug.print("--disk requires an argument\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, s, "--tap")) {
            tap_name = args.next() orelse {
                std.debug.print("--tap requires an argument\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.indexOfScalar(u8, s, '=') != null) {
            cmdline = arg;
        } else if (!got_initrd) {
            initrd_path = arg;
            got_initrd = true;
        }
    }

    log.info("flint starting", .{});
    log.info("kernel: {s}", .{kernel_path});
    if (initrd_path) |p| log.info("initrd: {s}", .{p});
    if (disk_path) |p| log.info("disk: {s}", .{p});
    if (tap_name) |p| log.info("tap: {s}", .{p});
    log.info("cmdline: {s}", .{cmdline});

    // 1. Open KVM
    const kvm = try Kvm.open();
    defer kvm.deinit();

    // 2. Create VM
    const vm = try kvm.createVm();
    defer vm.deinit();

    // 3. Set up Intel-required addresses (harmless on AMD)
    try vm.setTssAddr(0xFFFBD000);
    try vm.setIdentityMapAddr(0xFFFBC000);

    // 4. Set up guest memory
    var mem = try Memory.init(DEFAULT_MEM_SIZE);
    defer mem.deinit();

    try vm.setMemoryRegion(0, 0, mem.alignedMem());

    // 5. Create in-kernel devices
    try vm.createIrqChip();
    try vm.createPit2();

    // 6. Set up virtio devices
    var devices: [virtio.MAX_DEVICES]?VirtioMmio = .{null} ** virtio.MAX_DEVICES;
    var device_count: u32 = 0;

    if (disk_path) |dp| {
        const base = virtio.MMIO_BASE + @as(u64, device_count) * virtio.MMIO_SIZE;
        const irq = virtio.IRQ_BASE + device_count;
        devices[device_count] = try VirtioMmio.initBlk(base, irq, dp);
        device_count += 1;
    }

    if (tap_name) |tn| {
        const base = virtio.MMIO_BASE + @as(u64, device_count) * virtio.MMIO_SIZE;
        const irq = virtio.IRQ_BASE + device_count;
        devices[device_count] = try VirtioMmio.initNet(base, irq, tn);
        device_count += 1;
    }

    defer for (&devices) |*d| {
        if (d.*) |*dev| dev.deinit();
    };

    // Build cmdline with virtio_mmio.device= entries
    var cmdline_buf: [1024]u8 = undefined;
    var effective_cmdline: [*:0]const u8 = cmdline;
    if (device_count > 0) {
        var pos: usize = 0;
        const base_cmdline = cmdline[0..std.mem.indexOfSentinel(u8, 0, cmdline)];
        @memcpy(cmdline_buf[pos..][0..base_cmdline.len], base_cmdline);
        pos += base_cmdline.len;

        for (0..device_count) |i| {
            if (devices[i]) |dev| {
                const entry = std.fmt.bufPrint(cmdline_buf[pos..], " virtio_mmio.device=4K@0x{x}:{d}", .{
                    dev.mmio_base, dev.irq,
                }) catch {
                    log.err("cmdline buffer too small", .{});
                    return error.CmdlineTooLong;
                };
                pos += entry.len;
            }
        }

        if (pos < cmdline_buf.len) {
            cmdline_buf[pos] = 0;
            effective_cmdline = @ptrCast(&cmdline_buf);
        }
    }

    // 7. Load the kernel (and initrd if provided)
    const boot = try loader.loadBzImage(&mem, kernel_path, initrd_path, effective_cmdline);

    // 8. Create vCPU and set up registers
    const vcpu_mmap_size = try kvm.getVcpuMmapSize();
    var vcpu = try vm.createVcpu(0, vcpu_mmap_size);
    defer vcpu.deinit();

    // Set CPUID (passthrough host CPU features so kernel sees APIC, TSC, etc.)
    var cpuid = try kvm.getSupportedCpuid();
    try vcpu.setCpuid(&cpuid);

    try setupRegisters(&vcpu, boot, &mem);

    // 9. Set up devices
    var serial = Serial.init(1); // stdout fd

    // 10. Run
    log.info("entering VM run loop", .{});
    try runLoop(&vcpu, &serial, &vm, &mem, &devices, device_count);
}

// Memory layout for boot structures (all below boot_params at 0x7000)
const GDT_ADDR: u64 = 0x500;
const PML4_ADDR: u64 = 0x1000;
const PDPT_ADDR: u64 = 0x2000;
const STACK_ADDR: u64 = 0x8000; // above boot_params, grows down into 0x3000-0x7FFF

// x86-64 control register bits
const CR0_PE: u64 = 1 << 0; // Protected Mode Enable
const CR0_PG: u64 = 1 << 31; // Paging
const CR4_PAE: u64 = 1 << 5; // Physical Address Extension
const EFER_SCE: u64 = 1 << 0; // SYSCALL Enable
const EFER_LME: u64 = 1 << 8; // Long Mode Enable
const EFER_LMA: u64 = 1 << 10; // Long Mode Active
const EFER_NXE: u64 = 1 << 11; // No-Execute Enable

// Page table entry flags
const PTE_PRESENT: u64 = 1 << 0;
const PTE_WRITABLE: u64 = 1 << 1;
const PTE_HUGE: u64 = 1 << 7; // 1GB page in PDPT

fn setupRegisters(vcpu: *Vcpu, boot: loader.LoadResult, mem: *Memory) !void {
    // Write a GDT with 64-bit code segment
    // Entry 0: null
    // Entry 1 (0x08): 64-bit code segment
    // Entry 2 (0x10): 64-bit code segment (Linux expects CS=0x10)
    // Entry 3 (0x18): data segment
    const gdt = [4]u64{
        0x0000000000000000, // null
        0x00AF9B000000FFFF, // 64-bit code: L=1, D=0, P=1, DPL=0, type=0xB
        0x00AF9B000000FFFF, // 64-bit code (duplicate at selector 0x10)
        0x00CF93000000FFFF, // data: base=0, limit=4G, P=1, DPL=0, type=0x3
    };
    try mem.write(@intCast(GDT_ADDR), std.mem.asBytes(&gdt));

    // Set up identity-mapped page tables for first 512GB using 1GB huge pages
    const pml4 = try mem.ptrAt([512]u64, @intCast(PML4_ADDR));
    @memset(pml4, 0);
    pml4[0] = PDPT_ADDR | PTE_PRESENT | PTE_WRITABLE;

    const pdpt = try mem.ptrAt([512]u64, @intCast(PDPT_ADDR));
    for (0..512) |i| {
        pdpt[i] = (i * 0x40000000) | PTE_PRESENT | PTE_WRITABLE | PTE_HUGE;
    }

    var sregs = try vcpu.getSregs();

    // Point GDTR at our GDT
    sregs.gdt.base = GDT_ADDR;
    sregs.gdt.limit = @sizeOf(@TypeOf(gdt)) - 1;

    // Set up 64-bit code segment
    sregs.cs.base = 0;
    sregs.cs.limit = 0xFFFFFFFF;
    sregs.cs.selector = 0x10;
    sregs.cs.type = 0xB; // execute/read, accessed
    sregs.cs.present = 1;
    sregs.cs.dpl = 0;
    sregs.cs.db = 0; // must be 0 for 64-bit
    sregs.cs.s = 1;
    sregs.cs.l = 1; // 64-bit mode
    sregs.cs.g = 1;

    // Data segments
    inline for (&[_]*@TypeOf(sregs.ds){ &sregs.ds, &sregs.es, &sregs.fs, &sregs.gs, &sregs.ss }) |seg| {
        seg.base = 0;
        seg.limit = 0xFFFFFFFF;
        seg.selector = 0x18;
        seg.type = 0x3; // read/write, accessed
        seg.present = 1;
        seg.dpl = 0;
        seg.db = 1;
        seg.s = 1;
        seg.g = 1;
    }

    // Enable long mode
    sregs.cr0 = CR0_PE | CR0_PG;
    sregs.cr4 = CR4_PAE;
    sregs.cr3 = PML4_ADDR;
    sregs.efer = EFER_SCE | EFER_LME | EFER_LMA | EFER_NXE;

    try vcpu.setSregs(&sregs);

    // Set up general registers
    var regs = std.mem.zeroes(c.kvm_regs);
    regs.rip = boot.entry_addr + boot_params.STARTUP_64_OFFSET;
    regs.rsi = boot.boot_params_addr;
    regs.rflags = 0x2; // reserved bit 1 must be set
    regs.rsp = STACK_ADDR;

    try vcpu.setRegs(&regs);

    log.info("registers configured: rip=0x{x} (startup_64) rsi=0x{x}", .{ regs.rip, regs.rsi });
}

fn injectIrq(vm: *const Vm, irq: u32) void {
    vm.setIrqLine(irq, 1) catch |err| {
        log.warn("setIrqLine high: {}", .{err});
        return;
    };
    vm.setIrqLine(irq, 0) catch |err| log.warn("setIrqLine low: {}", .{err});
}

const DeviceArray = [virtio.MAX_DEVICES]?VirtioMmio;

fn runLoop(vcpu: *Vcpu, serial: *Serial, vm: *const Vm, mem: *Memory, devices: *DeviceArray, device_count: u32) !void {
    var exit_count: u64 = 0;
    while (true) {
        const exit_reason = vcpu.run() catch |err| {
            log.err("KVM_RUN failed: {}", .{err});
            return err;
        };
        exit_count +%= 1;

        // Poll RX on net devices between VM exits
        for (devices[0..device_count]) |*dev_opt| {
            if (dev_opt.*) |*dev| {
                if (dev.pollRx(mem)) {
                    injectIrq(vm, dev.irq);
                }
            }
        }

        switch (exit_reason) {
            c.KVM_EXIT_IO => {
                const io = vcpu.getIoData();

                if (io.port >= Serial.COM1_PORT and io.port < Serial.COM1_PORT + Serial.PORT_COUNT) {
                    const is_write = io.direction == c.KVM_EXIT_IO_OUT;
                    var i: u32 = 0;
                    while (i < io.count) : (i += 1) {
                        const offset = i * io.size;
                        serial.handleIo(io.port, io.data[offset..][0..io.size], is_write);
                    }
                    if (serial.hasPendingIrq()) {
                        injectIrq(vm, Serial.IRQ);
                    }
                }
            },
            c.KVM_EXIT_MMIO => {
                const mmio = vcpu.getMmioData();
                const len = @min(mmio.len, 8);
                for (devices[0..device_count]) |*dev_opt| {
                    if (dev_opt.*) |*dev| {
                        if (dev.matchesAddr(mmio.phys_addr)) {
                            const offset = mmio.phys_addr - dev.mmio_base;
                            if (mmio.is_write) {
                                const data: [8]u8 = mmio.data;
                                dev.handleWrite(offset, data[0..len]);

                                if (offset == virtio.MMIO_QUEUE_NOTIFY) {
                                    if (dev.processQueues(mem)) {
                                        injectIrq(vm, dev.irq);
                                    }
                                }
                            } else {
                                var data: [8]u8 = .{0} ** 8;
                                dev.handleRead(offset, data[0..len]);
                                const run_mmio = &vcpu.kvm_run.unnamed_0.mmio;
                                run_mmio.data = data;
                            }
                            break; // each address matches at most one device
                        }
                    }
                }
            },
            c.KVM_EXIT_HLT => {
                log.info("guest halted after {} exits", .{exit_count});
                return;
            },
            c.KVM_EXIT_SHUTDOWN => {
                log.info("guest shutdown (triple fault) after {} exits", .{exit_count});
                if (vcpu.getRegs()) |regs| {
                    log.info("  rip=0x{x} rsp=0x{x} rflags=0x{x}", .{ regs.rip, regs.rsp, regs.rflags });
                } else |_| {}
                if (vcpu.getSregs()) |sregs| {
                    log.info("  cr0=0x{x} cr3=0x{x} cr4=0x{x} efer=0x{x}", .{ sregs.cr0, sregs.cr3, sregs.cr4, sregs.efer });
                    log.info("  cs: sel=0x{x} base=0x{x} type={} l={} db={}", .{ sregs.cs.selector, sregs.cs.base, sregs.cs.type, sregs.cs.l, sregs.cs.db });
                } else |_| {}
                return;
            },
            c.KVM_EXIT_FAIL_ENTRY => {
                const fail = vcpu.kvm_run.unnamed_0.fail_entry;
                log.err("KVM entry failure: hardware_entry_failure_reason=0x{x}", .{fail.hardware_entry_failure_reason});
                return error.VmEntryFailed;
            },
            c.KVM_EXIT_INTERNAL_ERROR => {
                const internal = vcpu.kvm_run.unnamed_0.internal;
                log.err("KVM internal error: suberror={} (1=emulation failure) after {} exits", .{ internal.suberror, exit_count });
                if (vcpu.getRegs()) |regs| {
                    log.err("  rip=0x{x} rsp=0x{x}", .{ regs.rip, regs.rsp });
                } else |_| {}
                return error.VmInternalError;
            },
            else => {
                log.warn("unhandled exit reason: {}", .{exit_reason});
            },
        }
    }
}
