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
const api = @import("api.zig");
const snapshot = @import("snapshot.zig");
const jail = @import("jail.zig");
const seccomp = @import("seccomp.zig");
const pool_mod = @import("pool.zig");
const pool_api = @import("pool_api.zig");
const sandbox = @import("sandbox.zig");

const log = std.log.scoped(.flint);

const SnapshotOpts = struct {
    vmstate_path: ?[*:0]const u8 = null,
    mem_path: ?[*:0]const u8 = null,
};

/// Live VM state shared between the run loop thread and the API server thread.
/// The API server sets `paused` + `immediate_exit` to safely stop the vCPU
/// before performing operations like snapshotting that require the vCPU to
/// not be in KVM_RUN.
pub const VmRuntime = struct {
    vcpu: *Vcpu,
    vm: *const Vm,
    mem: *Memory,
    serial: *Serial,
    devices: *DeviceArray,
    device_count: u32,
    snap_opts: SnapshotOpts,
    agent: ?*sandbox.AgentConn = null,

    // Pause mechanism: API thread sets paused=true and immediate_exit=1.
    // KVM_RUN returns -EINTR, run loop sees paused=true and spins on
    // the flag. API thread does its work, then sets paused=false.
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Set by the run loop when it has actually stopped executing guest code.
    // The API thread polls this after setting paused=true to confirm the
    // vCPU is safe to inspect.
    ack_paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Set by the run loop when the guest exits (halt/shutdown/error).
    // Tells the API thread to stop accepting connections.
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const DEFAULT_MEM_SIZE = 512 * 1024 * 1024; // 512 MB
const DEFAULT_CMDLINE = "earlyprintk=serial,ttyS0,115200 console=ttyS0 nokaslr reboot=k panic=1 pci=off nomodules";

/// CLI arguments parsed from the command line.
/// Flag names are derived from field names: underscores become hyphens,
/// and each field maps to `--field-name`. Bool fields are flags (no value),
/// optional/non-optional sentinel pointer fields consume the next argument.
const CliArgs = struct {
    // Boot sources (positional args handled separately)
    @"api-sock": ?[*:0]const u8 = null,
    disk: ?[*:0]const u8 = null,
    tap: ?[*:0]const u8 = null,
    @"vsock-cid": ?[*:0]const u8 = null,
    @"vsock-uds": ?[*:0]const u8 = null,

    // Snapshot
    restore: bool = false,
    @"save-on-halt": bool = false,
    @"vmstate-path": [*:0]const u8 = "snapshot.vmstate",
    @"mem-path": [*:0]const u8 = "snapshot.mem",

    // Jail / security
    jail: ?[*:0]const u8 = null,
    @"jail-uid": ?[*:0]const u8 = null,
    @"jail-gid": ?[*:0]const u8 = null,
    @"jail-cgroup": ?[*:0]const u8 = null,
    @"seccomp-audit": bool = false,

    // Pool
    @"pool-size": ?[*:0]const u8 = null,
    @"pool-sock": [*:0]const u8 = "/tmp/flint-pool.sock",

    /// Try to match `flag` against all struct fields (as `--field-name`).
    /// For bool fields, sets to true. For pointer fields, consumes the next arg.
    /// Returns true if the flag was recognized.
    fn parse(self: *CliArgs, flag: []const u8, iter: *std.process.Args.Iterator) bool {
        inline for (std.meta.fields(CliArgs)) |field| {
            if (std.mem.eql(u8, flag, "--" ++ field.name)) {
                if (field.type == bool) {
                    @field(self, field.name) = true;
                } else {
                    @field(self, field.name) = iter.next() orelse {
                        std.debug.print("--" ++ field.name ++ " requires an argument\n", .{});
                        std.process.exit(1);
                    };
                }
                return true;
            }
        }
        return false;
    }
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    const self_exe = args.next() orelse "flint";

    var cli: CliArgs = .{};
    var pool_mode = false;
    var kernel_path: ?[*:0]const u8 = null;
    var initrd_path: ?[*:0]const u8 = null;
    var cmdline: [*:0]const u8 = DEFAULT_CMDLINE;
    var got_initrd = false;

    while (args.next()) |arg| {
        const len = std.mem.indexOfSentinel(u8, 0, arg);
        const s = arg[0..len];
        if (cli.parse(s, &args)) {
            // handled by struct parser
        } else if (std.mem.eql(u8, s, "pool")) {
            pool_mode = true;
        } else if (std.mem.indexOfScalar(u8, s, '=') != null) {
            cmdline = arg;
        } else if (kernel_path == null) {
            kernel_path = arg;
        } else if (!got_initrd) {
            initrd_path = arg;
            got_initrd = true;
        }
    }

    // Validate --pool-size
    var pool_size: u16 = 4;
    if (cli.@"pool-size") |ps| {
        const ps_len = std.mem.indexOfSentinel(u8, 0, ps);
        pool_size = std.fmt.parseUnsigned(u16, ps[0..ps_len], 10) catch {
            std.debug.print("invalid --pool-size\n", .{});
            std.process.exit(1);
        };
        if (pool_size == 0 or pool_size > pool_mod.MAX_POOL_SIZE) {
            std.debug.print("--pool-size must be 1-{}\n", .{pool_mod.MAX_POOL_SIZE});
            std.process.exit(1);
        }
    }

    // Pool mode: manager process spawns child VMs, no jail/seccomp for itself
    if (pool_mode) {
        var pool = pool_mod.Pool.init(.{
            .pool_size = pool_size,
            .vmstate_path = cli.@"vmstate-path",
            .mem_path = cli.@"mem-path",
            .disk_path = cli.disk,
            .pool_sock = cli.@"pool-sock",
            .self_exe = self_exe,
            .jail_dir = cli.jail,
            .jail_uid = cli.@"jail-uid",
            .jail_gid = cli.@"jail-gid",
        });
        defer pool.shutdown();
        return pool_api.serve(&pool, init.io);
    }

    // Jail setup runs before anything else — after this, the process is
    // in a mount namespace with pivot_root'd filesystem and dropped privileges.
    // All file paths (kernel, initrd, disk) must be relative to the jail root.
    if (cli.jail) |jd| {
        const uid_str = cli.@"jail-uid" orelse {
            std.debug.print("--jail requires --jail-uid\n", .{});
            std.process.exit(1);
        };
        const gid_str = cli.@"jail-gid" orelse {
            std.debug.print("--jail requires --jail-gid\n", .{});
            std.process.exit(1);
        };
        const uid_len = std.mem.indexOfSentinel(u8, 0, uid_str);
        const gid_len = std.mem.indexOfSentinel(u8, 0, gid_str);
        const uid = std.fmt.parseUnsigned(u32, uid_str[0..uid_len], 10) catch {
            std.debug.print("invalid --jail-uid\n", .{});
            std.process.exit(1);
        };
        const gid = std.fmt.parseUnsigned(u32, gid_str[0..gid_len], 10) catch {
            std.debug.print("invalid --jail-gid\n", .{});
            std.process.exit(1);
        };
        if (uid == 0 or gid == 0) {
            std.debug.print("--jail-uid and --jail-gid must be non-zero (jail must drop root)\n", .{});
            std.process.exit(1);
        }
        try jail.setup(.{
            .jail_dir = jd,
            .uid = uid,
            .gid = gid,
            .cgroup = cli.@"jail-cgroup",
            .need_tun = cli.tap != null,
        });
    }

    // Seccomp filter — installed after jail (jail needs mount/mknod/setuid)
    // but before any guest interaction
    if (cli.jail != null or cli.@"seccomp-audit") {
        try seccomp.install(cli.@"seccomp-audit");
    }

    if (cli.restore and cli.@"api-sock" != null) {
        // Restore + API mode: restore from snapshot, then run post-boot API
        // (used by pool manager to spawn controllable child VMs)
        const sock = cli.@"api-sock".?;
        const sock_len = std.mem.indexOfSentinel(u8, 0, sock);
        try restoreVmWithApi(cli.@"vmstate-path", cli.@"mem-path", cli.disk, cli.tap, cli.@"vsock-cid", cli.@"vsock-uds", sock[0..sock_len], init.io, init.gpa);
    } else if (cli.restore) {
        // Restore mode: rebuild VM from snapshot files, no kernel load
        try restoreVm(cli.@"vmstate-path", cli.@"mem-path", cli.disk, cli.tap, cli.@"vsock-cid", cli.@"vsock-uds");
    } else if (cli.@"api-sock") |sock| {
        // API mode: pre-boot config phase, then boot, then post-boot API
        const sock_len = std.mem.indexOfSentinel(u8, 0, sock);
        const config = try api.serve(sock[0..sock_len], init.io, init.gpa);
        const kp: [*:0]const u8 = config.kernel_path.?.ptr;
        const ip: ?[*:0]const u8 = if (config.initrd_path) |p| p.ptr else null;
        const ba: ?[*:0]const u8 = if (config.boot_args) |p| p.ptr else null;
        const dp: ?[*:0]const u8 = if (config.disk_path) |p| p.ptr else null;
        const tn: ?[*:0]const u8 = if (config.tap_name) |p| p.ptr else null;
        const vc: ?[*:0]const u8 = if (config.vsock_cid) |p| p.ptr else null;
        const vu: ?[*:0]const u8 = if (config.vsock_uds) |p| p.ptr else null;
        try bootVmWithApi(kp, ip, ba, dp, tn, vc, vu, config.mem_size_mib, sock[0..sock_len], init.io, init.gpa);
    } else if (kernel_path) |kp| {
        // CLI mode: boot directly from args
        const snap_opts: SnapshotOpts = if (cli.@"save-on-halt") .{
            .vmstate_path = cli.@"vmstate-path",
            .mem_path = cli.@"mem-path",
        } else .{};
        try bootVm(kp, initrd_path, cmdline, cli.disk, cli.tap, cli.@"vsock-cid", cli.@"vsock-uds", DEFAULT_MEM_SIZE / (1024 * 1024), snap_opts);
    } else {
        std.debug.print("usage: flint <kernel> [initrd] [--disk <path>] [--tap <name>] [cmdline]\n", .{});
        std.debug.print("       flint --restore [--vmstate-path <path>] [--mem-path <path>]\n", .{});
        std.debug.print("       flint --api-sock <path>\n", .{});
        std.debug.print("       --jail <dir> --jail-uid <uid> --jail-gid <gid> [--jail-cgroup <name>]\n", .{});
        std.debug.print("       --seccomp-audit  (log violations instead of killing)\n", .{});
        std.debug.print("       flint pool --vmstate-path <p> --mem-path <p> --pool-size <n> --pool-sock <p>\n", .{});
        std.process.exit(1);
    }
}


/// All live VM components created during setup. Returned by createVmComponents
/// so callers own the resources and their lifetimes.
const VmComponents = struct {
    kvm: Kvm,
    vm: Vm,
    mem: Memory,
    vcpu: Vcpu,
    serial: Serial,
    devices: DeviceArray,
    device_count: u32,

    fn deinit(self: *VmComponents) void {
        for (&self.devices) |*d| {
            if (d.*) |*dev| dev.deinit();
        }
        self.vcpu.deinit();
        self.mem.deinit();
        self.vm.deinit();
        self.kvm.deinit();
    }
};

/// Create KVM, VM, memory, devices, load kernel, set up vCPU registers.
/// Returns all components by value (Zig uses RVO, no copy).
fn createVmComponents(
    kernel_path: [*:0]const u8,
    initrd_path: ?[*:0]const u8,
    cmdline_or_args: ?[*:0]const u8,
    disk_path: ?[*:0]const u8,
    tap_name: ?[*:0]const u8,
    vsock_cid_str: ?[*:0]const u8,
    vsock_uds_path: ?[*:0]const u8,
    mem_size_mib: u32,
) !VmComponents {
    const mem_size: usize = @as(usize, mem_size_mib) * 1024 * 1024;
    const cmdline: [*:0]const u8 = cmdline_or_args orelse DEFAULT_CMDLINE;

    log.info("kernel: {s}", .{kernel_path});
    if (initrd_path) |p| log.info("initrd: {s}", .{p});
    if (disk_path) |p| log.info("disk: {s}", .{p});
    if (tap_name) |p| log.info("tap: {s}", .{p});
    log.info("cmdline: {s}", .{cmdline});
    log.info("memory: {} MB", .{mem_size_mib});

    const kvm = try Kvm.open();
    errdefer kvm.deinit();

    const vm = try kvm.createVm();
    errdefer vm.deinit();

    try vm.setTssAddr(0xFFFBD000);
    try vm.setIdentityMapAddr(0xFFFBC000);

    var mem = try Memory.init(mem_size);
    errdefer mem.deinit();
    try vm.setMemoryRegion(0, 0, mem.alignedMem());

    try vm.createIrqChip();
    try vm.createPit2();

    var devices: DeviceArray = .{null} ** virtio.MAX_DEVICES;
    const device_count = try initDevices(&devices, disk_path, tap_name, vsock_cid_str, vsock_uds_path);
    errdefer for (&devices) |*d| {
        if (d.*) |*dev| dev.deinit();
    };

    // Build cmdline with virtio_mmio.device= entries
    var cmdline_buf: [1024]u8 = undefined;
    var effective_cmdline: [*:0]const u8 = cmdline;
    if (device_count > 0) {
        var pos: usize = 0;
        const base_cmdline = cmdline[0..std.mem.indexOfSentinel(u8, 0, cmdline)];
        if (base_cmdline.len >= cmdline_buf.len) return error.CmdlineTooLong;
        @memcpy(cmdline_buf[pos..][0..base_cmdline.len], base_cmdline);
        pos += base_cmdline.len;
        for (0..device_count) |i| {
            if (devices[i]) |dev| {
                const entry = std.fmt.bufPrint(cmdline_buf[pos..], " virtio_mmio.device=4K@0x{x}:{d}", .{
                    dev.mmio_base, dev.irq,
                }) catch return error.CmdlineTooLong;
                pos += entry.len;
            }
        }
        if (pos < cmdline_buf.len) {
            cmdline_buf[pos] = 0;
            effective_cmdline = @ptrCast(&cmdline_buf);
        }
    }

    const boot = try loader.loadBzImage(&mem, kernel_path, initrd_path, effective_cmdline);

    const vcpu_mmap_size = try kvm.getVcpuMmapSize();
    var vcpu = try vm.createVcpu(0, vcpu_mmap_size);
    errdefer vcpu.deinit();

    var cpuid = try kvm.getSupportedCpuid();
    try vcpu.setCpuid(&cpuid);
    try setupRegisters(&vcpu, boot, &mem);

    return .{
        .kvm = kvm,
        .vm = vm,
        .mem = mem,
        .vcpu = vcpu,
        .serial = Serial.init(1),
        .devices = devices,
        .device_count = device_count,
    };
}

fn bootVm(
    kernel_path: [*:0]const u8,
    initrd_path: ?[*:0]const u8,
    cmdline_or_args: ?[*:0]const u8,
    disk_path: ?[*:0]const u8,
    tap_name: ?[*:0]const u8,
    vsock_cid_str: ?[*:0]const u8,
    vsock_uds_path: ?[*:0]const u8,
    mem_size_mib: u32,
    snap_opts: SnapshotOpts,
) !void {
    log.info("flint starting", .{});
    var c_ = try createVmComponents(kernel_path, initrd_path, cmdline_or_args, disk_path, tap_name, vsock_cid_str, vsock_uds_path, mem_size_mib);
    defer c_.deinit();

    log.info("entering VM run loop", .{});
    try runLoop(&c_.vcpu, &c_.serial, &c_.vm, &c_.mem, &c_.devices, c_.device_count, snap_opts, null);
}

/// Boot a VM and run a post-boot API server for pause/resume/snapshot.
/// The run loop executes in a spawned thread while the main thread handles
/// API requests on the same Unix socket used for pre-boot configuration.
fn bootVmWithApi(
    kernel_path: [*:0]const u8,
    initrd_path: ?[*:0]const u8,
    cmdline_or_args: ?[*:0]const u8,
    disk_path: ?[*:0]const u8,
    tap_name: ?[*:0]const u8,
    vsock_cid_str: ?[*:0]const u8,
    vsock_uds_path: ?[*:0]const u8,
    mem_size_mib: u32,
    api_sock_path: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    log.info("flint starting (API mode)", .{});
    var c_ = try createVmComponents(kernel_path, initrd_path, cmdline_or_args, disk_path, tap_name, vsock_cid_str, vsock_uds_path, mem_size_mib);
    defer c_.deinit();

    var agent_conn: sandbox.AgentConn = .{};
    if (vsock_uds_path) |uds| {
        agent_conn = sandbox.AgentConn.listen(uds) catch |err| blk: {
            log.warn("agent listener failed: {}, sandbox API disabled", .{err});
            break :blk .{};
        };
    }
    defer agent_conn.deinit();

    var runtime = VmRuntime{
        .vcpu = &c_.vcpu,
        .vm = &c_.vm,
        .mem = &c_.mem,
        .serial = &c_.serial,
        .devices = &c_.devices,
        .device_count = c_.device_count,
        .snap_opts = .{},
    };

    log.info("entering VM run loop (API mode)", .{});
    const thread = std.Thread.spawn(.{}, runLoopThread, .{&runtime}) catch |err| {
        log.err("failed to spawn run loop thread: {}", .{err});
        return error.ThreadSpawnFailed;
    };

    if (agent_conn.listen_fd >= 0) {
        agent_conn.accept() catch |err| {
            log.warn("agent accept failed: {}, sandbox API disabled", .{err});
        };
        if (agent_conn.fd >= 0) {
            runtime.agent = &agent_conn;
        }
    }

    api.servePostBoot(api_sock_path, io, allocator, &runtime) catch |err| {
        log.err("post-boot API error: {}", .{err});
    };

    thread.join();
}

/// Restore a VM from snapshot files instead of booting a kernel.
/// The KVM VM and in-kernel devices (irqchip, PIT) must be created fresh —
/// snapshot.load() then overwrites their state from the saved data.
/// Device backends (disk, TAP, vsock) must be re-opened from CLI args
/// because file descriptors don't survive across processes.
fn restoreVm(
    vmstate_path: [*:0]const u8,
    mem_snap_path: [*:0]const u8,
    disk_path: ?[*:0]const u8,
    tap_name: ?[*:0]const u8,
    vsock_cid_str: ?[*:0]const u8,
    vsock_uds_path: ?[*:0]const u8,
) !void {
    log.info("flint restoring from snapshot", .{});

    // 1. Open KVM, create VM with in-kernel devices
    const kvm = try Kvm.open();
    defer kvm.deinit();

    const vm = try kvm.createVm();
    defer vm.deinit();

    try vm.setTssAddr(0xFFFBD000);
    try vm.setIdentityMapAddr(0xFFFBC000);

    // irqchip and PIT must exist before snapshot.load() overwrites their state
    try vm.createIrqChip();
    try vm.createPit2();

    // 2. Re-create device backends from CLI args.
    // The snapshot tells us what device types/slots existed, but backends
    // hold OS resources (fds) that must be opened fresh.
    var devices: [virtio.MAX_DEVICES]?VirtioMmio = .{null} ** virtio.MAX_DEVICES;
    var device_count = try initDevices(&devices, disk_path, tap_name, vsock_cid_str, vsock_uds_path);

    defer for (&devices) |*d| {
        if (d.*) |*dev| dev.deinit();
    };

    // 3. Create vCPU (must exist before snapshot.load() sets its registers)
    const vcpu_mmap_size = try kvm.getVcpuMmapSize();
    var vcpu = try vm.createVcpu(0, vcpu_mmap_size);
    defer vcpu.deinit();

    // 4. Load snapshot — restores vCPU registers, VM state, device transport
    // state, serial registers, and mmaps guest memory from file
    var serial = Serial.init(1);
    var mem = try snapshot.load(
        vmstate_path,
        mem_snap_path,
        &vcpu,
        &vm,
        &serial,
        &devices,
        &device_count,
    );
    defer mem.deinit();

    // 5. Wire up memory region so KVM can access restored guest RAM
    try vm.setMemoryRegion(0, 0, mem.alignedMem());

    // 6. Enter run loop — guest resumes execution from where it was paused
    log.info("entering VM run loop (restored)", .{});
    try runLoop(&vcpu, &serial, &vm, &mem, &devices, device_count, .{}, null);
}

/// Restore a VM from snapshot and run a post-boot API server.
/// Used by pool manager children: the VM runs in a thread while the main
/// thread handles API requests (pause/resume/snapshot/status).
fn restoreVmWithApi(
    vmstate_path: [*:0]const u8,
    mem_snap_path: [*:0]const u8,
    disk_path: ?[*:0]const u8,
    tap_name: ?[*:0]const u8,
    vsock_cid_str: ?[*:0]const u8,
    vsock_uds_path: ?[*:0]const u8,
    api_sock_path: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    log.info("flint restoring from snapshot (API mode)", .{});

    const kvm = try Kvm.open();
    defer kvm.deinit();

    const vm = try kvm.createVm();
    defer vm.deinit();

    try vm.setTssAddr(0xFFFBD000);
    try vm.setIdentityMapAddr(0xFFFBC000);
    try vm.createIrqChip();
    try vm.createPit2();

    var devices: [virtio.MAX_DEVICES]?VirtioMmio = .{null} ** virtio.MAX_DEVICES;
    var device_count = try initDevices(&devices, disk_path, tap_name, vsock_cid_str, vsock_uds_path);
    defer for (&devices) |*d| {
        if (d.*) |*dev| dev.deinit();
    };

    const vcpu_mmap_size = try kvm.getVcpuMmapSize();
    var vcpu = try vm.createVcpu(0, vcpu_mmap_size);
    defer vcpu.deinit();

    var serial = Serial.init(1);
    var mem = try snapshot.load(vmstate_path, mem_snap_path, &vcpu, &vm, &serial, &devices, &device_count);
    defer mem.deinit();

    try vm.setMemoryRegion(0, 0, mem.alignedMem());

    // Set up agent listener before the VM resumes so the socket exists
    // when the guest daemon connects over vsock
    var agent_conn: sandbox.AgentConn = .{};
    if (vsock_uds_path) |uds| {
        agent_conn = sandbox.AgentConn.listen(uds) catch |err| blk: {
            log.warn("agent listener failed: {}, sandbox API disabled", .{err});
            break :blk .{};
        };
    }
    defer agent_conn.deinit();

    var runtime = VmRuntime{
        .vcpu = &vcpu,
        .vm = &vm,
        .mem = &mem,
        .serial = &serial,
        .devices = &devices,
        .device_count = device_count,
        .snap_opts = .{},
    };

    log.info("entering VM run loop (restored, API mode)", .{});
    const thread = std.Thread.spawn(.{}, runLoopThread, .{&runtime}) catch |err| {
        log.err("failed to spawn run loop thread: {}", .{err});
        return error.ThreadSpawnFailed;
    };

    // Wait for the guest agent to connect (blocks up to ~10s)
    if (agent_conn.listen_fd >= 0) {
        agent_conn.accept() catch |err| {
            log.warn("agent accept failed: {}, sandbox API disabled", .{err});
        };
        if (agent_conn.fd >= 0) {
            runtime.agent = &agent_conn;
        }
    }

    api.servePostBoot(api_sock_path, io, allocator, &runtime) catch |err| {
        log.err("post-boot API error: {}", .{err});
    };

    thread.join();
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
        log.warn("setIrqLine high failed: {}", .{err});
        return; // skip de-assert if assert failed
    };
    vm.setIrqLine(irq, 0) catch |err| {
        log.warn("setIrqLine low failed: {}", .{err});
    };
}

