const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const macos = @import("macos.zig");
const nap = @import("nap.zig");
const runner = @import("runner.zig");

const MacOsPlatform = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    config_path: ?[]const u8,
    overrides: config.Overrides,
    print_state: bool,

    pub fn shouldStop(self: *const MacOsPlatform) bool {
        _ = self;
        return macos.shouldStop();
    }

    pub fn takeReload(self: *const MacOsPlatform) bool {
        _ = self;
        return macos.takeReload();
    }

    pub fn reloadConfig(self: *const MacOsPlatform) ?config.Settings {
        return config.load(
            self.allocator,
            self.io,
            self.environ_map,
            self.config_path,
            self.overrides,
        ) catch |err| {
            writeConfigError(self.io, err);
            return null;
        };
    }

    pub fn mouseIdleNs(self: *const MacOsPlatform) u64 {
        _ = self;
        return macos.mouseIdleNs();
    }

    pub fn hideCursor(self: *const MacOsPlatform) !void {
        _ = self;
        try macos.hideCursor();
    }

    pub fn showCursor(self: *const MacOsPlatform) !void {
        _ = self;
        try macos.showCursor();
    }

    pub fn onTransition(self: *const MacOsPlatform, state: nap.State) !void {
        if (!self.print_state) return;
        const line = switch (state) {
            .hidden => "hidden\n",
            .visible => "visible\n",
        };
        try std.Io.File.stdout().writeStreamingAll(self.io, line);
    }

    pub fn sleepNs(self: *const MacOsPlatform, duration_ns: u64) void {
        _ = self;
        macos.sleepNs(duration_ns);
    }
};

pub fn main(init: std.process.Init) u8 {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch {
        writeStderr(init.io, "error: failed to read arguments\n");
        return 1;
    };

    const parsed = cli.parse(argv);
    const command = switch (parsed) {
        .ok => |cmd| cmd,
        .err => |failure| {
            writeParseError(init.io, failure.kind, failure.detail);
            return 2;
        },
    };

    switch (command) {
        .help => {
            std.Io.File.stdout().writeStreamingAll(init.io, cli.usage_text) catch return 1;
            return 0;
        },
        .version => {
            std.Io.File.stdout().writeStreamingAll(init.io, cli.version_text) catch return 1;
            return 0;
        },
        .config => |opts| {
            const settings = config.load(
                init.gpa,
                init.io,
                init.environ_map,
                opts.config_path,
                .{
                    .timeout_seconds = opts.timeout_seconds,
                    .poll_interval_ms = opts.poll_interval_ms,
                },
            ) catch |err| {
                writeConfigError(init.io, err);
                return 1;
            };
            var out_buf: [256]u8 = undefined;
            var out_writer = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
            config.formatToml(settings, &out_writer.interface) catch return 1;
            out_writer.interface.flush() catch return 1;
            return 0;
        },
        .run => |opts| {
            const overrides: config.Overrides = .{
                .timeout_seconds = opts.config.timeout_seconds,
                .poll_interval_ms = opts.config.poll_interval_ms,
            };
            const initial_settings = config.load(
                init.gpa,
                init.io,
                init.environ_map,
                opts.config.config_path,
                overrides,
            ) catch |err| {
                writeConfigError(init.io, err);
                return 1;
            };

            macos.enableBackgroundCursor() catch |err| {
                writeMacOsError(init.io, err);
                return 1;
            };
            macos.installSignalHandlers();

            const platform: MacOsPlatform = .{
                .allocator = init.gpa,
                .io = init.io,
                .environ_map = init.environ_map,
                .config_path = opts.config.config_path,
                .overrides = overrides,
                .print_state = opts.print_state,
            };

            runner.run(initial_settings, &platform) catch |err| {
                writeRunError(init.io, err);
                return 1;
            };
            return 0;
        },
    }
}

fn writeParseError(io: std.Io, kind: cli.ParseError, detail: []const u8) void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    const label = switch (kind) {
        error.UnknownCommand => "unknown command",
        error.UnknownFlag => "unknown flag",
        error.MissingFlagValue => "missing value for flag",
        error.InvalidNumber => "invalid number",
        error.UnexpectedArgument => "unexpected argument",
    };
    writer.interface.print("error: {s}: {s}\n", .{ label, detail }) catch return;
    writer.interface.flush() catch return;
}

fn writeConfigError(io: std.Io, err: config.Error) void {
    const message = switch (err) {
        error.FileNotFound => "error: config file not found\n",
        error.ReadFailed => "error: failed to read config file\n",
        error.InvalidSyntax => "error: invalid TOML syntax\n",
        error.DuplicateKey => "error: duplicate key in config\n",
        error.InvalidNumber => "error: invalid number in config\n",
        error.UnterminatedString => "error: unterminated string in config\n",
        error.InvalidEscape => "error: invalid string escape in config\n",
        error.UnknownKey => "error: unknown config key\n",
        error.WrongType => "error: wrong value type in config\n",
        error.InvalidTimeout => "error: timeout_seconds must be > 0 and <= 86400\n",
        error.InvalidPollInterval => "error: poll_interval_ms must be between 5 and 1000\n",
        error.OutOfMemory => "error: out of memory\n",
    };
    writeStderr(io, message);
}

fn writeMacOsError(io: std.Io, err: macos.Error) void {
    const message = switch (err) {
        error.BackgroundCursorUnavailable => "error: CoreGraphics background cursor symbol unavailable\n",
        error.BackgroundCursorFailed => "error: failed to enable background cursor control\n",
        error.HideCursorFailed => "error: failed to hide cursor\n",
        error.ShowCursorFailed => "error: failed to show cursor\n",
    };
    writeStderr(io, message);
}

fn writeRunError(io: std.Io, err: anyerror) void {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    writer.interface.print("error: runtime failure: {s}\n", .{@errorName(err)}) catch return;
    writer.interface.flush() catch return;
}

fn writeStderr(io: std.Io, message: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, message) catch {};
}
