// Vcpu: wraps a KVM vCPU fd.
// Provides register access and the VM run loop.

const std = @import("std");
const abi = @import("abi.zig");
const c = abi.c;
const Kvm = @import("system.zig");

const log = std.log.scoped(.vcpu);

const Self = @This();

fd: std.posix.fd_t,
kvm_run: *volatile c.kvm_run,
kvm_run_mmap_size: usize,

pub fn create(vm_fd: std.posix.fd_t, vcpu_id: u32, mmap_size: usize) !Self {
    const fd: i32 = @intCast(try abi.ioctl(vm_fd, c.KVM_CREATE_VCPU, vcpu_id));
    errdefer abi.close(fd);

    const mapped = std.posix.mmap(
        null,
        mmap_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    ) catch return error.MmapFailed;

    const kvm_run: *volatile c.kvm_run = @ptrCast(@alignCast(mapped.ptr));

    log.info("vCPU {} created (fd={})", .{ vcpu_id, fd });
    return .{
        .fd = fd,
        .kvm_run = kvm_run,
        .kvm_run_mmap_size = mmap_size,
    };
}

pub fn deinit(self: Self) void {
    const ptr: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(@constCast(@volatileCast(self.kvm_run))));
    std.posix.munmap(ptr[0..self.kvm_run_mmap_size]);
    abi.close(self.fd);
}

pub fn getRegs(self: Self) !c.kvm_regs {
    var regs: c.kvm_regs = undefined;
    try abi.ioctlVoid(self.fd, c.KVM_GET_REGS, @intFromPtr(&regs));
    return regs;
}

pub fn setRegs(self: Self, regs: *const c.kvm_regs) !void {
    try abi.ioctlVoid(self.fd, c.KVM_SET_REGS, @intFromPtr(regs));
}

pub fn getSregs(self: Self) !c.kvm_sregs {
    var sregs: c.kvm_sregs = undefined;
    try abi.ioctlVoid(self.fd, c.KVM_GET_SREGS, @intFromPtr(&sregs));
    return sregs;
}

pub fn setSregs(self: Self, sregs: *const c.kvm_sregs) !void {
    try abi.ioctlVoid(self.fd, c.KVM_SET_SREGS, @intFromPtr(sregs));
}

/// Execute the vCPU until it exits. Returns the exit reason.
pub fn run(self: Self) !u32 {
    try abi.ioctlVoid(self.fd, c.KVM_RUN, 0);
    return self.kvm_run.exit_reason;
}

/// Get the IO exit data (valid when exit_reason == KVM_EXIT_IO).
pub fn getIoData(self: Self) IoExit {
    const io = self.kvm_run.unnamed_0.io;
    const base: [*]u8 = @constCast(@ptrCast(@volatileCast(self.kvm_run)));
    return .{
        .direction = io.direction,
        .port = io.port,
        .size = io.size,
        .count = io.count,
        .data = base + io.data_offset,
    };
}

pub fn setCpuid(self: Self, cpuid: *Kvm.CpuidBuffer) !void {
    try abi.ioctlVoid(self.fd, c.KVM_SET_CPUID2, @intFromPtr(cpuid));
}

pub const IoExit = struct {
    direction: u8,
    port: u16,
    size: u8,
    count: u32,
    data: [*]u8,
};
