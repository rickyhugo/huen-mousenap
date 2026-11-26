const std = @import("std");

pub const Value = union(enum) {
    integer: i64,
    float: f64,
    boolean: bool,
    string: []const u8,
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const Error = error{
    InvalidSyntax,
    DuplicateKey,
    InvalidNumber,
    UnterminatedString,
    InvalidEscape,
    OutOfMemory,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

pub fn parse(backing_allocator: std.mem.Allocator, source: []const u8) Error!Document {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var entries: std.ArrayList(Entry) = .empty;
    var seen_keys: std.StringHashMapUnmanaged(void) = .empty;
    var current_table: ?[]const u8 = null;

    var line_iter = std.mem.splitScalar(u8, source, '\n');
    while (line_iter.next()) |raw_line| {
        const no_cr = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;

        const trimmed_left = trimSpaces(no_cr);
        if (trimmed_left.len == 0 or trimmed_left[0] == '#') {
            continue;
        }

        if (trimmed_left[0] == '[') {
            current_table = try parseTableHeader(allocator, trimmed_left);
            continue;
        }

        const parsed_entry = try parseKeyValue(allocator, trimmed_left, current_table);
        const put_result = try seen_keys.getOrPut(allocator, parsed_entry.key);
        if (put_result.found_existing) {
            return error.DuplicateKey;
        }
        try entries.append(allocator, parsed_entry);
    }

    return .{
        .arena = arena,
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn trimSpaces(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t");
}

fn isBareKeyChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn parseTableHeader(allocator: std.mem.Allocator, line: []const u8) Error![]const u8 {
    const close_idx = std.mem.indexOfScalar(u8, line, ']') orelse return error.InvalidSyntax;
    if (close_idx <= 1) return error.InvalidSyntax;

    const after_close = trimSpaces(line[close_idx + 1 ..]);
    if (after_close.len > 0 and after_close[0] != '#') {
        return error.InvalidSyntax;
    }

    const inner = trimSpaces(line[1..close_idx]);
    if (inner.len == 0) return error.InvalidSyntax;

    var parts: std.ArrayList([]const u8) = .empty;
    var seg_iter = std.mem.splitScalar(u8, inner, '.');
    while (seg_iter.next()) |raw_seg| {
        const seg = trimSpaces(raw_seg);
        if (seg.len == 0) return error.InvalidSyntax;
        for (seg) |byte| {
            if (!isBareKeyChar(byte)) return error.InvalidSyntax;
        }
        try parts.append(allocator, seg);
    }

    return std.mem.join(allocator, ".", parts.items);
}

fn parseKeyValue(allocator: std.mem.Allocator, line: []const u8, table: ?[]const u8) Error!Entry {
    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidSyntax;
    const raw_key = trimSpaces(line[0..eq_idx]);
    if (raw_key.len == 0) return error.InvalidSyntax;
    for (raw_key) |byte| {
        if (!isBareKeyChar(byte)) return error.InvalidSyntax;
    }

    const full_key = if (table) |prefix|
        try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, raw_key })
    else
        try allocator.dupe(u8, raw_key);

    const raw_val = trimSpaces(line[eq_idx + 1 ..]);
    if (raw_val.len == 0) return error.InvalidSyntax;

    const value = try parseValue(allocator, raw_val);
    return .{ .key = full_key, .value = value };
}

fn parseValue(allocator: std.mem.Allocator, raw: []const u8) Error!Value {
    if (raw[0] == '"') {
        return .{ .string = try parseBasicString(allocator, raw) };
    }
    if (raw[0] == '\'') {
        return .{ .string = try parseLiteralString(allocator, raw) };
    }

    const value_slice = stripInlineComment(raw);
    if (value_slice.len == 0) return error.InvalidSyntax;

    if (std.mem.eql(u8, value_slice, "true")) {
        return .{ .boolean = true };
    }
    if (std.mem.eql(u8, value_slice, "false")) {
        return .{ .boolean = false };
    }

    return parseNumber(allocator, value_slice);
}

fn stripInlineComment(raw: []const u8) []const u8 {
    const without_comment = if (std.mem.indexOfScalar(u8, raw, '#')) |hash_idx|
        raw[0..hash_idx]
    else
        raw;
    return trimSpaces(without_comment);
}

fn parseBasicString(allocator: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 1;
    var closed = false;

    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (byte == '"') {
            closed = true;
            index += 1;
            break;
        }
        if (byte == '\\') {
            index += 1;
            if (index >= raw.len) return error.UnterminatedString;
            const escaped: u8 = switch (raw[index]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                '"' => '"',
                else => return error.InvalidEscape,
            };
            try out.append(allocator, escaped);
            continue;
        }
        try out.append(allocator, byte);
    }

    if (!closed) return error.UnterminatedString;
    const trailing = trimSpaces(raw[index..]);
    if (trailing.len > 0 and trailing[0] != '#') {
        return error.InvalidSyntax;
    }
    return out.toOwnedSlice(allocator);
}

fn parseLiteralString(allocator: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    const end_idx = std.mem.indexOfScalarPos(u8, raw, 1, '\'') orelse return error.UnterminatedString;
    const trailing = trimSpaces(raw[end_idx + 1 ..]);
    if (trailing.len > 0 and trailing[0] != '#') {
        return error.InvalidSyntax;
    }
    return allocator.dupe(u8, raw[1..end_idx]);
}

fn parseNumber(allocator: std.mem.Allocator, token: []const u8) Error!Value {
    for (token) |byte| {
        if (byte == ' ' or byte == '\t') return error.InvalidSyntax;
    }

    var cleaned: std.ArrayList(u8) = .empty;
    var is_float = false;

    for (token, 0..) |byte, idx| {
        if (byte == '_') {
            if (idx == 0 or idx + 1 >= token.len) return error.InvalidNumber;
            if (!std.ascii.isDigit(token[idx - 1]) or !std.ascii.isDigit(token[idx + 1])) {
                return error.InvalidNumber;
            }
            continue;
        }
        if (byte == '.' or byte == 'e' or byte == 'E') {
            is_float = true;
        }
        try cleaned.append(allocator, byte);
    }

    const num_str = cleaned.items;
    if (num_str.len == 0) return error.InvalidNumber;

    if (is_float) {
        if (std.mem.indexOfScalar(u8, num_str, '.')) |dot_idx| {
            if (dot_idx == 0 or dot_idx + 1 >= num_str.len) return error.InvalidNumber;
            if (!std.ascii.isDigit(num_str[dot_idx - 1]) or !std.ascii.isDigit(num_str[dot_idx + 1])) {
                return error.InvalidNumber;
            }
        }
        const parsed_float = std.fmt.parseFloat(f64, num_str) catch return error.InvalidNumber;
        if (!std.math.isFinite(parsed_float)) return error.InvalidNumber;
        return .{ .float = parsed_float };
    }

    const parsed_int = std.fmt.parseInt(i64, num_str, 10) catch return error.InvalidNumber;
    return .{ .integer = parsed_int };
}
