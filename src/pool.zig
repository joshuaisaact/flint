// VM pool manager: maintains a pool of pre-restored VMs from a snapshot.
// Each VM is a child Flint process in --restore mode with its own API socket.
// The pool manager spawns replacements as VMs are acquired and released.

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.pool);

const WNOHANG: u32 = 1;
pub const MAX_POOL_SIZE = 32;

pub const SlotState = enum {
    empty,
    starting,
    ready,
    in_use,
    failed,
};

pub const VmSlot = struct {
    state: SlotState = .empty,
    pid: linux.pid_t = 0,
    deadline_ns: i128 = 0, // CLOCK_MONOTONIC nanos, 0 = no timeout
    sock_path_buf: [128]u8 = undefined,
    sock_path_len: u8 = 0,

    disk_path_buf: [128]u8 = undefined,
    disk_path_len: u8 = 0,

    pub fn sockPath(self: *const VmSlot) []const u8 {
        return self.sock_path_buf[0..self.sock_path_len];
    }

    /// Remove the per-VM disk copy if one exists.
    pub fn unlinkDisk(self: *VmSlot) void {
        if (self.disk_path_len > 0) {
            var path_z: [129]u8 = undefined;
            const len = self.disk_path_len;
            @memcpy(path_z[0..len], self.disk_path_buf[0..len]);
            path_z[len] = 0;
            _ = linux.unlink(@ptrCast(path_z[0..len :0]));
            self.disk_path_len = 0;
        }
    }
};

pub const Config = struct {
    pool_size: u16,
    vmstate_path: [*:0]const u8,
    mem_path: [*:0]const u8,
    disk_path: ?[*:0]const u8 = null,
    jail_dir: ?[*:0]const u8 = null,
    jail_uid: ?[*:0]const u8 = null,
    jail_gid: ?[*:0]const u8 = null,
    pool_sock: [*:0]const u8,
    self_exe: [*:0]const u8, // argv[0] for re-exec
};

/// Current monotonic time in nanoseconds via raw syscall.
pub fn timestamp() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

