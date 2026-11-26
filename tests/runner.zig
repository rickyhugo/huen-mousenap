const std = @import("std");
const runner = @import("runner");
const config = runner.config;
const nap = runner.nap;

const Event = enum { hide, show };

const FakePlatform = struct {
    idle_readings: []const u64,
    reading_index: usize = 0,
    hide_count: usize = 0,
    show_count: usize = 0,
    events: [32]Event = undefined,
    event_count: usize = 0,
    sleeps: [32]u64 = undefined,
    sleep_count: usize = 0,
    transitions: [32]nap.State = undefined,
    transition_count: usize = 0,
    reload_at_step: ?usize = null,
    reloaded_settings: ?config.Settings = null,
    reload_consumed: bool = false,

    pub fn shouldStop(self: *FakePlatform) bool {
        return self.reading_index >= self.idle_readings.len;
    }

    pub fn takeReload(self: *FakePlatform) bool {
        if (self.reload_at_step) |target_step| {
            if (!self.reload_consumed and self.reading_index == target_step) {
                self.reload_consumed = true;
                return true;
            }
        }
        return false;
    }

    pub fn reloadConfig(self: *FakePlatform) ?config.Settings {
        return self.reloaded_settings;
    }

    pub fn mouseIdleNs(self: *FakePlatform) u64 {
        const value = self.idle_readings[self.reading_index];
        self.reading_index += 1;
        return value;
    }

    pub fn hideCursor(self: *FakePlatform) !void {
        self.hide_count += 1;
        self.events[self.event_count] = .hide;
        self.event_count += 1;
    }

    pub fn showCursor(self: *FakePlatform) !void {
        self.show_count += 1;
        self.events[self.event_count] = .show;
        self.event_count += 1;
    }

    pub fn onTransition(self: *FakePlatform, state: nap.State) !void {
        self.transitions[self.transition_count] = state;
        self.transition_count += 1;
    }

    pub fn sleepNs(self: *FakePlatform, duration_ns: u64) void {
        self.sleeps[self.sleep_count] = duration_ns;
        self.sleep_count += 1;
    }

    pub fn recordedEvents(self: *const FakePlatform) []const Event {
        return self.events[0..self.event_count];
    }

    pub fn recordedSleeps(self: *const FakePlatform) []const u64 {
        return self.sleeps[0..self.sleep_count];
    }

    pub fn recordedTransitions(self: *const FakePlatform) []const nap.State {
        return self.transitions[0..self.transition_count];
    }
};

test "cursor stays visible below timeout and sleeps remaining time" {
    var platform: FakePlatform = .{
        .idle_readings = &.{
            500 * std.time.ns_per_ms,
            2_990 * std.time.ns_per_ms,
        },
    };
    const settings: config.Settings = .{
        .timeout_ns = 3_000 * std.time.ns_per_ms,
        .poll_interval_ns = 25 * std.time.ns_per_ms,
    };

    try runner.run(settings, &platform);

    try std.testing.expectEqual(@as(usize, 0), platform.hide_count);
    try std.testing.expectEqual(@as(usize, 0), platform.show_count);
    try std.testing.expectEqualSlices(u64, &.{
        2_500 * std.time.ns_per_ms,
        25 * std.time.ns_per_ms,
    }, platform.recordedSleeps());
}

test "cursor hides once at timeout and sleeps poll interval while hidden" {
    var platform: FakePlatform = .{
        .idle_readings = &.{
            3_000 * std.time.ns_per_ms,
            4_500 * std.time.ns_per_ms,
        },
    };
    const settings: config.Settings = .{
        .timeout_ns = 3_000 * std.time.ns_per_ms,
        .poll_interval_ns = 25 * std.time.ns_per_ms,
    };

    try runner.run(settings, &platform);

    try std.testing.expectEqual(@as(usize, 1), platform.hide_count);
    try std.testing.expectEqualSlices(u64, &.{
        25 * std.time.ns_per_ms,
        25 * std.time.ns_per_ms,
    }, platform.recordedSleeps());
}

test "cursor reveals once on activity and balances hide and show across cycles" {
    var platform: FakePlatform = .{
        .idle_readings = &.{
            3_000 * std.time.ns_per_ms,
            100 * std.time.ns_per_ms,
            200 * std.time.ns_per_ms,
            3_100 * std.time.ns_per_ms,
            3_500 * std.time.ns_per_ms,
            50 * std.time.ns_per_ms,
        },
    };
    const settings: config.Settings = .{
        .timeout_ns = 3_000 * std.time.ns_per_ms,
        .poll_interval_ns = 25 * std.time.ns_per_ms,
    };

    try runner.run(settings, &platform);

    try std.testing.expectEqualSlices(Event, &.{ .hide, .show, .hide, .show }, platform.recordedEvents());
    try std.testing.expectEqualSlices(u64, &.{
        25 * std.time.ns_per_ms,
        2_900 * std.time.ns_per_ms,
        2_800 * std.time.ns_per_ms,
        25 * std.time.ns_per_ms,
        25 * std.time.ns_per_ms,
        2_950 * std.time.ns_per_ms,
    }, platform.recordedSleeps());
}

