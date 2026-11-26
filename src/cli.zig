const std = @import("std");
const build_options = @import("build_options");
const config = @import("config.zig");

pub const version_text = "huen-mousenap " ++ build_options.version ++ "\n";

pub const usage_text =
    \\Usage:
    \\  huen-mousenap [run] [--config <path>] [--timeout <sec>] [--poll-interval <ms>] [--print-state]
    \\  huen-mousenap config [--config <path>] [--timeout <sec>] [--poll-interval <ms>]
    \\  huen-mousenap help
    \\  huen-mousenap version
    \\
    \\Options:
    \\  -c, --config <path>         Path to TOML config file
    \\  -t, --timeout <sec>         Idle timeout in seconds
    \\      --poll-interval <ms>    Poll interval in milliseconds
    \\      --print-state           Print hidden/visible on state changes
    \\  -h, --help                  Show this help message
    \\  -V, --version               Show version
    \\
;

pub const ConfigOptions = struct {
    config_path: ?[]const u8 = null,
    overrides: config.Overrides = .{},
};

pub const RunOptions = struct {
    config: ConfigOptions = .{},
    print_state: bool = false,
};

pub const Command = union(enum) {
    run: RunOptions,
    config: ConfigOptions,
    help,
    version,
};

pub const ParseError = error{
    UnknownCommand,
    UnknownFlag,
    MissingFlagValue,
    InvalidNumber,
    UnexpectedArgument,
};

pub const ParseResult = union(enum) {
    ok: Command,
    err: struct {
        kind: ParseError,
        detail: []const u8,
    },
};

pub fn parse(argv: []const [:0]const u8) ParseResult {
    const args: []const [:0]const u8 = if (argv.len > 0) argv[1..] else &.{};
    if (args.len == 0) {
        return .{ .ok = .{ .run = .{} } };
    }

    const first: []const u8 = args[0];
    if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        if (args.len > 1) {
            return .{ .err = .{ .kind = error.UnexpectedArgument, .detail = args[1] } };
        }
        return .{ .ok = .help };
    }
    if (std.mem.eql(u8, first, "version") or std.mem.eql(u8, first, "-V") or std.mem.eql(u8, first, "--version")) {
        if (args.len > 1) {
            return .{ .err = .{ .kind = error.UnexpectedArgument, .detail = args[1] } };
        }
        return .{ .ok = .version };
    }
    if (std.mem.eql(u8, first, "config")) {
        return parseOptions(args[1..], false);
    }
    if (std.mem.eql(u8, first, "run")) {
        return parseOptions(args[1..], true);
    }
    if (std.mem.startsWith(u8, first, "-")) {
        return parseOptions(args, true);
    }

    return .{ .err = .{ .kind = error.UnknownCommand, .detail = first } };
}

fn parseOptions(args: []const [:0]const u8, is_run: bool) ParseResult {
    var options: RunOptions = .{};
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .{ .ok = .help };
        }
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            return .{ .ok = .version };
        }
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            index += 1;
            if (index >= args.len) {
                return .{ .err = .{ .kind = error.MissingFlagValue, .detail = arg } };
            }
            options.config.config_path = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--timeout")) {
            index += 1;
            if (index >= args.len) {
                return .{ .err = .{ .kind = error.MissingFlagValue, .detail = arg } };
            }
            const parsed = std.fmt.parseFloat(f64, args[index]) catch {
                return .{ .err = .{ .kind = error.InvalidNumber, .detail = args[index] } };
            };
            options.config.overrides.timeout_seconds = parsed;
            continue;
        }
        if (std.mem.eql(u8, arg, "--poll-interval")) {
            index += 1;
            if (index >= args.len) {
                return .{ .err = .{ .kind = error.MissingFlagValue, .detail = arg } };
            }
            const parsed = std.fmt.parseInt(u64, args[index], 10) catch {
                return .{ .err = .{ .kind = error.InvalidNumber, .detail = args[index] } };
            };
            options.config.overrides.poll_interval_ms = parsed;
            continue;
        }
        if (is_run and std.mem.eql(u8, arg, "--print-state")) {
            options.print_state = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            return .{ .err = .{ .kind = error.UnknownFlag, .detail = arg } };
        }
        return .{ .err = .{ .kind = error.UnexpectedArgument, .detail = arg } };
    }

    if (is_run) {
        return .{ .ok = .{ .run = options } };
    }
    return .{ .ok = .{ .config = options.config } };
}
