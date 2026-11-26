const std = @import("std");
const build_options = @import("build_options");

fn runCli(args: []const []const u8, environ_map: ?*const std.process.Environ.Map) !std.process.RunResult {
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(std.testing.allocator);

    try argv_list.append(std.testing.allocator, build_options.binary_path);
    try argv_list.appendSlice(std.testing.allocator, args);

    return std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = argv_list.items,
        .environ_map = environ_map,
    });
}

fn freeResult(result: std.process.RunResult) void {
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
}

test "help subcommand and flags print usage and exit zero" {
    const cases = [_][]const []const u8{
        &.{"--help"},
        &.{"-h"},
        &.{"help"},
    };
    for (cases) |args| {
        const result = try runCli(args, null);
        defer freeResult(result);

        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "huen-mousenap") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "config") != null);
        try std.testing.expectEqualStrings("", result.stderr);
    }
}

test "version subcommand and flags print version and exit zero" {
    const cases = [_][]const []const u8{
        &.{"--version"},
        &.{"-V"},
        &.{"version"},
    };
    for (cases) |args| {
        const result = try runCli(args, null);
        defer freeResult(result);

        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expectEqualStrings("huen-mousenap 0.1.0\n", result.stdout);
        try std.testing.expectEqualStrings("", result.stderr);
    }
}

test "unknown subcommands, flags, and extra positionals fail with stderr message" {
    const cases = [_][]const []const u8{
        &.{"unknown"},
        &.{"--unknown"},
        &.{"-x"},
        &.{ "help", "extra" },
        &.{ "version", "extra" },
    };
    for (cases) |args| {
        const result = try runCli(args, null);
        defer freeResult(result);

        switch (result.term) {
            .exited => |code| try std.testing.expect(code != 0),
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expect(result.stderr.len > 0);
    }
}

test "config prints default TOML when default config file is absent" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const home_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home_path);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_path);

    const result = try runCli(&.{"config"}, &env_map);
    defer freeResult(result);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("timeout_seconds = 3.0\npoll_interval_ms = 25\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "config reads HOME default file with comments and integer timeout" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, ".config/huen-mousenap");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = ".config/huen-mousenap/config.toml",
        .data =
        \\# full-line comment
        \\timeout_seconds = 5 # inline comment
        \\
        \\poll_interval_ms = 50
        \\
        ,
    });

    const home_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home_path);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_path);
    try env_map.put("XDG_CONFIG_HOME", "relative/path");

    const result = try runCli(&.{"config"}, &env_map);
    defer freeResult(result);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("timeout_seconds = 5.0\npoll_interval_ms = 50\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "config prefers absolute XDG_CONFIG_HOME over HOME" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "home/.config/huen-mousenap");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.config/huen-mousenap/config.toml",
        .data = "timeout_seconds = 9.0\n",
    });
    try tmp_dir.dir.createDirPath(std.testing.io, "xdg/huen-mousenap");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "xdg/huen-mousenap/config.toml",
        .data = "timeout_seconds = 1.25\npoll_interval_ms = 40\n",
    });

    const home_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "home", std.testing.allocator);
    defer std.testing.allocator.free(home_path);
    const xdg_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "xdg", std.testing.allocator);
    defer std.testing.allocator.free(xdg_path);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_path);
    try env_map.put("XDG_CONFIG_HOME", xdg_path);

    const result = try runCli(&.{"config"}, &env_map);
    defer freeResult(result);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("timeout_seconds = 1.25\npoll_interval_ms = 40\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "config reads explicit --config path and rejects missing explicit file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "custom.toml",
        .data = "timeout_seconds = 2.5\npoll_interval_ms = 1_00\n",
    });

    const custom_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "custom.toml", std.testing.allocator);
    defer std.testing.allocator.free(custom_path);

    const ok_result = try runCli(&.{ "config", "-c", custom_path }, null);
    defer freeResult(ok_result);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, ok_result.term);
    try std.testing.expectEqualStrings("timeout_seconds = 2.5\npoll_interval_ms = 100\n", ok_result.stdout);
    try std.testing.expectEqualStrings("", ok_result.stderr);

    const root_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const missing_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "missing.toml" });
    defer std.testing.allocator.free(missing_path);

    const err_result = try runCli(&.{ "config", "--config", missing_path }, null);
    defer freeResult(err_result);

    switch (err_result.term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("", err_result.stdout);
    try std.testing.expect(err_result.stderr.len > 0);
}

