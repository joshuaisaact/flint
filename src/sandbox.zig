// Host-side sandbox agent connection.
// Listens on {vsock_uds}_1024 for the guest daemon to connect over vsock,
// then provides a request/response interface over the length-prefixed JSON protocol.

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.sandbox);

const AGENT_PORT: u32 = 1024;
const MAX_MSG: u32 = 16 * 1024 * 1024;

pub const AgentConn = struct {
    fd: linux.fd_t = -1,
    listen_fd: linux.fd_t = -1,
    uds_path: [128]u8 = undefined,
    uds_path_len: usize = 0,

    /// Create a Unix listener on {vsock_uds}_{AGENT_PORT}.
    /// Must be called BEFORE the VM boots so the path exists when the
    /// vsock device tries to connect.
    pub fn listen(vsock_uds: [*:0]const u8) !AgentConn {
        const uds_len = std.mem.indexOfSentinel(u8, 0, vsock_uds);

        var self: AgentConn = .{};
        const path = std.fmt.bufPrint(&self.uds_path, "{s}_{d}", .{
            vsock_uds[0..uds_len], AGENT_PORT,
        }) catch return error.PathTooLong;
        self.uds_path_len = path.len;

        // Unlink stale socket
        var z: [129]u8 = undefined;
        @memcpy(z[0..path.len], path);
        z[path.len] = 0;
        _ = linux.unlink(@ptrCast(z[0..path.len :0]));

        const sock_rc: isize = @bitCast(linux.socket(
            linux.AF.UNIX,
            linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
            0,
        ));
        if (sock_rc < 0) return error.SocketFailed;
        self.listen_fd = @intCast(sock_rc);

        var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        for (0..path.len) |i| {
            addr.path[i] = @intCast(path[i]);
        }

        const bind_rc: isize = @bitCast(linux.bind(
            self.listen_fd,
            @ptrCast(&addr),
            @intCast(@sizeOf(linux.sockaddr.un)),
        ));
        if (bind_rc < 0) {
            _ = linux.close(self.listen_fd);
            return error.BindFailed;
        }

        const listen_rc: isize = @bitCast(linux.listen(self.listen_fd, 1));
        if (listen_rc < 0) {
            _ = linux.close(self.listen_fd);
            return error.ListenFailed;
        }

        log.info("agent listener on {s}", .{path});
        return self;
    }

    /// Block until the guest daemon connects (or timeout after ~10s).
    pub fn accept(self: *AgentConn) !void {
        // Poll with timeout so we don't block forever if the VM dies
        var pfd = linux.pollfd{
            .fd = self.listen_fd,
            .events = linux.POLL.IN,
            .revents = 0,
        };
        const poll_rc: isize = @bitCast(linux.poll(@ptrCast(&pfd), 1, 10_000));
        if (poll_rc <= 0) {
            log.err("agent connection timed out", .{});
            return error.AcceptTimeout;
        }

        const rc: isize = @bitCast(linux.accept4(self.listen_fd, null, null, linux.SOCK.CLOEXEC));
        if (rc < 0) return error.AcceptFailed;
        self.fd = @intCast(rc);

        // Done with listener
        _ = linux.close(self.listen_fd);
        self.listen_fd = -1;

        log.info("agent connected", .{});
    }

    pub fn deinit(self: *AgentConn) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
        if (self.listen_fd >= 0) {
            _ = linux.close(self.listen_fd);
            self.listen_fd = -1;
        }
        // Clean up socket file
        if (self.uds_path_len > 0) {
            var z: [129]u8 = undefined;
            @memcpy(z[0..self.uds_path_len], self.uds_path[0..self.uds_path_len]);
            z[self.uds_path_len] = 0;
            _ = linux.unlink(@ptrCast(z[0..self.uds_path_len :0]));
        }
    }

    /// Send a command to the agent and return the response.
    pub fn command(self: *const AgentConn, payload: []const u8, resp_buf: []u8) ![]const u8 {
        if (self.fd < 0) return error.NotConnected;

        // Send: 4-byte LE length + payload
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(payload.len), .little);
        try writeAll(self.fd, &len_buf);
        try writeAll(self.fd, payload);

        // Receive: 4-byte LE length + response
        try readAll(self.fd, &len_buf);
        const resp_len = std.mem.readInt(u32, &len_buf, .little);
        if (resp_len > resp_buf.len or resp_len > MAX_MSG) return error.ResponseTooLarge;
        try readAll(self.fd, resp_buf[0..resp_len]);
        return resp_buf[0..resp_len];
    }
};

fn writeAll(fd: linux.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const rc: isize = @bitCast(linux.write(fd, data[written..].ptr, data[written..].len));
        if (rc <= 0) return error.WriteFailed;
        written += @intCast(rc);
    }
}

fn readAll(fd: linux.fd_t, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const rc: isize = @bitCast(linux.read(fd, buf[got..].ptr, buf[got..].len));
        if (rc < 0) return error.ReadFailed;
        if (rc == 0) return error.AgentDisconnected;
        got += @intCast(rc);
    }
}
