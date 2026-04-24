const std = @import("std");

pub const PrintableKey = struct {
    bytes: [4]u8 = [_]u8{0} ** 4,
    len: u3 = 0,

    pub fn fromSlice(input: []const u8) PrintableKey {
        var key = PrintableKey{
            .len = @intCast(input.len),
        };
        @memcpy(key.bytes[0..input.len], input);
        return key;
    }

    pub fn slice(self: *const PrintableKey) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Key = union(enum) {
    printable: PrintableKey,
    ctrl: u8,
    tab,
    enter,
    backspace,
    escape,
    up,
    down,
    left,
    right,
};

pub const ParseResult = struct {
    key: Key,
    consumed: usize,
};

pub fn parseKey(input: []const u8) ?ParseResult {
    if (input.len == 0) return null;

    const first = input[0];
    if (first == '\r' or first == '\n') {
        return .{ .key = .enter, .consumed = 1 };
    }

    switch (first) {
        0x09 => return .{ .key = .tab, .consumed = 1 },
        0x7f, 0x08 => return .{ .key = .backspace, .consumed = 1 },
        0x1b => return parseEscapeSequence(input),
        0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a => return .{
            .key = .{ .ctrl = @as(u8, 'a') + first - 1 },
            .consumed = 1,
        },
        else => {},
    }

    if (first < 0x20) return null;

    const sequence_len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    const consumed = @min(sequence_len, input.len);
    return .{
        .key = .{ .printable = PrintableKey.fromSlice(input[0..consumed]) },
        .consumed = consumed,
    };
}

fn parseEscapeSequence(input: []const u8) ParseResult {
    if (input.len >= 3) {
        const lead = input[1];
        const trail = input[2];
        if ((lead == '[' or lead == 'O') and trail == 'A') {
            return .{ .key = .up, .consumed = 3 };
        }
        if ((lead == '[' or lead == 'O') and trail == 'B') {
            return .{ .key = .down, .consumed = 3 };
        }
        if ((lead == '[' or lead == 'O') and trail == 'C') {
            return .{ .key = .right, .consumed = 3 };
        }
        if ((lead == '[' or lead == 'O') and trail == 'D') {
            return .{ .key = .left, .consumed = 3 };
        }
    }

    return .{ .key = .escape, .consumed = 1 };
}

test "parse printable keys" {
    const ascii = parseKey("a").?;
    try std.testing.expectEqual(@as(usize, 1), ascii.consumed);
    try std.testing.expect(ascii.key == .printable);
    try std.testing.expectEqualStrings("a", ascii.key.printable.slice());

    const utf8 = parseKey("é").?;
    try std.testing.expectEqual(@as(usize, 2), utf8.consumed);
    try std.testing.expect(utf8.key == .printable);
    try std.testing.expectEqualStrings("é", utf8.key.printable.slice());
}

test "parse arrow keys from escape sequences" {
    try std.testing.expectEqualDeep(ParseResult{ .key = .up, .consumed = 3 }, parseKey("\x1b[A").?);
    try std.testing.expectEqualDeep(ParseResult{ .key = .down, .consumed = 3 }, parseKey("\x1bOB").?);
    try std.testing.expectEqualDeep(ParseResult{ .key = .right, .consumed = 3 }, parseKey("\x1b[C").?);
    try std.testing.expectEqualDeep(ParseResult{ .key = .left, .consumed = 3 }, parseKey("\x1bOD").?);
}

test "parse enter backspace and ctrl sequences" {
    try std.testing.expectEqualDeep(ParseResult{ .key = .enter, .consumed = 1 }, parseKey("\r").?);
    try std.testing.expectEqualDeep(ParseResult{ .key = .tab, .consumed = 1 }, parseKey("\t").?);
    try std.testing.expectEqualDeep(ParseResult{ .key = .backspace, .consumed = 1 }, parseKey("\x7f").?);
    try std.testing.expectEqualDeep(ParseResult{ .key = .{ .ctrl = 'c' }, .consumed = 1 }, parseKey("\x03").?);
    try std.testing.expectEqualDeep(ParseResult{ .key = .{ .ctrl = 'd' }, .consumed = 1 }, parseKey("\x04").?);
}
