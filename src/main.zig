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

const DEFAULT_MEM_SIZE = 512 * 1024 * 1024; // 512 MB
const DEFAULT_CMDLINE = "earlyprintk=serial,ttyS0,115200 console=ttyS0 nokaslr reboot=k panic=1 pci=off nomodules";

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

    // Set CPUID (passthrough host CPU features so kernel sees APIC, TSC, etc.)
    var cpuid = try kvm.getSupportedCpuid();
    try vcpu.setCpuid(&cpuid);

    try setupRegisters(&vcpu, boot, &mem);

    // 7. Set up devices
    var serial = Serial.init(1); // stdout fd

    // 8. Run
    log.info("entering VM run loop", .{});

    try runLoop(&vcpu, &serial);
}

// Memory layout for boot structures (all below boot_params at 0x7000)
// Each page table is 4KB (0x1000)
const GDT_ADDR: u64 = 0x500; // GDT is small, fits in 256 bytes starting at 0x500
const PML4_ADDR: u64 = 0x1000;
const PDPT_ADDR: u64 = 0x2000;
const PD_BASE_ADDR: u64 = 0x3000; // 4 PD tables: 0x3000, 0x4000, 0x5000, 0x6000

fn setupRegisters(vcpu: *Vcpu, boot: loader.LoadResult, mem: *Memory) !void {
    // Write a GDT with 64-bit code segment
    // Entry 0: null
    // Entry 1 (0x08): 64-bit code segment
    // Entry 2 (0x10): 64-bit code segment (also at 0x10 for compatibility)
    // Entry 3 (0x18): data segment
    const gdt = [4]u64{
        0x0000000000000000, // null
        0x00AF9B000000FFFF, // 64-bit code: L=1, D=0, P=1, DPL=0, type=0xB
        0x00AF9B000000FFFF, // 64-bit code (duplicate for selector 0x10)
        0x00CF93000000FFFF, // data: base=0, limit=4G, P=1, DPL=0, type=0x3
    };
    try mem.write(@intCast(GDT_ADDR), std.mem.asBytes(&gdt));

    // Set up identity-mapped page tables for first 512GB
    // PML4[0] -> PDPT
    const pml4 = try mem.ptrAt([512]u64, @intCast(PML4_ADDR));
    @memset(pml4, 0);
    pml4[0] = PDPT_ADDR | 0x3; // present + writable

    // PDPT: 512 entries mapping 0-512GB using 1GB huge pages
    const pdpt = try mem.ptrAt([512]u64, @intCast(PDPT_ADDR));
    for (0..512) |i| {
        pdpt[i] = (i * 0x40000000) | 0x83; // present + writable + huge (1GB page)
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

    // Enable long mode:
    // CR0: PE (protected mode) + PG (paging)
    sregs.cr0 = 0x80000001;
    // CR4: PAE (required for long mode)
    sregs.cr4 = 0x20;
    // CR3: page table root
    sregs.cr3 = PML4_ADDR;
    // EFER: SCE (bit 0) + LME (bit 8) + LMA (bit 10) + NXE (bit 11)
    sregs.efer = 0xD01;

    try vcpu.setSregs(&sregs);

    // Set up general registers
    var regs = std.mem.zeroes(c.kvm_regs);
    regs.rip = boot.entry_addr + 0x200; // startup_64 entry point
    regs.rsi = boot.boot_params_addr;
    regs.rflags = 0x2;
    regs.rsp = 0x7C00;

    try vcpu.setRegs(&regs);

    log.info("registers configured: rip=0x{x} (64-bit entry) rsi=0x{x}", .{ regs.rip, regs.rsi });
}

fn runLoop(vcpu: *Vcpu, serial: *Serial) !void {
    var exit_count: u64 = 0;
    while (true) {
        const exit_reason = vcpu.run() catch |err| {
            log.err("KVM_RUN failed: {}", .{err});
            return err;
        };
        exit_count += 1;

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
                } else if (exit_count < 20) {
                    log.debug("IO port=0x{x} dir={} size={}", .{ io.port, io.direction, io.size });
                }
            },
            c.KVM_EXIT_HLT => {
                log.info("guest halted after {} exits", .{exit_count});
                return;
            },
            c.KVM_EXIT_SHUTDOWN => {
                const regs = vcpu.getRegs() catch unreachable;
                const sregs = vcpu.getSregs() catch unreachable;
                log.info("guest shutdown (triple fault) after {} exits", .{exit_count});
                log.info("  rip=0x{x} rsp=0x{x} rflags=0x{x}", .{ regs.rip, regs.rsp, regs.rflags });
                log.info("  cr0=0x{x} cr3=0x{x} cr4=0x{x} efer=0x{x}", .{ sregs.cr0, sregs.cr3, sregs.cr4, sregs.efer });
                log.info("  cs: sel=0x{x} base=0x{x} type={} l={} db={}", .{ sregs.cs.selector, sregs.cs.base, sregs.cs.type, sregs.cs.l, sregs.cs.db });
                return;
            },
            c.KVM_EXIT_FAIL_ENTRY => {
                const fail = vcpu.kvm_run.unnamed_0.fail_entry;
                log.err("KVM entry failure: hardware_entry_failure_reason=0x{x}", .{fail.hardware_entry_failure_reason});
                return error.VmEntryFailed;
            },
            c.KVM_EXIT_INTERNAL_ERROR => {
                const internal = vcpu.kvm_run.unnamed_0.internal;
                const regs = vcpu.getRegs() catch unreachable;
                log.err("KVM internal error: suberror={} (1=emulation failure) after {} exits", .{ internal.suberror, exit_count });
                log.err("  rip=0x{x} rsp=0x{x}", .{ regs.rip, regs.rsp });
                return error.VmInternalError;
            },
            c.KVM_EXIT_MMIO => {
                const mmio = vcpu.kvm_run.unnamed_0.mmio;
                if (exit_count < 20) {
                    log.info("MMIO: addr=0x{x} len={} is_write={}", .{ mmio.phys_addr, mmio.len, mmio.is_write });
                }
            },
            else => {
                log.warn("unhandled exit reason: {}", .{exit_reason});
            },
        }
    }
}