test "short timeout clamps poll sleep to half timeout with 1ms floor" {
    var platform_half: FakePlatform = .{
        .idle_readings = &.{
            10 * std.time.ns_per_ms,
            2 * std.time.ns_per_ms,
        },
    };
    try runner.run(.{
        .timeout_ns = 10 * std.time.ns_per_ms,
        .poll_interval_ns = 25 * std.time.ns_per_ms,
    }, &platform_half);

    try std.testing.expectEqualSlices(u64, &.{
        5 * std.time.ns_per_ms,
        8 * std.time.ns_per_ms,
    }, platform_half.recordedSleeps());

    var platform_floor: FakePlatform = .{
        .idle_readings = &.{
            1 * std.time.ns_per_ms,
        },
    };
    try runner.run(.{
        .timeout_ns = 1 * std.time.ns_per_ms,
        .poll_interval_ns = 25 * std.time.ns_per_ms,
    }, &platform_floor);

    try std.testing.expectEqualSlices(u64, &.{
        1 * std.time.ns_per_ms,
    }, platform_floor.recordedSleeps());
}

test "stopping while hidden restores cursor and stopping while visible does not" {
    var hidden_platform: FakePlatform = .{
        .idle_readings = &.{
            3_000 * std.time.ns_per_ms,
        },
    };
    const settings: config.Settings = .{
        .timeout_ns = 3_000 * std.time.ns_per_ms,
        .poll_interval_ns = 25 * std.time.ns_per_ms,
    };

    try runner.run(settings, &hidden_platform);
    try std.testing.expectEqualSlices(Event, &.{ .hide, .show }, hidden_platform.recordedEvents());

    var visible_platform: FakePlatform = .{
        .idle_readings = &.{
            500 * std.time.ns_per_ms,
        },
    };
    try runner.run(settings, &visible_platform);
    try std.testing.expectEqual(@as(usize, 0), visible_platform.show_count);
    try std.testing.expectEqual(@as(usize, 0), visible_platform.hide_count);
}

test "transition notifications emit only when cursor state changes" {
    var platform: FakePlatform = .{
        .idle_readings = &.{
            500 * std.time.ns_per_ms,
            3_000 * std.time.ns_per_ms,
            4_000 * std.time.ns_per_ms,
            100 * std.time.ns_per_ms,
            200 * std.time.ns_per_ms,
        },
    };
    const settings: config.Settings = .{
        .timeout_ns = 3_000 * std.time.ns_per_ms,
        .poll_interval_ns = 25 * std.time.ns_per_ms,
    };

    try runner.run(settings, &platform);

    try std.testing.expectEqualSlices(nap.State, &.{ .hidden, .visible }, platform.recordedTransitions());
}

test "live reload adopts valid config for immediate hide and immediate reveal" {
    var shorten_platform: FakePlatform = .{
        .idle_readings = &.{
            1_500 * std.time.ns_per_ms,
            1_500 * std.time.ns_per_ms,
        },
        .reload_at_step = 1,
        .reloaded_settings = .{
            .timeout_ns = 1_000 * std.time.ns_per_ms,
            .poll_interval_ns = 50 * std.time.ns_per_ms,
        },
    };
    try runner.run(.{
        .timeout_ns = 3_000 * std.time.ns_per_ms,
        .poll_interval_ns = 25 * std.time.ns_per_ms,
    }, &shorten_platform);

    try std.testing.expectEqualSlices(Event, &.{ .hide, .show }, shorten_platform.recordedEvents());
    try std.testing.expectEqualSlices(u64, &.{
        1_500 * std.time.ns_per_ms,
        50 * std.time.ns_per_ms,
    }, shorten_platform.recordedSleeps());

    var lengthen_platform: FakePlatform = .{
        .idle_readings = &.{
            3_000 * std.time.ns_per_ms,
            3_500 * std.time.ns_per_ms,
        },
        .reload_at_step = 1,
        .reloaded_settings = .{
            .timeout_ns = 5_000 * std.time.ns_per_ms,
            .poll_interval_ns = 40 * std.time.ns_per_ms,
        },
    };
    try runner.run(.{
        .timeout_ns = 3_000 * std.time.ns_per_ms,
        .poll_interval_ns = 25 * std.time.ns_per_ms,
    }, &lengthen_platform);

    try std.testing.expectEqualSlices(Event, &.{ .hide, .show }, lengthen_platform.recordedEvents());
    try std.testing.expectEqualSlices(u64, &.{
        25 * std.time.ns_per_ms,
        1_500 * std.time.ns_per_ms,
    }, lengthen_platform.recordedSleeps());
}

test "invalid live reload keeps last good config" {
    var platform: FakePlatform = .{
        .idle_readings = &.{
            500 * std.time.ns_per_ms,
            1_500 * std.time.ns_per_ms,
        },
        .reload_at_step = 1,
        .reloaded_settings = null,
    };
    try runner.run(.{
        .timeout_ns = 3_000 * std.time.ns_per_ms,
        .poll_interval_ns = 25 * std.time.ns_per_ms,
    }, &platform);

    try std.testing.expect(platform.reload_consumed);
    try std.testing.expectEqual(@as(usize, 0), platform.hide_count);
    try std.testing.expectEqualSlices(u64, &.{
        2_500 * std.time.ns_per_ms,
        1_500 * std.time.ns_per_ms,
    }, platform.recordedSleeps());
}
