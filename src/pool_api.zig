// HTTP API for the pool manager.
// Listens on a Unix socket via raw epoll, handles acquire/release/status.
// The epoll_wait timeout (1s) drives a maintenance tick that reaps children,
// health-checks VMs, respawns failures, and expires timed-out leases.

const std = @import("std");
const linux = std.os.linux;

const pool_mod = @import("pool.zig");

const log = std.log.scoped(.pool_api);

const TICK_MS = 1000; // maintenance cycle interval

/// Run the pool manager API loop. Blocks forever (or until interrupted).
pub fn serve(pool: *pool_mod.Pool) !void {
    const sock_path = pool.config.pool_sock;
    const sock_len = std.mem.indexOfSentinel(u8, 0, sock_path);
    const path = sock_path[0..sock_len];

    _ = linux.unlink(sock_path);

    const sock_rc: isize = @bitCast(linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
    ));
    if (sock_rc < 0) return error.SocketFailed;
    const listen_fd: linux.fd_t = @intCast(sock_rc);
    defer _ = linux.close(listen_fd);

    var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    for (0..path.len) |i| {
        addr.path[i] = @intCast(path[i]);
    }

    const bind_rc: isize = @bitCast(linux.bind(
        listen_fd,
        @ptrCast(&addr),
        @intCast(@sizeOf(linux.sockaddr.un)),
    ));
    if (bind_rc < 0) return error.BindFailed;

    const listen_rc: isize = @bitCast(linux.listen(listen_fd, 8));
    if (listen_rc < 0) return error.ListenFailed;

    // Epoll on the listener fd — timeout drives the maintenance tick
    const epoll_rc: isize = @bitCast(linux.epoll_create1(linux.EPOLL.CLOEXEC));
    if (epoll_rc < 0) return error.EpollFailed;
    const epoll_fd: linux.fd_t = @intCast(epoll_rc);
    defer _ = linux.close(epoll_fd);

    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = listen_fd },
    };
    const ctl_rc: isize = @bitCast(linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, listen_fd, &ev));
    if (ctl_rc < 0) return error.EpollCtlFailed;

    log.info("pool API listening on {s} (pool_size={})", .{ path, pool.config.pool_size });

    pool.fillPool();
    waitForReady(pool);

    while (true) {
        pool.reapChildren();
        pool.healthCheck();
        pool.respawnFailed();
        pool.expireVms();

        var events: [1]linux.epoll_event = undefined;
        const nfds: isize = @bitCast(linux.epoll_wait(epoll_fd, &events, 1, TICK_MS));
        if (nfds <= 0) continue;

        const client_rc: isize = @bitCast(linux.accept4(listen_fd, null, null, linux.SOCK.CLOEXEC));
        if (client_rc < 0) continue;
        const client_fd: linux.fd_t = @intCast(client_rc);
        defer _ = linux.close(client_fd);

        handleConnection(client_fd, pool);
    }
}

fn handleConnection(fd: linux.fd_t, pool: *pool_mod.Pool) void {
    var buf: [4096]u8 = undefined;
    var total: usize = 0;

    while (total < buf.len) {
        const rc: isize = @bitCast(linux.read(fd, buf[total..].ptr, buf.len - total));
        if (rc <= 0) return;
        total += @intCast(rc);

        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |header_end| {
            const body_start = header_end + 4;
            const content_len = parseContentLength(buf[0..header_end]) orelse 0;
            if (total >= body_start + content_len) break;
        }
    }

    const data = buf[0..total];

    // Parse "METHOD /path HTTP/1.1\r\n"
    const first_line_end = std.mem.indexOf(u8, data, "\r\n") orelse return;
    const first_line = data[0..first_line_end];

    const method_end = std.mem.indexOf(u8, first_line, " ") orelse return;
    const method = first_line[0..method_end];

    const target_start = method_end + 1;
    const target_end = std.mem.lastIndexOf(u8, first_line, " ") orelse return;
    if (target_end <= target_start) return;
    const target = first_line[target_start..target_end];

    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return;
    const body = data[header_end + 4 ..];

    log.info("{s} {s}", .{ method, target });

    if (eql(method, "POST") and eql(target, "/pool/acquire")) {
        handleAcquire(fd, pool, body);
    } else if (eql(method, "POST") and eql(target, "/pool/release")) {
        handleRelease(fd, pool, body);
    } else if (eql(method, "GET") and eql(target, "/pool/status")) {
        handleStatus(fd, pool);
    } else {
        sendResponse(fd, 404, "{\"fault_message\":\"resource not found\"}");
    }
}

