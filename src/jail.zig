// Process jail: mount namespace, pivot_root, device nodes, privilege drop.
// Called early in VMM startup (before opening /dev/kvm) so the entire
// VMM lifecycle runs inside the jail.

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.jail);

const S_IFCHR: u32 = 0o020000;
// Device major/minor encoding: (major << 8) | minor (valid for major < 4096, minor < 256)
const DEV_KVM = (10 << 8) | 232;
const DEV_NET_TUN = (10 << 8) | 200;

fn check(rc: usize, comptime what: []const u8) !void {
    const signed: isize = @bitCast(rc);
    if (signed < 0) {
        log.err("{s} failed: errno {}", .{ what, -signed });
        return error.JailSetupFailed;
    }
}

pub const Config = struct {
    jail_dir: [*:0]const u8,
    uid: u32,
    gid: u32,
    cgroup: ?[*:0]const u8 = null,
    need_tun: bool = false,
};

pub fn setup(config: Config) !void {
    // Close inherited FDs above stderr to prevent leaks from parent
    try check(linux.close_range(3, std.math.maxInt(linux.fd_t), .{ .UNSHARE = false, .CLOEXEC = false }), "close_range");

    // Cgroup: move process into cgroup before pivot_root (needs /sys/fs/cgroup)
    if (config.cgroup) |cg| {
        try setupCgroup(cg);
    }

    // New mount namespace — isolates our mount table from the host
    try check(linux.unshare(linux.CLONE.NEWNS), "unshare(NEWNS)");

    // Stop mount event propagation to parent namespace
    try check(linux.mount(null, "/", null, linux.MS.SLAVE | linux.MS.REC, 0), "mount(MS_SLAVE)");

    // Bind-mount jail dir on itself (pivot_root requires a mount point)
    try check(linux.mount(config.jail_dir, config.jail_dir, null, linux.MS.BIND | linux.MS.REC, 0), "mount(MS_BIND)");

    // Swap filesystem root: jail_dir becomes /, old root goes to old_root
    try check(linux.chdir(config.jail_dir), "chdir(jail)");
    try check(linux.mkdir("old_root", 0o700), "mkdir(old_root)");
    try check(linux.pivot_root(".", "old_root"), "pivot_root");
    try check(linux.chdir("/"), "chdir(/)");

    // Detach host filesystem — no way back
    try check(linux.umount2("old_root", linux.MNT.DETACH), "umount2(old_root)");
    _ = linux.rmdir("old_root");

    // Create device nodes inside the jail (only what the VMM needs)
    try check(linux.mkdir("dev", 0o755), "mkdir(/dev)");
    try check(linux.mknod("dev/kvm", S_IFCHR | 0o666, DEV_KVM), "mknod(/dev/kvm)");

    if (config.need_tun) {
        try check(linux.mkdir("dev/net", 0o755), "mkdir(/dev/net)");
        try check(linux.mknod("dev/net/tun", S_IFCHR | 0o666, DEV_NET_TUN), "mknod(/dev/net/tun)");
    }

    // Drop privileges — last step requiring root
    try check(linux.setgid(config.gid), "setgid");
    try check(linux.setuid(config.uid), "setuid");

    log.info("jail active: uid={} gid={}", .{ config.uid, config.gid });
}

fn setupCgroup(name: [*:0]const u8) !void {
    const name_len = std.mem.indexOfSentinel(u8, 0, name);
    const prefix = "/sys/fs/cgroup/";

    var path_buf: [256]u8 = undefined;
    if (prefix.len + name_len >= path_buf.len) return error.CgroupPathTooLong;
    @memcpy(path_buf[0..prefix.len], prefix);
    @memcpy(path_buf[prefix.len..][0..name_len], name[0..name_len]);
    path_buf[prefix.len + name_len] = 0;
    const cg_path: [*:0]const u8 = @ptrCast(path_buf[0 .. prefix.len + name_len :0]);

    // Create cgroup directory (may already exist)
    _ = linux.mkdir(cg_path, 0o755);

    // Move current process into the cgroup
    const procs_suffix = "/cgroup.procs";
    var procs_buf: [280]u8 = undefined;
    const procs_len = prefix.len + name_len + procs_suffix.len;
    @memcpy(procs_buf[0 .. prefix.len + name_len], path_buf[0 .. prefix.len + name_len]);
    @memcpy(procs_buf[prefix.len + name_len ..][0..procs_suffix.len], procs_suffix);
    procs_buf[procs_len] = 0;

    var pid_buf: [20]u8 = undefined;
    const pid: u64 = @intCast(linux.getpid());
    const pid_str = std.fmt.bufPrint(&pid_buf, "{}", .{pid}) catch return error.FormatFailed;

    try writeFile(@ptrCast(procs_buf[0..procs_len :0]), pid_str);
    log.info("joined cgroup: {s}", .{name});
}

fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY }, 0);
    const fd: isize = @bitCast(rc);
    if (fd < 0) return error.OpenFailed;
    defer _ = linux.close(@intCast(@as(usize, @bitCast(fd))));
    _ = linux.write(@intCast(@as(usize, @bitCast(fd))), data.ptr, data.len);
}