test "config rejects invalid TOML and out-of-range values" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const invalid_cases = [_]struct {
        filename: []const u8,
        contents: []const u8,
    }{
        .{ .filename = "bad_syntax.toml", .contents = "not a valid line\n" },
        .{ .filename = "trailing.toml", .contents = "timeout_seconds = 3.0 extra\n" },
        .{ .filename = "duplicate.toml", .contents = "timeout_seconds = 2.0\ntimeout_seconds = 4.0\n" },
        .{ .filename = "unknown_key.toml", .contents = "unknown = 1\n" },
        .{ .filename = "unknown_table_key.toml", .contents = "[cursor]\ntimeout_seconds = 3.0\n" },
        .{ .filename = "wrong_type_timeout.toml", .contents = "timeout_seconds = \"3.0\"\n" },
        .{ .filename = "wrong_type_bool.toml", .contents = "timeout_seconds = true\n" },
        .{ .filename = "wrong_type_poll.toml", .contents = "poll_interval_ms = 25.0\n" },
        .{ .filename = "zero_timeout.toml", .contents = "timeout_seconds = 0.0\n" },
        .{ .filename = "negative_timeout.toml", .contents = "timeout_seconds = -1.5\n" },
        .{ .filename = "huge_timeout.toml", .contents = "timeout_seconds = 86401.0\n" },
        .{ .filename = "low_poll.toml", .contents = "poll_interval_ms = 4\n" },
        .{ .filename = "high_poll.toml", .contents = "poll_interval_ms = 1001\n" },
        .{ .filename = "negative_poll.toml", .contents = "poll_interval_ms = -10\n" },
    };

    for (invalid_cases) |case| {
        try tmp_dir.dir.writeFile(std.testing.io, .{
            .sub_path = case.filename,
            .data = case.contents,
        });
        const full_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, case.filename, std.testing.allocator);
        defer std.testing.allocator.free(full_path);

        const result = try runCli(&.{ "config", "--config", full_path }, null);
        defer freeResult(result);

        switch (result.term) {
            .exited => |code| try std.testing.expect(code != 0),
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expect(result.stderr.len > 0);
    }
}

test "config applies CLI overrides over file values and validates CLI flag errors" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "base.toml",
        .data = "timeout_seconds = 10.0\npoll_interval_ms = 80\n",
    });
    const base_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "base.toml", std.testing.allocator);
    defer std.testing.allocator.free(base_path);

    const override_result = try runCli(&.{
        "config",
        "--config",
        base_path,
        "--timeout",
        "0.5",
        "--poll-interval",
        "10",
    }, null);
    defer freeResult(override_result);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, override_result.term);
    try std.testing.expectEqualStrings("timeout_seconds = 0.5\npoll_interval_ms = 10\n", override_result.stdout);
    try std.testing.expectEqualStrings("", override_result.stderr);

    const short_override = try runCli(&.{ "config", "-c", base_path, "-t", "86400" }, null);
    defer freeResult(short_override);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, short_override.term);
    try std.testing.expectEqualStrings("timeout_seconds = 86400.0\npoll_interval_ms = 80\n", short_override.stdout);
    try std.testing.expectEqualStrings("", short_override.stderr);

    const bad_flag_cases = [_][]const []const u8{
        &.{ "config", "--config" },
        &.{ "config", "--timeout" },
        &.{ "config", "--poll-interval" },
        &.{ "config", "--timeout", "abc" },
        &.{ "config", "--timeout", "0" },
        &.{ "config", "--timeout", "nan" },
        &.{ "config", "--poll-interval", "abc" },
        &.{ "config", "--poll-interval", "4" },
        &.{ "config", "--poll-interval", "1001" },
        &.{ "config", "--print-state" },
        &.{ "config", "extra" },
    };
    for (bad_flag_cases) |args| {
        const result = try runCli(args, null);
        defer freeResult(result);

        switch (result.term) {
            .exited => |code| try std.testing.expect(code != 0),
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expect(result.stderr.len > 0);
    }
}

