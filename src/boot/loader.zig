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

    // Parse the setup header at offset 0x1F1 (unaligned, so we copy it out)
    var hdr: params.SetupHeader = undefined;
    const hdr_src = kernel_data[0x1F1..][0..@sizeOf(params.SetupHeader)];
    @memcpy(std.mem.asBytes(&hdr), hdr_src);

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

    // Copy the ENTIRE setup header from the kernel image into boot_params.
    // The setup header extends from offset 0x1F1 well beyond our SetupHeader struct
    // (the kernel reads fields up to at least 0x264, e.g. init_size).
    // The setup header in the file spans from 0x1F1 to the end of the first sector+setup.
    const raw_hdr_max = @min(setup_size, params.BOOT_PARAMS_SIZE) - params.OFF_SETUP_HEADER;
    const src_hdr = kernel_data[params.OFF_SETUP_HEADER..][0..raw_hdr_max];
    @memcpy(bp[params.OFF_SETUP_HEADER..][0..raw_hdr_max], src_hdr);

    // Patch the specific fields we need to override
    // type_of_loader at boot_params offset 0x210
    bp[0x210] = 0xFF;
    // loadflags at boot_params offset 0x211
    bp[0x211] |= params.CAN_USE_HEAP;
    // heap_end_ptr at boot_params offset 0x224 (u16 LE)
    bp[0x224] = 0x00;
    bp[0x225] = 0xFE;
    // cmd_line_ptr at boot_params offset 0x228 (u32 LE)
    std.mem.writeInt(u32, bp[0x228..][0..4], params.CMDLINE_ADDR, .little);

    // Set up e820 memory map by writing raw bytes (20 bytes per entry, no padding)
    const e820_entries = [_]params.E820Entry{
        .{ .addr = 0, .size = 0x9FC00, .type_ = params.E820Entry.RAM }, // Conventional memory
        .{ .addr = 0x9FC00, .size = 0x400, .type_ = params.E820Entry.RESERVED }, // EBDA
        .{ .addr = 0xF0000, .size = 0x10000, .type_ = params.E820Entry.RESERVED }, // BIOS ROM
        .{ .addr = 0x100000, .size = mem.size() - 0x100000, .type_ = params.E820Entry.RAM }, // Main RAM
    };
    for (e820_entries, 0..) |entry, i| {
        const off = params.OFF_E820_TABLE + i * 20;
        std.mem.writeInt(u64, bp[off..][0..8], entry.addr, .little);
        std.mem.writeInt(u64, bp[off + 8 ..][0..8], entry.size, .little);
        std.mem.writeInt(u32, bp[off + 16 ..][0..4], entry.type_, .little);
    }
    bp[params.OFF_E820_ENTRIES] = e820_entries.len;

    log.info("boot_params at guest 0x{x}, cmdline at 0x{x}, e820 entries: {}", .{
        params.BOOT_PARAMS_ADDR, params.CMDLINE_ADDR, e820_entries.len,
    });

    return .{
        .entry_addr = params.KERNEL_ADDR,
        .boot_params_addr = params.BOOT_PARAMS_ADDR,
    };
}
