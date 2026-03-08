// HTTP API for the pool manager.
// Listens on a Unix socket, handles acquire/release/status requests.
// Runs the main loop: accept connections, health-check VMs, reap children.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const linux = std.os.linux;

const Pool = @import("pool.zig");

const log = std.log.scoped(.pool_api);

/// Run the pool manager API loop. Blocks forever (or until interrupted).
pub fn serve(pool: *Pool.Pool, io: Io) !void {
    const sock_path = pool.config.pool_sock;
    const sock_len = std.mem.indexOfSentinel(u8, 0, sock_path);
    const path = sock_path[0..sock_len];

    // Unlink stale socket
    _ = linux.unlink(sock_path);

    const addr = try Io.net.UnixAddress.init(path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    log.info("pool API listening on {s} (pool_size={})", .{ path, pool.config.pool_size });

    // Spawn initial pool
    pool.fillPool();

    // Wait for initial VMs to become ready before accepting requests
    waitForReady(pool);

    // Main loop: blocking accept, maintenance between connections
    while (true) {
        // Maintenance between requests
        pool.reapChildren();
        pool.healthCheck();
        pool.respawnFailed();

        const stream = server.accept(io) catch |err| {
            log.err("accept failed: {}", .{err});
            continue;
        };

        handleConnection(stream, io, pool) catch |err| {
            log.err("connection error: {}", .{err});
        };

        stream.close(io);
    }
}

fn handleConnection(stream: Io.net.Stream, io: Io, pool: *Pool.Pool) !void {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buf);
    var stream_writer = stream.writer(io, &write_buf);
    var http_server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        var request = http_server.receiveHead() catch |err| {
            if (err == error.EndOfStream) return;
            return;
        };

        handleRequest(&request, pool);

        if (!request.head.keep_alive) return;
    }
}

fn handleRequest(request: *http.Server.Request, pool: *Pool.Pool) void {
    const method = request.head.method;
    const target = request.head.target;

    log.info("{s} {s}", .{ @tagName(method), target });

    if (method == .POST and std.mem.eql(u8, target, "/pool/acquire")) {
        handleAcquire(request, pool);
    } else if (method == .POST and std.mem.eql(u8, target, "/pool/release")) {
        handleRelease(request, pool);
    } else if (method == .GET and std.mem.eql(u8, target, "/pool/status")) {
        handleStatus(request, pool);
    } else {
        respondError(request, .not_found, "resource not found");
    }
}

fn handleAcquire(request: *http.Server.Request, pool: *Pool.Pool) void {
    const slot_id = pool.acquire() orelse {
        respondError(request, .service_unavailable, "pool exhausted");
        return;
    };

    const slot = &pool.slots[slot_id];
    var buf: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "{{\"id\":{},\"api_sock\":\"{s}\"}}", .{
        slot_id, slot.sockPath(),
    }) catch {
        respondError(request, .internal_server_error, "format failed");
        return;
    };

    request.respond(resp, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch {
        // Client didn't receive the socket path — release slot back to pool
        _ = pool.release(slot_id);
        return;
    };
}

fn handleRelease(request: *http.Server.Request, pool: *Pool.Pool) void {
    // Read body for id
    var body_buf: [256]u8 = undefined;
    const body = readBody(request, &body_buf) catch {
        respondError(request, .bad_request, "failed to read body");
        return;
    };

    const data = body orelse {
        respondError(request, .bad_request, "missing request body");
        return;
    };

    // Simple manual parse for {"id": N}
    const id = parseId(data) orelse {
        respondError(request, .bad_request, "missing or invalid 'id' field");
        return;
    };

    if (!pool.release(id)) {
        respondError(request, .bad_request, "slot not in use");
        return;
    }

    request.respond("", .{ .status = .no_content }) catch {};
}

fn handleStatus(request: *http.Server.Request, pool: *Pool.Pool) void {
    const s = pool.status();
    var buf: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf,
        \\{{"ready":{},"in_use":{},"starting":{},"failed":{},"pool_size":{}}}
    , .{ s.ready, s.in_use, s.starting, s.failed, pool.config.pool_size }) catch {
        respondError(request, .internal_server_error, "format failed");
        return;
    };

    request.respond(resp, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch {};
}

fn parseId(data: []const u8) ?u16 {
    // Find "id" field value — simple scan for "id": or "id" :
    const id_key = "\"id\"";
    const pos = std.mem.indexOf(u8, data, id_key) orelse return null;
    var i = pos + id_key.len;

    // Skip whitespace and colon
    while (i < data.len and (data[i] == ' ' or data[i] == ':' or data[i] == '\t')) : (i += 1) {}

    // Parse number
    var end = i;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == i) return null;

    return std.fmt.parseUnsigned(u16, data[i..end], 10) catch null;
}

fn readBody(request: *http.Server.Request, buf: []u8) !?[]const u8 {
    const content_length = request.head.content_length orelse return null;
    if (content_length == 0) return null;
    if (content_length > buf.len) return error.BodyTooLarge;

    var reader_buf: [1024]u8 = undefined;
    var body_reader = request.readerExpectNone(&reader_buf);
    const len: usize = @intCast(content_length);
    body_reader.readSliceAll(buf[0..len]) catch return error.ReadFailed;
    return buf[0..len];
}

fn respondError(request: *http.Server.Request, status_code: http.Status, msg: []const u8) void {
    var buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"fault_message\":\"{s}\"}}", .{msg}) catch {
        request.respond("", .{ .status = status_code }) catch {};
        return;
    };

    request.respond(body, .{
        .status = status_code,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch {};
}

/// Poll until at least one VM is ready (or all have failed).
fn waitForReady(pool: *Pool.Pool) void {
    const max_attempts = 500; // 500 * 20ms = 10s max
    var attempts: u32 = 0;
    while (attempts < max_attempts) : (attempts += 1) {
        pool.reapChildren();
        pool.healthCheck();

        const s = pool.status();
        if (s.ready > 0) {
            log.info("pool ready: {}/{} VMs available", .{ s.ready, pool.config.pool_size });
            return;
        }
        if (s.starting == 0 and s.ready == 0) {
            log.err("all VMs failed to start", .{});
            return;
        }

        const ts = linux.timespec{ .sec = 0, .nsec = 20_000_000 };
        _ = linux.nanosleep(&ts, null);
    }
    log.warn("timed out waiting for pool VMs to become ready", .{});
}
