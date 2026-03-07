// Linux kernel loader.
// Loads a bzImage into guest memory following the x86 Linux boot protocol.

const std = @import("std");
const params = @import("params.zig");
const Memory = @import("../memory.zig");

const log = std.log.scoped(.loader);
const linux = std.os.linux;

pub const LoadResult = struct {
    /// Entry point (guest physical address of protected-mode kernel).
    entry_addr: u64,
    /// Where boot_params is in guest memory.
    boot_params_addr: u64,
};

/// Read an entire file into memory using linux syscalls.
fn readFile(path: [*:0]const u8) ![]u8 {
    const fd: i32 = @bitCast(@as(u32, @truncate(linux.open(path, .{ .ACCMODE = .RDONLY }, 0))));
    if (fd < 0) return error.OpenFailed;
    defer _ = linux.close(fd);

    // Get file size via statx
    var stx: linux.Statx = undefined;
    const stat_rc = linux.statx(fd, "", @as(u32, linux.AT.EMPTY_PATH), .{}, &stx);
    const stat_signed: isize = @bitCast(stat_rc);
    if (stat_signed < 0) return error.StatFailed;
    const file_size: usize = @intCast(stx.size);

    const buf = try std.heap.page_allocator.alloc(u8, file_size);
    errdefer std.heap.page_allocator.free(buf);

    var total: usize = 0;
    while (total < file_size) {
        const rc = linux.read(fd, buf.ptr + total, file_size - total);
        const signed: isize = @bitCast(rc);
        if (signed <= 0) break;
        total += rc;
    }

    return buf[0..total];
}

/// Load a bzImage from disk into guest memory.
pub fn loadBzImage(mem: *Memory, kernel_path: [*:0]const u8, cmdline: []const u8) !LoadResult {
    const kernel_data = try readFile(kernel_path);
    defer std.heap.page_allocator.free(kernel_data);

    if (kernel_data.len < 0x1F1 + @sizeOf(params.SetupHeader)) {
        return error.KernelTooSmall;
    }

    // Parse the setup header at offset 0x1F1
    const hdr: *const params.SetupHeader = @ptrCast(@alignCast(&kernel_data[0x1F1]));

    if (hdr.header != params.HDRS_MAGIC) {
        log.err("invalid bzImage: missing HdrS magic (got 0x{x})", .{hdr.header});
        return error.InvalidKernel;
    }

    log.info("boot protocol version: {}.{}", .{ hdr.version >> 8, hdr.version & 0xFF });

    if (hdr.version < 0x0200) {
        log.err("boot protocol version too old: 0x{x}", .{hdr.version});
        return error.UnsupportedProtocol;
    }

    // Number of 512-byte setup sectors (0 means 4)
    const setup_sects: u32 = if (hdr.setup_sects == 0) 4 else hdr.setup_sects;
    const setup_size = (setup_sects + 1) * 512; // +1 for the boot sector
    const kernel_offset = setup_size;
    const kernel_size = kernel_data.len - kernel_offset;

    log.info("setup sectors: {}, kernel size: {} bytes", .{ setup_sects, kernel_size });

    if (hdr.loadflags & params.LOADED_HIGH == 0) {
        log.err("kernel does not support loading high", .{});
        return error.UnsupportedKernel;
    }

    // Copy protected-mode kernel code to 1MB
    try mem.write(params.KERNEL_ADDR, kernel_data[kernel_offset..]);
    log.info("kernel loaded at guest 0x{x} ({} bytes)", .{ params.KERNEL_ADDR, kernel_size });

    // Copy command line
    if (cmdline.len > 0) {
        try mem.write(params.CMDLINE_ADDR, cmdline);
        // Null-terminate
        const term = try mem.slice(params.CMDLINE_ADDR + cmdline.len, 1);
        term[0] = 0;
    }

    // Set up boot_params (zero page) -- work with a slice starting at BOOT_PARAMS_ADDR
    const bp = try mem.slice(params.BOOT_PARAMS_ADDR, params.BOOT_PARAMS_SIZE);
    @memset(bp, 0);

    // Copy the original setup header into boot_params at the correct offset
    // OFF_ constants are offsets within the 4096-byte boot_params struct
    const hdr_bytes = std.mem.asBytes(hdr);
    @memcpy(bp[params.OFF_SETUP_HEADER..][0..hdr_bytes.len], hdr_bytes);

    // Patch the fields we need to set
    const bp_hdr: *params.SetupHeader = @ptrCast(@alignCast(&bp[params.OFF_SETUP_HEADER]));
    bp_hdr.type_of_loader = 0xFF; // undefined loader
    bp_hdr.loadflags |= params.CAN_USE_HEAP;
    bp_hdr.heap_end_ptr = 0xFE00;
    bp_hdr.cmd_line_ptr = params.CMDLINE_ADDR;

    // Set up e820 memory map
    const e820_ptr: *[128]params.E820Entry = @ptrCast(@alignCast(&bp[params.OFF_E820_TABLE]));
    e820_ptr[0] = .{ .addr = 0, .size = 0xA0000, .type_ = params.E820Entry.RAM }; // 640KB conventional
    e820_ptr[1] = .{ .addr = 0x100000, .size = mem.size() - 0x100000, .type_ = params.E820Entry.RAM }; // rest from 1MB
    bp[params.OFF_E820_ENTRIES] = 2;

    log.info("boot_params at guest 0x{x}, cmdline at 0x{x}", .{ params.BOOT_PARAMS_ADDR, params.CMDLINE_ADDR });

    return .{
        .entry_addr = params.KERNEL_ADDR,
        .boot_params_addr = params.BOOT_PARAMS_ADDR,
    };
}