fn sleepMs(millis: u64) void {
    const req: std.c.timespec = .{
        .sec = @intCast(millis / 1000),
        .nsec = @intCast((millis % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&req, null);
}

fn readAllPipe(file: std.Io.File) ![]u8 {
    var reader = file.readerStreaming(std.testing.io, &.{});
    return reader.interface.allocRemaining(std.testing.allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => return err,
    };
}

fn isChildAlive(child: *std.process.Child) bool {
    const pid = child.id orelse return false;
    var wait_status: c_int = 0;
    if (std.c.waitpid(pid, &wait_status, std.c.W.NOHANG) == 0) {
        return true;
    }
    if (child.stdout) |out_file| {
        out_file.close(std.testing.io);
        child.stdout = null;
    }
    if (child.stderr) |err_file| {
        err_file.close(std.testing.io);
        child.stderr = null;
    }
    child.id = null;
    return false;
}

test "run stays alive until SIGTERM and exits zero within one second" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const home_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home_path);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_path);

    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ build_options.binary_path, "run", "--timeout", "86400" },
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(std.testing.io);

    sleepMs(150);
    if (!isChildAlive(&child)) return error.ProcessExitedEarly;

    const start_ts = std.Io.Clock.awake.now(std.testing.io);
    try std.testing.expectEqual(@as(c_int, 0), std.c.kill(child.id.?, std.c.SIG.TERM));

    const stdout_bytes = try readAllPipe(child.stdout.?);
    defer std.testing.allocator.free(stdout_bytes);
    const stderr_bytes = try readAllPipe(child.stderr.?);
    defer std.testing.allocator.free(stderr_bytes);

    const term = try child.wait(std.testing.io);
    const elapsed_ns = start_ts.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds();

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    try std.testing.expect(elapsed_ns < std.time.ns_per_s);
    try std.testing.expectEqualStrings("", stdout_bytes);
    try std.testing.expectEqualStrings("", stderr_bytes);
}

test "run survives SIGHUP for valid and invalid config reloads until SIGTERM" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "reload.toml",
        .data = "timeout_seconds = 86400.0\npoll_interval_ms = 25\n",
    });
    const config_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "reload.toml", std.testing.allocator);
    defer std.testing.allocator.free(config_path);

    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ build_options.binary_path, "run", "--config", config_path },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(std.testing.io);

    sleepMs(150);
    if (!isChildAlive(&child)) return error.ProcessExitedEarly;

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "reload.toml",
        .data = "timeout_seconds = 43200.0\npoll_interval_ms = 50\n",
    });
    try std.testing.expectEqual(@as(c_int, 0), std.c.kill(child.id.?, std.c.SIG.HUP));
    sleepMs(120);
    if (!isChildAlive(&child)) return error.ProcessExitedOnValidReload;

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "reload.toml",
        .data = "timeout_seconds = \"broken\"\n",
    });
    try std.testing.expectEqual(@as(c_int, 0), std.c.kill(child.id.?, std.c.SIG.HUP));
    sleepMs(120);
    if (!isChildAlive(&child)) return error.ProcessExitedOnInvalidReload;

    try std.testing.expectEqual(@as(c_int, 0), std.c.kill(child.id.?, std.c.SIG.TERM));

    const stdout_bytes = try readAllPipe(child.stdout.?);
    defer std.testing.allocator.free(stdout_bytes);
    const stderr_bytes = try readAllPipe(child.stderr.?);
    defer std.testing.allocator.free(stderr_bytes);

    const term = try child.wait(std.testing.io);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    try std.testing.expectEqualStrings("", stdout_bytes);
    try std.testing.expect(stderr_bytes.len > 0);
}
