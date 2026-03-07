// 16550 UART serial port emulation.
// Emulates COM1 at IO port 0x3F8, enough to capture kernel boot output.

const std = @import("std");

const log = std.log.scoped(.serial);

const Self = @This();

pub const COM1_PORT: u16 = 0x3F8;
pub const PORT_COUNT: u16 = 8;
pub const IRQ: u32 = 4;

// Register offsets from base port
const THR = 0; // Transmit Holding Register (write)
const RBR = 0; // Receive Buffer Register (read)
const IER = 1; // Interrupt Enable Register
const IIR = 2; // Interrupt Identification Register (read)
const FCR = 2; // FIFO Control Register (write)
const LCR = 3; // Line Control Register
const MCR = 4; // Modem Control Register
const LSR = 5; // Line Status Register
const MSR = 6; // Modem Status Register
const SCR = 7; // Scratch Register

// LSR bits
const LSR_DR = 0x01; // Data Ready
const LSR_THRE = 0x20; // Transmitter Holding Register Empty
const LSR_TEMT = 0x40; // Transmitter Empty

// IIR bits
const IIR_NO_INT = 0x01; // No interrupt pending

// LCR bits
const LCR_DLAB = 0x80; // Divisor Latch Access Bit

ier: u8 = 0,
iir: u8 = IIR_NO_INT,
lcr: u8 = 0,
mcr: u8 = 0,
lsr: u8 = LSR_THRE | LSR_TEMT,
msr: u8 = 0,
scr: u8 = 0,
dll: u8 = 0, // Divisor Latch Low (when DLAB=1)
dlh: u8 = 0, // Divisor Latch High (when DLAB=1)

output_fd: std.posix.fd_t,

pub fn init(output_fd: std.posix.fd_t) Self {
    return .{ .output_fd = output_fd };
}

pub fn handleIo(self: *Self, port: u16, data: []u8, is_write: bool) void {
    const offset = port - COM1_PORT;

    if (is_write) {
        self.writeReg(offset, data[0]);
    } else {
        data[0] = self.readReg(offset);
    }
}

fn writeReg(self: *Self, offset: u16, value: u8) void {
    if (self.lcr & LCR_DLAB != 0 and offset <= 1) {
        switch (offset) {
            0 => self.dll = value,
            1 => self.dlh = value,
            else => {},
        }
        return;
    }

    switch (offset) {
        THR => {
            // Write character to output
            const buf = [1]u8{value};
            _ = std.os.linux.write(self.output_fd, &buf, 1);
        },
        IER => self.ier = value & 0x0F,
        FCR => {}, // FIFO control - acknowledge but ignore
        LCR => self.lcr = value,
        MCR => self.mcr = value,
        MSR => self.msr = value,
        SCR => self.scr = value,
        else => log.warn("unhandled serial write: offset={} value=0x{x}", .{ offset, value }),
    }
}

fn readReg(self: *Self, offset: u16) u8 {
    if (self.lcr & LCR_DLAB != 0 and offset <= 1) {
        return switch (offset) {
            0 => self.dll,
            1 => self.dlh,
            else => 0,
        };
    }

    return switch (offset) {
        RBR => 0, // No input for now
        IER => self.ier,
        IIR => self.iir,
        LCR => self.lcr,
        MCR => self.mcr,
        LSR => self.lsr,
        MSR => self.msr,
        SCR => self.scr,
        else => blk: {
            log.warn("unhandled serial read: offset={}", .{offset});
            break :blk 0;
        },
    };
}
