// Vm: wraps the KVM VM fd.
// Provides VM-level operations: memory regions, vCPU creation, IRQ chip, PIT.

const std = @import("std");
const abi = @import("abi.zig");
const c = abi.c;
const Vcpu = @import("vcpu.zig");

const log = std.log.scoped(.vm);

const Self = @This();

fd: std.posix.fd_t,

pub fn create(kvm_fd: std.posix.fd_t) !Self {
    const fd: i32 = @intCast(try abi.ioctl(kvm_fd, c.KVM_CREATE_VM, 0));
    log.info("VM created (fd={})", .{fd});
    return .{ .fd = fd };
}

pub fn deinit(self: Self) void {
    abi.close(self.fd);
}

/// Register a guest physical memory region backed by host memory.
pub fn setMemoryRegion(self: Self, slot: u32, guest_phys_addr: u64, memory: []align(std.heap.page_size_min) u8) !void {
    var region = c.kvm_userspace_memory_region{
        .slot = slot,
        .flags = 0,
        .guest_phys_addr = guest_phys_addr,
        .memory_size = memory.len,
        .userspace_addr = @intFromPtr(memory.ptr),
    };
    try abi.ioctlVoid(self.fd, c.KVM_SET_USER_MEMORY_REGION, @intFromPtr(&region));
    log.info("memory region: slot={} guest=0x{x} size=0x{x}", .{ slot, guest_phys_addr, memory.len });
}

/// Create a vCPU with the given ID.
pub fn createVcpu(self: Self, vcpu_id: u32, vcpu_mmap_size: usize) !Vcpu {
    return Vcpu.create(self.fd, vcpu_id, vcpu_mmap_size);
}

/// Set TSS address (required on Intel before running vCPUs).
pub fn setTssAddr(self: Self, addr: u32) !void {
    try abi.ioctlVoid(self.fd, c.KVM_SET_TSS_ADDR, addr);
}

/// Set identity map address (required on Intel).
pub fn setIdentityMapAddr(self: Self, addr: u64) !void {
    var a = addr;
    try abi.ioctlVoid(self.fd, c.KVM_SET_IDENTITY_MAP_ADDR, @intFromPtr(&a));
}

/// Create the in-kernel IRQ chip (PIC + IOAPIC).
pub fn createIrqChip(self: Self) !void {
    try abi.ioctlVoid(self.fd, c.KVM_CREATE_IRQCHIP, 0);
    log.info("in-kernel IRQ chip created", .{});
}

/// Create the in-kernel PIT (i8254 timer).
pub fn createPit2(self: Self) !void {
    var pit_config = std.mem.zeroes(c.kvm_pit_config);
    pit_config.flags = c.KVM_PIT_SPEAKER_DUMMY;
    try abi.ioctlVoid(self.fd, c.KVM_CREATE_PIT2, @intFromPtr(&pit_config));
    log.info("in-kernel PIT created", .{});
}

/// Inject an IRQ line level change.
pub fn setIrqLine(self: Self, irq: u32, level: u32) !void {
    var irq_level: c.kvm_irq_level = .{};
    irq_level.unnamed_0.irq = irq;
    irq_level.level = level;
    try abi.ioctlVoid(self.fd, c.KVM_IRQ_LINE, @intFromPtr(&irq_level));
}
