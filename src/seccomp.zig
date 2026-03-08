// Seccomp BPF filter for sandboxing the VMM process.
// Whitelists the minimum syscalls needed to run a KVM VM with
// virtio devices and an API socket. Everything else kills the process.

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.seccomp);

// Seccomp constants (stable kernel ABI — hardcoded to avoid Zig stdlib
// compilation issues with AUDIT.ARCH enum on 0.16-dev)
const SECCOMP_SET_MODE_FILTER: u32 = 1;
const SECCOMP_RET_KILL_PROCESS: u32 = 0x80000000;
const SECCOMP_RET_ALLOW: u32 = 0x7FFF0000;
const SECCOMP_RET_LOG: u32 = 0x7FFC0000;
const AUDIT_ARCH_X86_64: u32 = 0xC000003E; // EM_X86_64(62) | __AUDIT_ARCH_64BIT | __AUDIT_ARCH_LE

// seccomp_data field offsets (stable ABI: nr at 0, arch at 4)
const DATA_OFF_NR: u32 = 0;
const DATA_OFF_ARCH: u32 = 4;

// Classic BPF instruction (struct sock_filter — not in Zig stdlib)
const SockFilter = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

// Classic BPF program descriptor (struct sock_fprog — not in Zig stdlib)
const SockFprog = extern struct {
    len: u16,
    filter: [*]const SockFilter,
};

// BPF instruction encoding constants (not in Zig stdlib)
const BPF_LD: u16 = 0x00;
const BPF_JMP: u16 = 0x05;
const BPF_RET: u16 = 0x06;
const BPF_W: u16 = 0x00;
const BPF_ABS: u16 = 0x20;
const BPF_K: u16 = 0x00;
const BPF_JEQ: u16 = 0x10;

fn bpf_stmt(code: u16, k: u32) SockFilter {
    return .{ .code = code, .jt = 0, .jf = 0, .k = k };
}

fn bpf_jump(code: u16, k: u32, jt: u8, jf: u8) SockFilter {
    return .{ .code = code, .jt = jt, .jf = jf, .k = k };
}

// x86_64 syscall numbers — minimum whitelist for Flint.
const allowed_syscalls = [_]u32{
    // Core I/O
    0,   // read
    1,   // write
    3,   // close
    8,   // lseek
    16,  // ioctl (KVM, FIONBIO, TUNSETIFF)
    17,  // pread64 (virtio-blk)
    18,  // pwrite64 (virtio-blk)
    19,  // readv (virtio-net TAP)
    20,  // writev (virtio-net TAP)
    72,  // fcntl (O_NONBLOCK)
    74,  // fsync (disk flush)
    87,  // unlink (API socket cleanup)
    257, // openat

    // Memory
    9,   // mmap
    10,  // mprotect
    11,  // munmap
    12,  // brk
    25,  // mremap

    // Networking / API socket
    41,  // socket
    42,  // connect (vsock UDS)
    44,  // sendto
    45,  // recvfrom
    49,  // bind
    50,  // listen
    288, // accept4

    // Threading
    24,  // sched_yield
    56,  // clone
    158, // arch_prctl (TLS)
    186, // gettid
    202, // futex
    218, // set_tid_address
    273, // set_robust_list (thread cleanup)

    // Signals
    13,  // rt_sigaction
    14,  // rt_sigprocmask
    15,  // rt_sigreturn
    131, // sigaltstack

    // Process lifecycle
    60,  // exit
    200, // tkill
    219, // restart_syscall (kernel injects after interrupted sleep)
    231, // exit_group

    // Snapshot / file metadata
    77,  // ftruncate
    262, // newfstatat

    // Clock / random
    228, // clock_gettime
    318, // getrandom (HashMap seeding)
};

/// Build a BPF whitelist filter at comptime. Checks arch first (reject
/// x32/compat ABI), then tests each allowed syscall number.
fn buildFilter(comptime syscalls: []const u32, comptime default_action: u32) [syscalls.len + 6]SockFilter {
    var f: [syscalls.len + 6]SockFilter = undefined;

    // Verify architecture is x86_64
    f[0] = bpf_stmt(BPF_LD | BPF_W | BPF_ABS, DATA_OFF_ARCH);
    f[1] = bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0);
    f[2] = bpf_stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);

    // Load syscall number
    f[3] = bpf_stmt(BPF_LD | BPF_W | BPF_ABS, DATA_OFF_NR);

    // Each allowed syscall: match → jump to ALLOW, miss → fall through
    for (syscalls, 0..) |nr, i| {
        const jump_to_allow: u8 = @intCast(syscalls.len - i);
        f[4 + i] = bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, nr, jump_to_allow, 0);
    }

    f[4 + syscalls.len] = bpf_stmt(BPF_RET | BPF_K, default_action);
    f[4 + syscalls.len + 1] = bpf_stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);

    return f;
}

pub const kill_filter = buildFilter(&allowed_syscalls, SECCOMP_RET_KILL_PROCESS);
pub const log_filter = buildFilter(&allowed_syscalls, SECCOMP_RET_LOG);

/// Install the seccomp BPF filter. After this, unlisted syscalls kill
/// the process (or log in audit mode for development).
pub fn install(audit: bool) !void {
    const rc1 = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    if (rc1 != 0) {
        log.err("prctl(NO_NEW_PRIVS) failed", .{});
        return error.PrctlFailed;
    }

    const filter = if (audit) &log_filter else &kill_filter;
    const prog = SockFprog{
        .len = @intCast(filter.len),
        .filter = filter,
    };

    const rc2 = linux.seccomp(SECCOMP_SET_MODE_FILTER, 0, &prog);
    const signed: isize = @bitCast(rc2);
    if (signed < 0) {
        log.err("seccomp(SET_MODE_FILTER) failed: {}", .{signed});
        return error.SeccompFailed;
    }

    if (audit) {
        log.warn("seccomp in AUDIT mode — violations logged, not killed", .{});
    } else {
        log.info("seccomp filter installed ({} syscalls whitelisted)", .{allowed_syscalls.len});
    }
}
