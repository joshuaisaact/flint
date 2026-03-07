const std = @import("std");
const Kvm = @import("kvm/system.zig");
const Vm = @import("kvm/vm.zig");
const Vcpu = @import("kvm/vcpu.zig");
const Memory = @import("memory.zig");
const loader = @import("boot/loader.zig");
const Serial = @import("devices/serial.zig");
const abi = @import("kvm/abi.zig");
const c = abi.c;

const log = std.log.scoped(.flint);

const DEFAULT_MEM_SIZE = 128 * 1024 * 1024; // 128 MB
const DEFAULT_CMDLINE = "console=ttyS0 noapic reboot=k panic=1 pci=off nomodules";

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.skip(); // program name

    const kernel_path = args.next() orelse {
        std.debug.print("usage: flint <kernel-bzimage> [command line]\n", .{});
        std.process.exit(1);
    };

    const cmdline = args.next() orelse DEFAULT_CMDLINE;

    log.info("flint starting", .{});
    log.info("kernel: {s}", .{kernel_path});
    log.info("cmdline: {s}", .{cmdline});

    // 1. Open KVM
    const kvm = try Kvm.open();
    defer kvm.deinit();

    // 2. Create VM
    const vm = try kvm.createVm();
    defer vm.deinit();

    // 3. Set up guest memory
    var mem = try Memory.init(DEFAULT_MEM_SIZE);
    defer mem.deinit();

    try vm.setMemoryRegion(0, 0, mem.alignedMem());

    // 4. Create in-kernel devices
    try vm.createIrqChip();
    try vm.createPit2();

    // 5. Load the kernel
    // kernel_path is a [:0]const u8 from args iterator
    const boot = try loader.loadBzImage(&mem, kernel_path, cmdline);

    // 6. Create vCPU and set up registers
    var vcpu = try vm.createVcpu(0);
    defer vcpu.deinit();

    try setupRegisters(&vcpu, boot);

    // 7. Set up devices
    var serial = Serial.init(1); // stdout fd

    // 8. Run
    log.info("entering VM run loop", .{});
    try runLoop(&vcpu, &serial);
}

fn setupRegisters(vcpu: *Vcpu, boot: loader.LoadResult) !void {
    // Set up segment registers for protected mode with flat segments
    var sregs = try vcpu.getSregs();

    // Code segment: flat, executable, readable
    sregs.cs.base = 0;
    sregs.cs.limit = 0xFFFFFFFF;
    sregs.cs.selector = 0x10;
    sregs.cs.type = 0xB; // execute/read, accessed
    sregs.cs.present = 1;
    sregs.cs.dpl = 0;
    sregs.cs.db = 1; // 32-bit
    sregs.cs.s = 1; // code/data
    sregs.cs.g = 1; // 4KB granularity

    // Data segments: flat, read/write
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

    // Enable protected mode
    sregs.cr0 |= 1;

    try vcpu.setSregs(&sregs);

    // Set up general registers
    var regs = std.mem.zeroes(c.kvm_regs);
    regs.rip = boot.entry_addr;
    regs.rsi = boot.boot_params_addr; // Linux boot protocol: RSI = boot_params pointer
    regs.rflags = 0x2; // Reserved bit 1 must be set
    regs.rsp = 0x7C00; // Stack below boot_params

    try vcpu.setRegs(&regs);

    log.info("registers configured: rip=0x{x} rsi=0x{x}", .{ regs.rip, regs.rsi });
}

fn runLoop(vcpu: *Vcpu, serial: *Serial) !void {
    while (true) {
        const exit_reason = vcpu.run() catch |err| {
            log.err("KVM_RUN failed: {}", .{err});
            return err;
        };

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
                }
                // Unknown ports are silently ignored
            },
            c.KVM_EXIT_HLT => {
                log.info("guest halted", .{});
                return;
            },
            c.KVM_EXIT_SHUTDOWN => {
                log.info("guest shutdown", .{});
                return;
            },
            c.KVM_EXIT_FAIL_ENTRY => {
                const fail = vcpu.kvm_run.unnamed_0.fail_entry;
                log.err("KVM entry failure: hardware_entry_failure_reason=0x{x}", .{fail.hardware_entry_failure_reason});
                return error.VmEntryFailed;
            },
            c.KVM_EXIT_INTERNAL_ERROR => {
                const internal = vcpu.kvm_run.unnamed_0.internal;
                log.err("KVM internal error: suberror={}", .{internal.suberror});
                return error.VmInternalError;
            },
            else => {
                log.warn("unhandled exit reason: {}", .{exit_reason});
            },
        }
    }
}
