const std = @import("std");
const toml = @import("toml.zig");

pub const max_timeout_seconds: f64 = 86400.0;
pub const min_poll_interval_ms: u64 = 5;
pub const max_poll_interval_ms: u64 = 1000;

pub const Settings = struct {
    timeout_ns: u64 = 3 * std.time.ns_per_s,
    poll_interval_ns: u64 = 25 * std.time.ns_per_ms,
};

pub const Overrides = struct {
    timeout_seconds: ?f64 = null,
    poll_interval_ms: ?u64 = null,
};

pub const Error = error{
    DuplicateKey,
    UnknownKey,
    WrongType,
    InvalidTimeout,
    InvalidPollInterval,
    FileNotFound,
    ReadFailed,
    OutOfMemory,
} || toml.Error;

pub fn defaultPath(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !?[]u8 {
    if (environ_map.get("XDG_CONFIG_HOME")) |xdg_home| {
        if (xdg_home.len > 0 and std.fs.path.isAbsolute(xdg_home)) {
            return try std.fs.path.join(allocator, &.{ xdg_home, "huen-mousenap", "config.toml" });
        }
    }
    if (environ_map.get("HOME")) |home| {
        if (home.len > 0) {
            return try std.fs.path.join(allocator, &.{ home, ".config", "huen-mousenap", "config.toml" });
        }
    }
    return null;
}

pub fn parse(source: []const u8) Error!Settings {
    var entries = toml.Iterator.init(source);
    var settings: Settings = .{};
    var seen_timeout = false;
    var seen_poll = false;

    while (try entries.next()) |entry| {
        if (std.mem.eql(u8, entry.key, "timeout_seconds")) {
            if (seen_timeout) return error.DuplicateKey;
            seen_timeout = true;
            const timeout_sec: f64 = switch (entry.value) {
                .float => |val| val,
                .integer => |val| @floatFromInt(val),
                .non_numeric => return error.WrongType,
            };
            settings.timeout_ns = try timeoutSecondsToNs(timeout_sec);
            continue;
        }
        if (std.mem.eql(u8, entry.key, "poll_interval_ms")) {
            if (seen_poll) return error.DuplicateKey;
            seen_poll = true;
            const poll_ms: i64 = switch (entry.value) {
                .integer => |val| val,
                .float, .non_numeric => return error.WrongType,
            };
            if (poll_ms < 0) return error.InvalidPollInterval;
            settings.poll_interval_ns = try pollIntervalMsToNs(@intCast(poll_ms));
            continue;
        }
        return error.UnknownKey;
    }

    return settings;
}

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    explicit_path: ?[]const u8,
    overrides: Overrides,
) Error!Settings {
    var settings: Settings = .{};

    if (explicit_path) |path| {
        const bytes = readConfigFile(allocator, io, path) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return error.ReadFailed,
        };
        defer allocator.free(bytes);
        settings = try parse(bytes);
    } else if (try defaultPath(allocator, environ_map)) |resolved_path| {
        defer allocator.free(resolved_path);
        const maybe_bytes = readConfigFile(allocator, io, resolved_path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return error.ReadFailed,
        };
        if (maybe_bytes) |bytes| {
            defer allocator.free(bytes);
            settings = try parse(bytes);
        }
    }

    if (overrides.timeout_seconds) |timeout_sec| {
        settings.timeout_ns = try timeoutSecondsToNs(timeout_sec);
    }
    if (overrides.poll_interval_ms) |poll_ms| {
        settings.poll_interval_ns = try pollIntervalMsToNs(poll_ms);
    }

    return settings;
}

fn readConfigFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
}

fn timeoutSecondsToNs(timeout_sec: f64) Error!u64 {
    if (!std.math.isFinite(timeout_sec) or timeout_sec <= 0.0 or timeout_sec > max_timeout_seconds) {
        return error.InvalidTimeout;
    }
    const scaled = @round(timeout_sec * @as(f64, @floatFromInt(std.time.ns_per_s)));
    const timeout_ns: u64 = @intFromFloat(scaled);
    if (timeout_ns == 0) return error.InvalidTimeout;
    return timeout_ns;
}

fn pollIntervalMsToNs(poll_ms: u64) Error!u64 {
    if (poll_ms < min_poll_interval_ms or poll_ms > max_poll_interval_ms) {
        return error.InvalidPollInterval;
    }
    return poll_ms * std.time.ns_per_ms;
}

pub fn formatToml(settings: Settings, writer: *std.Io.Writer) !void {
    const whole_seconds = settings.timeout_ns / std.time.ns_per_s;
    const rem_ns = settings.timeout_ns % std.time.ns_per_s;
    const poll_ms = settings.poll_interval_ns / std.time.ns_per_ms;

    if (rem_ns == 0) {
        try writer.print("timeout_seconds = {d}.0\npoll_interval_ms = {d}\n", .{ whole_seconds, poll_ms });
        return;
    }

    var frac_buf: [9]u8 = undefined;
    _ = std.fmt.bufPrint(&frac_buf, "{d:0>9}", .{rem_ns}) catch unreachable;
    const trimmed_frac = std.mem.trimEnd(u8, &frac_buf, "0");
    try writer.print("timeout_seconds = {d}.{s}\npoll_interval_ms = {d}\n", .{ whole_seconds, trimmed_frac, poll_ms });
}
