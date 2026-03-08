// Virtio-MMIO transport layer.
// Implements the MMIO register interface (v2/modern) for a single device.

const std = @import("std");
const Memory = @import("../../memory.zig");
const virtio = @import("../virtio.zig");
const Queue = @import("queue.zig");
const Blk = @import("blk.zig");

const log = std.log.scoped(.virtio_mmio);

const Self = @This();

// Device identity
device_id: u32,
mmio_base: u64,
irq: u32,

// Device state
status: u8 = 0,
device_features_sel: u32 = 0,
driver_features_sel: u32 = 0,
driver_features: u64 = 0,
queue_sel: u32 = 0,
interrupt_status: u32 = 0,
config_generation: u32 = 0,

// Single queue for virtio-blk (requestq)
queue: Queue = .{},

// Backend
blk: Blk,

pub fn initBlk(mmio_base: u64, irq: u32, disk_path: [*:0]const u8) !Self {
    const blk = try Blk.init(disk_path);
    log.info("virtio-blk at MMIO 0x{x} IRQ {}", .{ mmio_base, irq });
    return .{
        .device_id = virtio.DEVICE_ID_BLOCK,
        .mmio_base = mmio_base,
        .irq = irq,
        .blk = blk,
    };
}

pub fn deinit(self: *Self) void {
    self.blk.deinit();
}

fn reset(self: *Self) void {
    self.status = 0;
    self.device_features_sel = 0;
    self.driver_features_sel = 0;
    self.driver_features = 0;
    self.queue_sel = 0;
    self.interrupt_status = 0;
    self.queue.reset();
}

fn selectedQueue(self: *Self) ?*Queue {
    if (self.queue_sel == 0) return &self.queue;
    return null;
}

fn setLow32(target: *u64, val: u32) void {
    target.* = (target.* & 0xFFFFFFFF00000000) | val;
}