fn handleAcquire(fd: linux.fd_t, pool: *pool_mod.Pool, body: []const u8) void {
    const slot_id = pool.acquire() orelse {
        sendResponse(fd, 503, "{\"fault_message\":\"pool exhausted\"}");
        return;
    };

    // Set deadline if timeout_ms provided
    if (body.len > 0) {
        if (parseTimeoutMs(body)) |timeout_ms| {
            pool.slots[slot_id].deadline_ns = pool_mod.timestamp() +
                @as(i128, timeout_ms) * 1_000_000;
        }
    }

    const slot = &pool.slots[slot_id];
    var resp_buf: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf, "{{\"id\":{},\"api_sock\":\"{s}\"}}", .{
        slot_id, slot.sockPath(),
    }) catch {
        _ = pool.release(slot_id);
        sendResponse(fd, 500, "{\"fault_message\":\"format failed\"}");
        return;
    };

    sendResponse(fd, 200, resp);
}

fn handleRelease(fd: linux.fd_t, pool: *pool_mod.Pool, body: []const u8) void {
    if (body.len == 0) {
        sendResponse(fd, 400, "{\"fault_message\":\"missing request body\"}");
        return;
    }

    const id = parseId(body) orelse {
        sendResponse(fd, 400, "{\"fault_message\":\"missing or invalid 'id' field\"}");
        return;
    };

    if (!pool.release(id)) {
        sendResponse(fd, 400, "{\"fault_message\":\"slot not in use\"}");
        return;
    }

    sendResponse(fd, 204, "");
}

fn handleStatus(fd: linux.fd_t, pool: *pool_mod.Pool) void {
    const s = pool.status();
    var buf: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf,
        \\{{"ready":{},"in_use":{},"starting":{},"failed":{},"pool_size":{}}}
    , .{ s.ready, s.in_use, s.starting, s.failed, pool.config.pool_size }) catch {
        sendResponse(fd, 500, "{\"fault_message\":\"format failed\"}");
        return;
    };

    sendResponse(fd, 200, resp);
}

// -- Helpers --

fn sendResponse(fd: linux.fd_t, status: u16, body: []const u8) void {
    const status_text = switch (status) {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "Unknown",
    };

    var buf: [4096]u8 = undefined;
    const header = std.fmt.bufPrint(&buf,
        "HTTP/1.1 {} {s}\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
        .{ status, status_text, body.len },
    ) catch return;

    writeAll(fd, header);
    if (body.len > 0) writeAll(fd, body);
}

fn writeAll(fd: linux.fd_t, data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const rc: isize = @bitCast(linux.write(fd, data[written..].ptr, data.len - written));
        if (rc <= 0) return;
        written += @intCast(rc);
    }
}

fn parseContentLength(headers: []const u8) ?usize {
    const needle = "Content-Length: ";
    const pos = std.mem.indexOf(u8, headers, needle) orelse return null;
    return parseNumAt(headers, pos + needle.len);
}

fn parseNumAt(data: []const u8, start: usize) ?usize {
    var end = start;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseUnsigned(usize, data[start..end], 10) catch null;
}

fn parseId(data: []const u8) ?u16 {
    const id_key = "\"id\"";
    const pos = std.mem.indexOf(u8, data, id_key) orelse return null;
    var i = pos + id_key.len;
    while (i < data.len and (data[i] == ' ' or data[i] == ':' or data[i] == '\t')) : (i += 1) {}
    var end = i;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseUnsigned(u16, data[i..end], 10) catch null;
}

fn parseTimeoutMs(data: []const u8) ?u64 {
    const key = "\"timeout_ms\"";
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    var i = pos + key.len;
    while (i < data.len and (data[i] == ' ' or data[i] == ':' or data[i] == '\t')) : (i += 1) {}
    var end = i;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseUnsigned(u64, data[i..end], 10) catch null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Poll until at least one VM is ready (or all have failed).
fn waitForReady(pool: *pool_mod.Pool) void {
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