const DeviceArray = [virtio.MAX_DEVICES]?VirtioMmio;

fn initDevices(
    devices: *DeviceArray,
    disk_path: ?[*:0]const u8,
    tap_name: ?[*:0]const u8,
    vsock_cid_str: ?[*:0]const u8,
    vsock_uds_path: ?[*:0]const u8,
) !u32 {
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

    if (vsock_cid_str) |cid_str| {
        const uds = vsock_uds_path orelse {
            log.err("--vsock-cid requires --vsock-uds", .{});
            return error.MissingVsockUds;
        };
        const cid_len = std.mem.indexOfSentinel(u8, 0, cid_str);
        const cid = std.fmt.parseUnsigned(u64, cid_str[0..cid_len], 10) catch {
            log.err("invalid vsock CID: {s}", .{cid_str[0..cid_len]});
            return error.InvalidCid;
        };
        const base = virtio.MMIO_BASE + @as(u64, device_count) * virtio.MMIO_SIZE;
        const irq = virtio.IRQ_BASE + device_count;
        devices[device_count] = try VirtioMmio.initVsock(base, irq, cid, uds);
        device_count += 1;
    }

    return device_count;
}

/// Thread entry point for run loop when running alongside the API server.
fn runLoopThread(runtime: *VmRuntime) void {
    runLoop(
        runtime.vcpu,
        runtime.serial,
        runtime.vm,
        runtime.mem,
        runtime.devices,
        runtime.device_count,
        runtime.snap_opts,
        runtime,
    ) catch |err| {
        log.err("run loop exited with error: {}", .{err});
    };
    runtime.exited.store(true, .release);
}

