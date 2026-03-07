// Kvm: wraps the /dev/kvm system fd.
// Provides system-level operations: version check, VM creation.

const std = @import("std");
const abi = @import("abi.zig");
const c = abi.c;
const Vm = @import("vm.zig");

const log = std.log.scoped(.kvm);

const Self = @This();

fd: std.posix.fd_t,

pub fn open() !Self {
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/dev/kvm", .{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    }, 0) catch |err| {
        log.err("failed to open /dev/kvm: {}", .{err});
        return error.KvmUnavailable;
    };

    // Check API version
    const version = try abi.ioctl(fd, c.KVM_GET_API_VERSION, 0);
    if (version != 12) {
        log.err("unexpected KVM API version: {}, expected 12", .{version});
        abi.close(fd);
        return error.UnsupportedApiVersion;
    }

    log.info("KVM API version {}", .{version});
    return .{ .fd = fd };
}

pub fn deinit(self: Self) void {
    abi.close(self.fd);
}

pub fn createVm(self: Self) !Vm {
    return Vm.create(self.fd);
}

/// Check if a KVM extension is supported.
pub fn checkExtension(self: Self, extension: u32) !bool {
    const ret = try abi.ioctl(self.fd, c.KVM_CHECK_EXTENSION, extension);
    return ret > 0;
}
