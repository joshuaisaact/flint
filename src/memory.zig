// Guest physical memory management.
// Allocates host memory via mmap and provides access for loading kernels
// and handling guest memory operations.

const std = @import("std");

const log = std.log.scoped(.memory);

const Self = @This();

/// The raw mmap'd memory region backing guest physical RAM.
mem: []align(std.heap.page_size_min) u8,

pub fn init(mem_size: usize) !Self {
    const mem = std.posix.mmap(
        null,
        mem_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return error.GuestMemoryAlloc;

    log.info("guest memory: {} MB at host 0x{x}", .{ mem_size / (1024 * 1024), @intFromPtr(mem.ptr) });
    return .{ .mem = mem };
}

pub fn deinit(self: Self) void {
    std.posix.munmap(self.mem);
}

pub fn size(self: Self) usize {
    return self.mem.len;
}

/// Get a slice of guest memory starting at the given guest physical address.
pub fn slice(self: Self, guest_addr: usize, len: usize) ![]u8 {
    if (guest_addr + len > self.mem.len) return error.GuestMemoryOutOfBounds;
    return self.mem[guest_addr..][0..len];
}

/// Get a pointer to a struct at the given guest physical address.
pub fn ptrAt(self: Self, comptime T: type, guest_addr: usize) !*T {
    if (guest_addr + @sizeOf(T) > self.mem.len) return error.GuestMemoryOutOfBounds;
    return @ptrCast(@alignCast(&self.mem[guest_addr]));
}

/// Write bytes into guest memory at the given guest physical address.
pub fn write(self: Self, guest_addr: usize, data: []const u8) !void {
    const dest = try self.slice(guest_addr, data.len);
    @memcpy(dest, data);
}

/// Get the aligned slice for passing to KVM setMemoryRegion.
pub fn alignedMem(self: Self) []align(std.heap.page_size_min) u8 {
    return self.mem;
}
