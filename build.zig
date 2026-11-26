const std = @import("std");

pub fn build(builder: *std.Build) void {
    const zig_version = @import("builtin").zig_version;
    if (zig_version.major != 0 or zig_version.minor != 17) @panic("huen-mousenap requires Zig 0.17.x");

    const target = builder.standardTargetOptions(.{
        .default_target = .{
            .os_tag = .macos,
            .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } },
        },
    });
    if (target.result.os.tag != .macos or target.result.cpu.arch != @import("builtin").cpu.arch) {
        @panic("huen-mousenap builds for the host macOS architecture only");
    }

    const optimize = builder.standardOptimizeOption(.{});
    const sdk = std.mem.trim(u8, builder.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }), "\r\n");

    const app_options = builder.addOptions();
    app_options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const module = builder.createModule(.{
        .root_source_file = builder.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addOptions("build_options", app_options);
    module.addSystemFrameworkPath(.{ .cwd_relative = builder.fmt("{s}/System/Library/Frameworks", .{sdk}) });
    module.addSystemIncludePath(.{ .cwd_relative = builder.fmt("{s}/usr/include", .{sdk}) });
    module.addLibraryPath(.{ .cwd_relative = builder.fmt("{s}/usr/lib", .{sdk}) });
    for ([_][]const u8{ "CoreGraphics", "CoreFoundation" }) |framework| {
        module.linkFramework(framework, .{});
    }

    const executable = builder.addExecutable(.{
        .name = "huen-mousenap",
        .root_module = module,
    });
    builder.installArtifact(executable);

    const runner_module = builder.createModule(.{
        .root_source_file = builder.path("src/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runner_test_module = builder.createModule(.{
        .root_source_file = builder.path("tests/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    runner_test_module.addImport("runner", runner_module);
    const runner_tests = builder.addTest(.{
        .name = "runner-tests",
        .root_module = runner_test_module,
    });
    const run_runner_tests = builder.addRunArtifact(runner_tests);
    const test_step = builder.step("test", "Run runner seam tests");
    test_step.dependOn(&run_runner_tests.step);

    const smoke_options = builder.addOptions();
    smoke_options.addOptionPath("binary_path", executable.getEmittedBin());

    const smoke_test_module = builder.createModule(.{
        .root_source_file = builder.path("tests/cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    smoke_test_module.addOptions("build_options", smoke_options);
    const smoke_tests = builder.addTest(.{
        .name = "smoke-tests",
        .root_module = smoke_test_module,
    });
    const run_smoke_tests = builder.addRunArtifact(smoke_tests);
    run_smoke_tests.has_side_effects = true;
    const smoke_step = builder.step("smoke", "Run CLI seam smoke tests");
    smoke_step.dependOn(&run_smoke_tests.step);
}
