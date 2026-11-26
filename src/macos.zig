const std = @import("std");

const CGError = i32;
const CGDirectDisplayID = u32;
const CGEventSourceStateID = i32;
const CGEventType = u32;
const CFTypeRef = *const anyopaque;
const CFStringRef = *const anyopaque;
const CFBooleanRef = *const anyopaque;

const event_source_combined_session: CGEventSourceStateID = 0;

const EventType = struct {
    const left_mouse_down: CGEventType = 1;
    const left_mouse_up: CGEventType = 2;
    const right_mouse_down: CGEventType = 3;
    const right_mouse_up: CGEventType = 4;
    const mouse_moved: CGEventType = 5;
    const left_mouse_dragged: CGEventType = 6;
    const right_mouse_dragged: CGEventType = 7;
    const scroll_wheel: CGEventType = 22;
    const other_mouse_down: CGEventType = 25;
    const other_mouse_up: CGEventType = 26;
    const other_mouse_dragged: CGEventType = 27;
};

const mouse_event_types = [_]CGEventType{
    EventType.left_mouse_down,
    EventType.left_mouse_up,
    EventType.right_mouse_down,
    EventType.right_mouse_up,
    EventType.mouse_moved,
    EventType.left_mouse_dragged,
    EventType.right_mouse_dragged,
    EventType.scroll_wheel,
    EventType.other_mouse_down,
    EventType.other_mouse_up,
    EventType.other_mouse_dragged,
};

extern "c" fn CGMainDisplayID() CGDirectDisplayID;
extern "c" fn CGDisplayHideCursor(display: CGDirectDisplayID) CGError;
extern "c" fn CGDisplayShowCursor(display: CGDirectDisplayID) CGError;
extern "c" fn CGEventSourceSecondsSinceLastEventType(
    state_id: CGEventSourceStateID,
    event_type: CGEventType,
) f64;
extern "c" fn __CFStringMakeConstantString(c_str: [*:0]const u8) CFStringRef;
extern "c" const kCFBooleanTrue: CFBooleanRef;

const MainConnectionFn = *const fn () callconv(.c) c_int;
const SetConnectionPropertyFn = *const fn (c_int, c_int, CFStringRef, CFTypeRef) callconv(.c) CGError;

const BackgroundSymbols = struct {
    main_connection: MainConnectionFn,
    set_property: SetConnectionPropertyFn,
};

pub const Error = error{
    BackgroundCursorUnavailable,
    BackgroundCursorFailed,
    HideCursorFailed,
    ShowCursorFailed,
};

var stop_requested = std.atomic.Value(bool).init(false);
var reload_requested = std.atomic.Value(bool).init(false);

fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    switch (sig) {
        .INT, .TERM => stop_requested.store(true, .release),
        .HUP => reload_requested.store(true, .release),
        else => {},
    }
}

pub fn installSignalHandlers() void {
    stop_requested.store(false, .release);
    reload_requested.store(false, .release);

    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    std.posix.sigaction(std.posix.SIG.HUP, &action, null);
}

pub fn shouldStop() bool {
    return stop_requested.load(.acquire);
}

pub fn takeReload() bool {
    return reload_requested.swap(false, .acq_rel);
}

pub fn enableBackgroundCursor() Error!void {
    const symbols = resolveBackgroundSymbols() orelse return error.BackgroundCursorUnavailable;
    const connection_id = symbols.main_connection();
    const property_key = __CFStringMakeConstantString("SetsCursorInBackground");
    const status = symbols.set_property(connection_id, connection_id, property_key, kCFBooleanTrue);
    if (status != 0) {
        return error.BackgroundCursorFailed;
    }
}

fn resolveBackgroundSymbols() ?BackgroundSymbols {
    if (loadSymbols(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        "CGSMainConnectionID",
        "CGSSetConnectionProperty",
    )) |symbols| {
        return symbols;
    }
    return loadSymbols(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        "SLSMainConnectionID",
        "SLSSetConnectionProperty",
    );
}

fn loadSymbols(
    framework_path: [*:0]const u8,
    main_conn_symbol: [*:0]const u8,
    set_prop_symbol: [*:0]const u8,
) ?BackgroundSymbols {
    const handle = std.c.dlopen(framework_path, .{ .LAZY = true, .LOCAL = true }) orelse return null;
    const raw_main_conn = std.c.dlsym(handle, main_conn_symbol) orelse return null;
    const raw_set_prop = std.c.dlsym(handle, set_prop_symbol) orelse return null;
    return .{
        .main_connection = @ptrCast(@alignCast(raw_main_conn)),
        .set_property = @ptrCast(@alignCast(raw_set_prop)),
    };
}

pub fn hideCursor() Error!void {
    if (CGDisplayHideCursor(CGMainDisplayID()) != 0) {
        return error.HideCursorFailed;
    }
}

pub fn showCursor() Error!void {
    if (CGDisplayShowCursor(CGMainDisplayID()) != 0) {
        return error.ShowCursorFailed;
    }
}

pub fn mouseIdleNs() u64 {
    var min_seconds: ?f64 = null;
    for (mouse_event_types) |event_type| {
        const seconds = CGEventSourceSecondsSinceLastEventType(event_source_combined_session, event_type);
        if (!std.math.isFinite(seconds) or seconds < 0.0) {
            continue;
        }
        if (min_seconds) |current_min| {
            if (seconds < current_min) {
                min_seconds = seconds;
            }
        } else {
            min_seconds = seconds;
        }
    }

    const best_seconds = min_seconds orelse return 0;
    const max_seconds: f64 = 18_000_000_000.0;
    if (best_seconds >= max_seconds) {
        return std.math.maxInt(u64);
    }
    return @intFromFloat(best_seconds * @as(f64, @floatFromInt(std.time.ns_per_s)));
}

pub fn sleepNs(duration_ns: u64) void {
    if (duration_ns == 0 or stop_requested.load(.acquire) or reload_requested.load(.acquire)) {
        return;
    }
    const request: std.c.timespec = .{
        .sec = @intCast(duration_ns / std.time.ns_per_s),
        .nsec = @intCast(duration_ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&request, null);
}
