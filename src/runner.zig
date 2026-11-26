pub const config = @import("config.zig");
pub const nap = @import("nap.zig");

pub fn run(initial_settings: config.Settings, platform: anytype) !void {
    var settings = initial_settings;
    var machine: nap.Machine = .{};
    defer if (machine.reset() == .show) {
        platform.showCursor() catch {};
        platform.onTransition(.visible) catch {};
    };

    while (!platform.shouldStop()) {
        if (platform.takeReload()) {
            if (platform.reloadConfig()) |updated| {
                settings = updated;
            }
        }
        const idle_ns = platform.mouseIdleNs();
        const step = machine.advance(idle_ns, settings);
        switch (step.action) {
            .none => {},
            .hide => {
                platform.hideCursor() catch |err| {
                    machine.state = .visible;
                    return err;
                };
                try platform.onTransition(.hidden);
            },
            .show => {
                platform.showCursor() catch |err| {
                    machine.state = .hidden;
                    return err;
                };
                try platform.onTransition(.visible);
            },
        }
        platform.sleepNs(step.sleep_ns);
    }
}