pub const Pool = struct {
    slots: [MAX_POOL_SIZE]VmSlot = [_]VmSlot{.{}} ** MAX_POOL_SIZE,
    config: Config,

    pub fn init(config: Config) Pool {
        return .{ .config = config };
    }

    /// Spawn VMs for all empty slots up to pool_size.
    pub fn fillPool(self: *Pool) void {
        for (0..self.config.pool_size) |i| {
            if (self.slots[i].state == .empty) {
                self.spawnVm(@intCast(i));
            }
        }
    }

    /// Find a READY slot, mark it IN_USE, return its index.
    pub fn acquire(self: *Pool) ?u16 {
        for (0..self.config.pool_size) |i| {
            if (self.slots[i].state == .ready) {
                self.slots[i].state = .in_use;
                log.info("acquired slot {}", .{i});
                return @intCast(i);
            }
        }
        return null;
    }

    /// Kill the VM in a slot and mark it for respawn.
    pub fn release(self: *Pool, id: u16) bool {
        if (id >= self.config.pool_size) return false;
        const slot = &self.slots[id];
        if (slot.state != .in_use) return false;

        killSlot(slot);
        slot.state = .empty;
        slot.deadline_ns = 0;
        log.info("released slot {}", .{id});

        // Immediately start a replacement
        self.spawnVm(id);
        return true;
    }

    /// Count slots in each state.
    pub fn status(self: *const Pool) struct { ready: u16, in_use: u16, starting: u16, failed: u16 } {
        var ready: u16 = 0;
        var in_use: u16 = 0;
        var starting: u16 = 0;
        var failed: u16 = 0;
        for (0..self.config.pool_size) |i| {
            switch (self.slots[i].state) {
                .ready => ready += 1,
                .in_use => in_use += 1,
                .starting => starting += 1,
                .failed => failed += 1,
                .empty => {},
            }
        }
        return .{ .ready = ready, .in_use = in_use, .starting = starting, .failed = failed };
    }

    /// Reap exited children and update slot states.
    pub fn reapChildren(self: *Pool) void {
        while (true) {
            var wstatus: u32 = 0;
            const rc: isize = @bitCast(linux.waitpid(-1, &wstatus, WNOHANG)); // WNOHANG=1
            if (rc <= 0) break;

            const pid: linux.pid_t = @intCast(rc);
            for (0..self.config.pool_size) |i| {
                if (self.slots[i].pid == pid) {
                    const prev = self.slots[i].state;
                    if (prev == .starting or prev == .ready or prev == .in_use) {
                        log.warn("slot {} (pid {}) exited unexpectedly (was {})", .{ i, pid, @intFromEnum(prev) });
                        self.slots[i].state = .failed;
                    }
                    self.slots[i].pid = 0;
                    break;
                }
            }
        }
    }

    /// Check STARTING slots by connecting to their API socket.
    pub fn healthCheck(self: *Pool) void {
        for (0..self.config.pool_size) |i| {
            if (self.slots[i].state == .starting) {
                if (probeSocket(&self.slots[i])) {
                    self.slots[i].state = .ready;
                    log.info("slot {} ready (pid {})", .{ i, self.slots[i].pid });
                }
            }
        }
    }

    /// Kill VMs that have exceeded their deadline.
    pub fn expireVms(self: *Pool) void {
        const now = timestamp();
        for (0..self.config.pool_size) |i| {
            const slot = &self.slots[i];
            if (slot.state == .in_use and slot.deadline_ns > 0 and now >= slot.deadline_ns) {
                log.warn("slot {} expired (pid {}), killing", .{ i, slot.pid });
                killSlot(slot);
                slot.state = .empty;
                slot.deadline_ns = 0;
                self.spawnVm(@intCast(i));
            }
        }
    }

    /// Respawn failed slots.
    pub fn respawnFailed(self: *Pool) void {
        for (0..self.config.pool_size) |i| {
            if (self.slots[i].state == .failed) {
                self.slots[i].state = .empty;
                self.spawnVm(@intCast(i));
            }
        }
    }

    /// Clean up all slots on shutdown.
    pub fn shutdown(self: *Pool) void {
        for (0..self.config.pool_size) |i| {
            if (self.slots[i].pid != 0) {
                killSlot(&self.slots[i]);
            }
            // Unlink API socket
            if (self.slots[i].sock_path_len > 0) {
                var path_z: [129]u8 = undefined;
                const len = self.slots[i].sock_path_len;
                @memcpy(path_z[0..len], self.slots[i].sock_path_buf[0..len]);
                path_z[len] = 0;
                _ = linux.unlink(@ptrCast(path_z[0..len :0]));
            }
            // Unlink per-VM disk copy
            self.slots[i].unlinkDisk();
        }
    }

    fn killSlot(slot: *VmSlot) void {
        if (slot.pid != 0) {
            _ = linux.kill(slot.pid, linux.SIG.KILL);
            var wstatus: u32 = 0;
            _ = linux.waitpid(slot.pid, &wstatus, 0);
            slot.pid = 0;
        }
        slot.unlinkDisk();
    }

    fn spawnVm(self: *Pool, id: u16) void {
        const slot = &self.slots[id];

        // Build API socket path for this slot
        const sock_path_len = std.fmt.bufPrint(&slot.sock_path_buf, "/tmp/flint-pool-vm-{}.sock", .{id}) catch {
            slot.state = .failed;
            return;
        };
        slot.sock_path_len = @intCast(sock_path_len.len);

        // Unlink stale socket before spawning
        var sock_z: [129]u8 = undefined;
        @memcpy(sock_z[0..sock_path_len.len], sock_path_len);
        sock_z[sock_path_len.len] = 0;
        _ = linux.unlink(@ptrCast(sock_z[0..sock_path_len.len :0]));

        // Build argv for child: flint --restore --api-sock <path> --vmstate-path <x> --mem-path <y> ...
        var argv_buf: [32]?[*:0]const u8 = .{null} ** 32;
        var arg_strs: [8][128]u8 = undefined; // scratch for formatted strings
        var argc: usize = 0;

        argv_buf[argc] = self.config.self_exe;
        argc += 1;
        argv_buf[argc] = "--restore";
        argc += 1;
        argv_buf[argc] = "--api-sock";
        argc += 1;

        // API sock path needs to be null-terminated for execve
        @memcpy(arg_strs[0][0..sock_path_len.len], sock_path_len);
        arg_strs[0][sock_path_len.len] = 0;
        argv_buf[argc] = @ptrCast(arg_strs[0][0..sock_path_len.len :0]);
        argc += 1;

        argv_buf[argc] = "--vmstate-path";
        argc += 1;
        argv_buf[argc] = self.config.vmstate_path;
        argc += 1;
        argv_buf[argc] = "--mem-path";
        argc += 1;
        argv_buf[argc] = self.config.mem_path;
        argc += 1;

        if (self.config.disk_path) |dp| {
            // Create per-VM disk copy for write isolation (FICLONE on btrfs/XFS,
            // read/write fallback on ext4). Each VM gets its own CoW copy so
            // concurrent VMs don't corrupt a shared base image.
            const disk_path = std.fmt.bufPrint(&slot.disk_path_buf, "/tmp/flint-pool-vm-{}.disk", .{id}) catch {
                slot.state = .failed;
                return;
            };
            slot.disk_path_len = @intCast(disk_path.len);

            var disk_z: [129]u8 = undefined;
            @memcpy(disk_z[0..disk_path.len], disk_path);
            disk_z[disk_path.len] = 0;

            copyDisk(dp, @ptrCast(disk_z[0..disk_path.len :0])) catch |err| {
                log.err("failed to copy disk for slot {}: {}", .{ id, err });
                slot.disk_path_len = 0;
                slot.state = .failed;
                return;
            };

            argv_buf[argc] = "--disk";
            argc += 1;
            @memcpy(arg_strs[1][0..disk_path.len], disk_path);
            arg_strs[1][disk_path.len] = 0;
            argv_buf[argc] = @ptrCast(arg_strs[1][0..disk_path.len :0]);
            argc += 1;
        }

        if (self.config.jail_dir) |jd| {
            argv_buf[argc] = "--jail";
            argc += 1;
            argv_buf[argc] = jd;
            argc += 1;
            if (self.config.jail_uid) |u| {
                argv_buf[argc] = "--jail-uid";
                argc += 1;
                argv_buf[argc] = u;
                argc += 1;
            }
            if (self.config.jail_gid) |g| {
                argv_buf[argc] = "--jail-gid";
                argc += 1;
                argv_buf[argc] = g;
                argc += 1;
            }
        }

        argv_buf[argc] = null; // null-terminate argv

        const fork_rc: isize = @bitCast(linux.fork());
        if (fork_rc < 0) {
            log.err("fork failed for slot {}: errno {}", .{ id, -fork_rc });
            slot.unlinkDisk();
            slot.state = .failed;
            return;
        }

        if (fork_rc == 0) {
            // Child: close inherited fds (pool listener, etc) before exec
            _ = linux.close_range(3, std.math.maxInt(linux.fd_t), .{ .UNSHARE = false, .CLOEXEC = false });

            const envp = [_:null]?[*:0]const u8{null};
            _ = linux.execve(
                self.config.self_exe,
                @ptrCast(&argv_buf),
                @ptrCast(&envp),
            );
            // execve failed — exit child immediately
            linux.exit_group(1);
        }

        // Parent
        slot.pid = @intCast(fork_rc);
        slot.state = .starting;
        log.info("spawned slot {} (pid {})", .{ id, slot.pid });
    }

    /// Copy a disk image for per-VM isolation. Tries FICLONE (instant CoW
    /// reflink on btrfs/XFS) first, falls back to a read/write copy.
    pub fn copyDisk(src: [*:0]const u8, dst: [*:0]const u8) !void {
        const FICLONE: u32 = 0x40049409;

        const src_rc: isize = @bitCast(linux.open(src, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
        if (src_rc < 0) return error.OpenFailed;
        const src_fd: i32 = @intCast(src_rc);
        defer _ = linux.close(src_fd);

        const dst_rc: isize = @bitCast(linux.open(dst, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
            .CLOEXEC = true,
        }, 0o644));
        if (dst_rc < 0) return error.CreateFailed;
        const dst_fd: i32 = @intCast(dst_rc);
        defer _ = linux.close(dst_fd);

        // Try FICLONE (instant CoW on btrfs/XFS)
        const clone_rc: isize = @bitCast(linux.ioctl(dst_fd, FICLONE, @as(usize, @intCast(src_fd))));
        if (clone_rc == 0) return;

        // Fallback: read/write copy
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const rrc: isize = @bitCast(linux.read(src_fd, &buf, buf.len));
            if (rrc == 0) break;
            if (rrc < 0) return error.CopyFailed;
            const n: usize = @intCast(rrc);
            var written: usize = 0;
            while (written < n) {
                const wrc: isize = @bitCast(linux.write(dst_fd, buf[written..].ptr, n - written));
                if (wrc <= 0) return error.CopyFailed;
                written += @intCast(wrc);
            }
        }
    }

    /// Verify a slot's VM is actually responsive by sending GET /vm to its
    /// API socket and checking for an HTTP 200 response. This is strictly
    /// better than a TCP connect probe — a crashed VM that bound the socket
    /// before dying would pass a connect check but fail here.
    fn probeSocket(slot: *const VmSlot) bool {
        const path = slot.sockPath();
        if (path.len == 0) return false;

        const sock_rc: isize = @bitCast(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
        if (sock_rc < 0) return false;
        const fd: linux.fd_t = @intCast(sock_rc);
        defer _ = linux.close(fd);

        var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        if (path.len > addr.path.len) return false;
        for (0..path.len) |j| {
            addr.path[j] = @intCast(path[j]);
        }

        const connect_rc: isize = @bitCast(linux.connect(
            fd,
            @ptrCast(&addr),
            @intCast(@sizeOf(linux.sockaddr.un)),
        ));
        if (connect_rc < 0) return false;

        // Send a minimal HTTP request to verify the API is responsive
        const req = "GET /vm HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var written: usize = 0;
        while (written < req.len) {
            const rc: isize = @bitCast(linux.write(fd, req[written..].ptr, req.len - written));
            if (rc <= 0) return false;
            written += @intCast(rc);
        }

        // Read enough of the response to check for "200"
        var buf: [64]u8 = undefined;
        const read_rc: isize = @bitCast(linux.read(fd, &buf, buf.len));
        if (read_rc < 12) return false; // "HTTP/1.1 200" is 12 chars minimum
        const resp = buf[0..@intCast(read_rc)];

        return std.mem.startsWith(u8, resp, "HTTP/1.1 200") or
            std.mem.startsWith(u8, resp, "HTTP/1.0 200");
    }
};
