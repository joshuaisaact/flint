// Unit tests for flint.
// Run with: zig build test

const std = @import("std");
const Memory = @import("memory.zig");
const boot_params = @import("boot/params.zig");
const Serial = @import("devices/serial.zig");

// -- Memory tests --

test "memory: basic slice and write" {
    var mem = try Memory.init(4096);
    defer mem.deinit();

    const data = "hello";
    try mem.write(0, data);
    const s = try mem.slice(0, 5);
    try std.testing.expectEqualStrings("hello", s);
}

test "memory: write at offset" {
    var mem = try Memory.init(4096);
    defer mem.deinit();

    try mem.write(100, "test");
    const s = try mem.slice(100, 4);
    try std.testing.expectEqualStrings("test", s);
}

test "memory: out of bounds slice" {
    var mem = try Memory.init(4096);
    defer mem.deinit();

    try std.testing.expectError(error.GuestMemoryOutOfBounds, mem.slice(4090, 10));
}

test "memory: overflow in bounds check" {
    var mem = try Memory.init(4096);
    defer mem.deinit();

    // guest_addr + len would overflow usize
    try std.testing.expectError(error.GuestMemoryOutOfBounds, mem.slice(std.math.maxInt(usize), 1));
}

test "memory: ptrAt alignment check" {
    var mem = try Memory.init(4096);
    defer mem.deinit();

    // Aligned access should work
    const ptr = try mem.ptrAt(u64, 0);
    ptr.* = 42;
    try std.testing.expectEqual(@as(u64, 42), ptr.*);

    // Misaligned access should fail
    try std.testing.expectError(error.GuestMemoryMisaligned, mem.ptrAt(u64, 3));
}

test "memory: ptrAt out of bounds" {
    var mem = try Memory.init(64);
    defer mem.deinit();

    try std.testing.expectError(error.GuestMemoryOutOfBounds, mem.ptrAt(u64, 60));
}

test "memory: size" {
    var mem = try Memory.init(8192);
    defer mem.deinit();

    try std.testing.expectEqual(@as(usize, 8192), mem.size());
}

// -- Boot params tests --

test "params: SetupHeader is packed with correct bit size" {
    // The setup header must be exactly the sum of its field sizes (75 bytes = 600 bits)
    // so we can memcpy it from the bzImage at an unaligned offset.
    try std.testing.expectEqual(@as(usize, 600), @bitSizeOf(boot_params.SetupHeader));
}

test "params: E820Entry is 20 bytes packed" {
    try std.testing.expectEqual(@as(usize, 160), @bitSizeOf(boot_params.E820Entry));
}

test "params: offset constants are within boot_params" {
    try std.testing.expect(boot_params.OFF_E820_ENTRIES < boot_params.BOOT_PARAMS_SIZE);
    try std.testing.expect(boot_params.OFF_SETUP_HEADER < boot_params.BOOT_PARAMS_SIZE);
    try std.testing.expect(boot_params.OFF_E820_TABLE < boot_params.BOOT_PARAMS_SIZE);
    try std.testing.expect(boot_params.OFF_TYPE_OF_LOADER < boot_params.BOOT_PARAMS_SIZE);
    try std.testing.expect(boot_params.OFF_RAMDISK_IMAGE < boot_params.BOOT_PARAMS_SIZE);
}

test "params: HDRS_MAGIC matches 'HdrS'" {
    const magic = std.mem.bytesToValue(u32, "HdrS");
    try std.testing.expectEqual(boot_params.HDRS_MAGIC, magic);
}

test "params: memory addresses don't overlap" {
    // boot_params (0x7000-0x7FFF) must not overlap cmdline (0x20000+)
    try std.testing.expect(boot_params.BOOT_PARAMS_ADDR + boot_params.BOOT_PARAMS_SIZE <= boot_params.CMDLINE_ADDR);
    // cmdline must be below kernel at 1MB
    try std.testing.expect(boot_params.CMDLINE_ADDR < boot_params.KERNEL_ADDR);
}

// -- Serial tests --

test "serial: write outputs to THR" {
    // We can't easily capture fd output in a test, but we can verify
    // that writing to THR with IER_THRE enabled triggers an IRQ.
    var serial = Serial.init(-1); // invalid fd, write will fail silently

    // Enable THRE interrupt
    const ier_data = [1]u8{0x02}; // IER_THRE
    serial.handleIo(Serial.COM1_PORT + 1, @constCast(&ier_data), true);

    // Write a character
    const thr_data = [1]u8{'A'};
    serial.handleIo(Serial.COM1_PORT, @constCast(&thr_data), true);

    // Should have pending IRQ
    try std.testing.expect(serial.hasPendingIrq());
    // Second call should be false (consumed)
    try std.testing.expect(!serial.hasPendingIrq());
}

test "serial: LSR always reports transmitter ready" {
    var serial = Serial.init(-1);

    var data = [1]u8{0};
    serial.handleIo(Serial.COM1_PORT + 5, &data, false); // read LSR
    try std.testing.expect(data[0] & 0x60 == 0x60); // THRE + TEMT
}

test "serial: DLAB mode accesses divisor latch" {
    var serial = Serial.init(-1);

    // Set DLAB
    const lcr_data = [1]u8{0x80};
    serial.handleIo(Serial.COM1_PORT + 3, @constCast(&lcr_data), true);

    // Write divisor latch low
    const dll_data = [1]u8{0x42};
    serial.handleIo(Serial.COM1_PORT, @constCast(&dll_data), true);

    // Read it back
    var read_data = [1]u8{0};
    serial.handleIo(Serial.COM1_PORT, &read_data, false);
    try std.testing.expectEqual(@as(u8, 0x42), read_data[0]);
}

test "serial: IIR read clears THR empty interrupt" {
    var serial = Serial.init(-1);

    // Enable THRE interrupt
    const ier_data = [1]u8{0x02};
    serial.handleIo(Serial.COM1_PORT + 1, @constCast(&ier_data), true);

    // Read IIR -- should show THR empty (0x02 in low nibble)
    var iir_data = [1]u8{0};
    serial.handleIo(Serial.COM1_PORT + 2, &iir_data, false);
    try std.testing.expectEqual(@as(u8, 0x02), iir_data[0] & 0x0F);

    // Read IIR again -- should be cleared to no-interrupt (0x01)
    serial.handleIo(Serial.COM1_PORT + 2, &iir_data, false);
    try std.testing.expectEqual(@as(u8, 0x01), iir_data[0] & 0x0F);
}

test "serial: MSR is read-only" {
    var serial = Serial.init(-1);

    // Read default MSR (should have DCD+DSR+CTS)
    var data = [1]u8{0};
    serial.handleIo(Serial.COM1_PORT + 6, &data, false);
    const original = data[0];
    try std.testing.expect(original != 0); // has some bits set

    // Try to write MSR
    const write_data = [1]u8{0x00};
    serial.handleIo(Serial.COM1_PORT + 6, @constCast(&write_data), true);

    // Read back -- should be unchanged
    serial.handleIo(Serial.COM1_PORT + 6, &data, false);
    try std.testing.expectEqual(original, data[0]);
}

test "serial: scratch register is read-write" {
    var serial = Serial.init(-1);

    const write_data = [1]u8{0xAB};
    serial.handleIo(Serial.COM1_PORT + 7, @constCast(&write_data), true);

    var read_data = [1]u8{0};
    serial.handleIo(Serial.COM1_PORT + 7, &read_data, false);
    try std.testing.expectEqual(@as(u8, 0xAB), read_data[0]);
}