fn setHigh32(target: *u64, val: u32) void {
    target.* = (target.* & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
}

/// Handle an MMIO read. Returns the value to write back to the guest.
pub fn handleRead(self: *Self, offset: u64, data: []u8) void {
    if (offset >= virtio.MMIO_CONFIG) {
        // Device-specific config space
        self.blk.readConfig(offset - virtio.MMIO_CONFIG, data);
        return;
    }

    // All standard registers are 32-bit
    if (data.len != 4) {
        @memset(data, 0);
        return;
    }

    const val: u32 = switch (offset) {
        virtio.MMIO_MAGIC_VALUE => virtio.MAGIC_VALUE,
        virtio.MMIO_VERSION => virtio.MMIO_VERSION_2,
        virtio.MMIO_DEVICE_ID => self.device_id,
        virtio.MMIO_VENDOR_ID => virtio.VENDOR_ID,
        virtio.MMIO_DEVICE_FEATURES => val: {
            const features = Blk.deviceFeatures();
            break :val if (self.device_features_sel == 0)
                @truncate(features)
            else
                @truncate(features >> 32);
        },
        virtio.MMIO_QUEUE_NUM_MAX => val: {
            if (self.selectedQueue()) |_| {
                break :val Queue.MAX_QUEUE_SIZE;
            }
            break :val 0;
        },
        virtio.MMIO_QUEUE_READY => val: {
            if (self.selectedQueue()) |q| {
                break :val @intFromBool(q.ready);
            }
            break :val 0;
        },
        virtio.MMIO_INTERRUPT_STATUS => self.interrupt_status,
        virtio.MMIO_STATUS => self.status,
        virtio.MMIO_CONFIG_GENERATION => self.config_generation,
        else => 0,
    };

    std.mem.writeInt(u32, data[0..4], val, .little);
}

/// Handle an MMIO write from the guest.
pub fn handleWrite(self: *Self, offset: u64, data: []const u8) void {
    if (offset >= virtio.MMIO_CONFIG) {
        // Config space writes (not used for blk, ignore)
        return;
    }

    if (data.len != 4) return;

    const val = std.mem.readInt(u32, data[0..4], .little);

    switch (offset) {
        virtio.MMIO_DEVICE_FEATURES_SEL => self.device_features_sel = val,
        virtio.MMIO_DRIVER_FEATURES => {
            if (self.driver_features_sel == 0) {
                setLow32(&self.driver_features, val);
            } else {
                setHigh32(&self.driver_features, val);
            }
        },
        virtio.MMIO_DRIVER_FEATURES_SEL => self.driver_features_sel = val,
        virtio.MMIO_QUEUE_SEL => self.queue_sel = val,
        virtio.MMIO_QUEUE_NUM => {
            if (self.selectedQueue()) |q| {
                const size: u16 = @intCast(val & 0xFFFF);
                // Validate: must be non-zero, power of 2, and <= MAX_QUEUE_SIZE
                if (size == 0 or size > Queue.MAX_QUEUE_SIZE or @popCount(size) != 1) {
                    log.warn("rejected invalid queue size: {}", .{size});
                } else {
                    q.size = size;
                }
            }
        },
        virtio.MMIO_QUEUE_READY => {
            if (self.selectedQueue()) |q| {
                q.ready = val == 1;
                if (q.ready) {
                    log.info("queue {} ready (size={})", .{ self.queue_sel, q.size });
                }
            }
        },
        virtio.MMIO_QUEUE_NOTIFY => {
            // Handled by caller (triggers queue processing in run loop)
        },
        virtio.MMIO_INTERRUPT_ACK => {
            self.interrupt_status &= ~val;
        },
        virtio.MMIO_STATUS => {
            if (val == 0) {
                self.reset();
                log.info("device reset", .{});
            } else {
                self.status = @truncate(val);
                if (self.status & virtio.STATUS_FAILED != 0) {
                    log.err("driver set FAILED status", .{});
                }
            }
        },
        virtio.MMIO_QUEUE_DESC_LOW => {
            if (self.selectedQueue()) |q| setLow32(&q.desc_addr, val);
        },
        virtio.MMIO_QUEUE_DESC_HIGH => {
            if (self.selectedQueue()) |q| setHigh32(&q.desc_addr, val);
        },
        virtio.MMIO_QUEUE_DRIVER_LOW => {
            if (self.selectedQueue()) |q| setLow32(&q.avail_addr, val);
        },
        virtio.MMIO_QUEUE_DRIVER_HIGH => {
            if (self.selectedQueue()) |q| setHigh32(&q.avail_addr, val);
        },
        virtio.MMIO_QUEUE_DEVICE_LOW => {
            if (self.selectedQueue()) |q| setLow32(&q.used_addr, val);
        },
        virtio.MMIO_QUEUE_DEVICE_HIGH => {
            if (self.selectedQueue()) |q| setHigh32(&q.used_addr, val);
        },
        else => {},
    }
}

/// Process pending requests on the virtqueue.
/// Returns true if any work was done (interrupt should be raised).
/// Reads avail_idx once and caps processing to queue size to prevent DoS.
pub fn processQueues(self: *Self, mem: *Memory) bool {
    if (self.status & virtio.STATUS_DRIVER_OK == 0) return false;
    if (!self.queue.isReady()) return false;

    var did_work = false;
    // Process at most queue.size entries per notify to bound work
    var processed: u16 = 0;
    while (processed < self.queue.size) : (processed += 1) {
        const head = self.queue.popAvail(mem) catch |err| {
            log.err("popAvail failed: {}", .{err});
            break;
        } orelse break;

        self.blk.processRequest(mem, &self.queue, head) catch |err| {
            log.err("block request failed: {}", .{err});
            // Push a zero-length entry so the guest reclaims the descriptor
            self.queue.pushUsed(mem, head, 0) catch {};
        };
        did_work = true;
    }

    if (did_work) {
        self.interrupt_status |= virtio.INT_USED_RING;
    }
    return did_work;
}

/// Check if address falls within this device's MMIO range.
pub fn matchesAddr(self: Self, addr: u64) bool {
    return addr >= self.mmio_base and addr < self.mmio_base + virtio.MMIO_SIZE;
}
