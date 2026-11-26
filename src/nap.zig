const std = @import("std");
const config = @import("config.zig");

pub const State = enum { visible, hidden };
pub const Action = enum { none, hide, show };

pub const Step = struct {
    action: Action,
    sleep_ns: u64,
};

pub const Machine = struct {
    state: State = .visible,

    pub fn advance(self: *Machine, idle_ns: u64, settings: config.Settings) Step {
        const poll_ns = effectivePollNs(settings);
        switch (self.state) {
            .visible => {
                if (idle_ns >= settings.timeout_ns) {
                    self.state = .hidden;
                    return .{ .action = .hide, .sleep_ns = poll_ns };
                }
                return .{ .action = .none, .sleep_ns = @max(poll_ns, settings.timeout_ns - idle_ns) };
            },
            .hidden => {
                if (idle_ns < settings.timeout_ns) {
                    self.state = .visible;
                    return .{ .action = .show, .sleep_ns = @max(poll_ns, settings.timeout_ns - idle_ns) };
                }
                return .{ .action = .none, .sleep_ns = poll_ns };
            },
        }
    }

    pub fn reset(self: *Machine) Action {
        if (self.state == .hidden) {
            self.state = .visible;
            return .show;
        }
        return .none;
    }
};

pub fn effectivePollNs(settings: config.Settings) u64 {
    return @min(settings.poll_interval_ns, @max(@as(u64, 1 * std.time.ns_per_ms), settings.timeout_ns / 2));
}
