const std = @import("std");

pub const Value = union(enum) {
    integer: i64,
    float: f64,
    non_numeric,
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const Error = error{
    InvalidSyntax,
    InvalidNumber,
    UnterminatedString,
};

pub const Iterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    pub fn init(source: []const u8) Iterator {
        return .{ .lines = std.mem.splitScalar(u8, source, '\n') };
    }

    pub fn next(self: *Iterator) Error!?Entry {
        while (self.lines.next()) |raw_line| {
            const no_cr = std.mem.trimEnd(u8, raw_line, "\r");
            const trimmed = trimSpaces(no_cr);
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            if (trimmed[0] == '[') return .{ .key = trimmed, .value = .non_numeric };
            return try parseKeyValue(trimmed);
        }
        return null;
    }
};

fn trimSpaces(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t");
}

fn isBareKeyChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn parseKeyValue(line: []const u8) Error!Entry {
    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidSyntax;
    const key = trimSpaces(line[0..eq_idx]);
    if (key.len == 0) return error.InvalidSyntax;
    for (key) |byte| {
        if (!isBareKeyChar(byte)) return error.InvalidSyntax;
    }

    const raw_val = trimSpaces(line[eq_idx + 1 ..]);
    if (raw_val.len == 0) return error.InvalidSyntax;

    return .{ .key = key, .value = try parseValue(raw_val) };
}

fn parseValue(raw: []const u8) Error!Value {
    if (raw[0] == '"') {
        try skipQuotedString(raw, '"', true);
        return .non_numeric;
    }
    if (raw[0] == '\'') {
        try skipQuotedString(raw, '\'', false);
        return .non_numeric;
    }

    const without_comment = if (std.mem.indexOfScalar(u8, raw, '#')) |hash_idx| raw[0..hash_idx] else raw;
    const token = trimSpaces(without_comment);
    if (token.len == 0) return error.InvalidSyntax;
    if (std.mem.eql(u8, token, "true") or std.mem.eql(u8, token, "false")) return .non_numeric;

    return parseNumber(token);
}

fn skipQuotedString(raw: []const u8, quote: u8, allow_escapes: bool) Error!void {
    var index: usize = 1;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (allow_escapes and byte == '\\') {
            index += 1;
            if (index >= raw.len) return error.UnterminatedString;
            continue;
        }
        if (byte == quote) {
            const trailing = trimSpaces(raw[index + 1 ..]);
            if (trailing.len > 0 and trailing[0] != '#') return error.InvalidSyntax;
            return;
        }
    }
    return error.UnterminatedString;
}

fn parseNumber(token: []const u8) Error!Value {
    var buffer: [64]u8 = undefined;
    var length: usize = 0;
    var is_float = false;

    for (token, 0..) |byte, idx| {
        if (byte == ' ' or byte == '\t') return error.InvalidSyntax;
        if (byte == '_') {
            if (idx == 0 or idx + 1 >= token.len) return error.InvalidNumber;
            if (!std.ascii.isDigit(token[idx - 1]) or !std.ascii.isDigit(token[idx + 1])) return error.InvalidNumber;
            continue;
        }
        if (byte == '.' or byte == 'e' or byte == 'E') is_float = true;
        if (length >= buffer.len) return error.InvalidNumber;
        buffer[length] = byte;
        length += 1;
    }

    const num_str = buffer[0..length];
    if (num_str.len == 0) return error.InvalidNumber;

    if (is_float) {
        if (std.mem.indexOfScalar(u8, num_str, '.')) |dot_idx| {
            if (dot_idx == 0 or dot_idx + 1 >= num_str.len) return error.InvalidNumber;
            if (!std.ascii.isDigit(num_str[dot_idx - 1]) or !std.ascii.isDigit(num_str[dot_idx + 1])) return error.InvalidNumber;
        }
        const parsed_float = std.fmt.parseFloat(f64, num_str) catch return error.InvalidNumber;
        if (!std.math.isFinite(parsed_float)) return error.InvalidNumber;
        return .{ .float = parsed_float };
    }

    const parsed_int = std.fmt.parseInt(i64, num_str, 10) catch return error.InvalidNumber;
    return .{ .integer = parsed_int };
}