fn runLoop(vcpu: *Vcpu, serial: *Serial, vm: *const Vm, mem: *Memory, devices: *DeviceArray, device_count: u32, snap_opts: SnapshotOpts, runtime: ?*VmRuntime) !void {
    var exit_count: u64 = 0;
    while (true) {
        const exit_reason = vcpu.run() catch |err| {
            // immediate_exit causes KVM_RUN to return -EINTR (VmRunFailed).
            // Check if this was a pause request from the API thread.
            if (runtime) |rt| {
                if (rt.paused.load(.acquire)) {
                    rt.ack_paused.store(true, .release);
                    log.info("vCPU paused by API request", .{});
                    // Spin until unpaused — the API resume handler clears
                    // ack_paused then paused, so we just watch paused here
                    while (rt.paused.load(.acquire)) {
                        std.atomic.spinLoopHint();
                    }
                    log.info("vCPU resumed", .{});
                    vcpu.kvm_run.immediate_exit = 0;
                    continue;
                }
            }
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
                if (snap_opts.vmstate_path) |sp| {
                    // vCPU is stopped (just exited KVM_RUN), safe to snapshot
                    snapshot.save(sp, snap_opts.mem_path.?, vcpu, vm, mem, serial, devices, device_count) catch |err| {
                        log.err("snapshot save failed: {}", .{err});
                    };
                }
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
