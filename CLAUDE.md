# Flint — Claude Code Standards

## Language: Zig 0.16+

## CLI Argument Parsing

Use comptime struct reflection instead of if/else chains. Define a struct with fields matching CLI flags (hyphens in field names via `@"quoted-name"`), then use `inline for` over `std.meta.fields()` to match and assign:

```zig
const CliArgs = struct {
    @"api-sock": ?[*:0]const u8 = null,
    restore: bool = false,
    @"vmstate-path": [*:0]const u8 = "default.vmstate",

    fn parse(self: *CliArgs, flag: []const u8, iter: *std.process.Args.Iterator) bool {
        inline for (std.meta.fields(CliArgs)) |field| {
            if (std.mem.eql(u8, flag, "--" ++ field.name)) {
                if (field.type == bool) {
                    @field(self, field.name) = true;
                } else {
                    @field(self, field.name) = iter.next() orelse {
                        std.debug.print("--" ++ field.name ++ " requires an argument\n", .{});
                        std.process.exit(1);
                    };
                }
                return true;
            }
        }
        return false;
    }
};
```

Adding a new flag = adding a struct field. Zero boilerplate. This is the TigerBeetle-pioneered pattern and the direction of the Zig stdlib (see zig issue #24601).

Handle positional args and subcommands (`pool`, kernel cmdline with `=`) outside the struct parser since they don't follow `--flag` patterns.

## Comptime Validation

Use `comptime` blocks and `std.debug.assert` to catch invariants at compile time rather than runtime. Examples:
- `comptime { std.debug.assert(@popCount(MAX_QUEUE_SIZE) == 1); }` — enforce power-of-2
- `comptime { std.debug.assert(@sizeOf(SockaddrVm) == 16); }` — enforce ABI layout
- Validate struct sizes match on-wire formats, no unintended padding

When a size or layout matters for correctness (packed structs, virtio headers, boot protocol offsets), assert it at comptime.

## Static Allocation

This project already uses static/stack buffers everywhere — don't introduce dynamic allocation. Guest memory is a single `mmap` at startup, device arrays are fixed-size, connection tables are fixed-size, the seccomp filter is built at comptime. The only heap use is temporary (`page_allocator` in the loader for kernel/initrd files, freed immediately) and stdlib JSON parsing in the API server.

Don't add `ArrayList`, `HashMap`, or allocator-backed containers unless there's no fixed upper bound.

## Zero Dependencies

This project uses no external dependencies — pure Zig + Linux syscalls. Keep it that way. No third-party arg parsers, no libc in the guest agent.

## Error Handling

- Use explicit error returns, not `unreachable`, for anything a guest or external input can trigger
- `errdefer` for cleanup on all fd-acquiring paths
- `catch unreachable` is acceptable only when the allocator/setup guarantees success (e.g., fixed-buffer formatting)
- Domain-specific error names: `error.GuestMemoryOutOfBounds`, not `error.InvalidArgument`

## Design Principles

See DESIGN.md for the full list. Key ones for code changes:
- No global mutable state — all state flows through struct fields
- Fd-holding wrapper types with `deinit()` cleanup
- `unreachable` never for guest IO — log and ignore unknown accesses
- Tests from day one
- Use `inline for` + `std.meta.fields()` for repetitive struct-driven dispatch
