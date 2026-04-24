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
    shift_tab,
    up,
    down,
    left,
    right,
    home,
    end,
    insert,
    delete,
    page_up,
    page_down,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    bracketed_paste_start,
    bracketed_paste_end,
    unknown_escape,
};

pub const ParsedKey = struct {
    key: Key,
    consumed: usize,
};

pub const InputEvent = union(enum) {
    key: Key,
    paste: []const u8,
};

pub const ParsedInput = struct {
    event: InputEvent,
    consumed: usize,
};

pub const ParseResult = union(enum) {
    parsed: ParsedKey,
    need_more_bytes,
};

pub const InputParseResult = union(enum) {
    parsed: ParsedInput,
    need_more_bytes,
};

const ParseMode = enum {
    buffering,
    flush,
};

const BRACKETED_PASTE_START = "\x1b[200~";
const BRACKETED_PASTE_END = "\x1b[201~";

pub fn parseInputEvent(input: []const u8) ?InputParseResult {
    return parseInputEventWithMode(input, .buffering);
}

pub fn flushInputEvent(input: []const u8) ?ParsedInput {
    const result = parseInputEventWithMode(input, .flush) orelse return null;
    return switch (result) {
        .parsed => |parsed_input| parsed_input,
        .need_more_bytes => null,
    };
}

pub fn parseKey(input: []const u8) ?ParseResult {
    return parseKeyWithMode(input, .buffering);
}

pub fn flushKey(input: []const u8) ?ParsedKey {
    const result = parseKeyWithMode(input, .flush) orelse return null;
    return switch (result) {
        .parsed => |parsed_key| parsed_key,
        .need_more_bytes => null,
    };
}

fn parseKeyWithMode(input: []const u8, mode: ParseMode) ?ParseResult {
    if (input.len == 0) return null;

    const first = input[0];
    if (first == '\r' or first == '\n') {
        return parsed(.enter, 1);
    }

    switch (first) {
        0x09 => return parsed(.tab, 1),
        0x7f, 0x08 => return parsed(.backspace, 1),
        0x1b => return parseEscapeSequence(input, mode),
        0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a => return parsed(.{ .ctrl = @as(u8, 'a') + first - 1 }, 1),
        else => {},
    }

    if (first < 0x20) return null;

    const sequence_len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    if (input.len < sequence_len) {
        return .need_more_bytes;
    }

    return parsed(.{ .printable = PrintableKey.fromSlice(input[0..sequence_len]) }, sequence_len);
}

fn parseInputEventWithMode(input: []const u8, mode: ParseMode) ?InputParseResult {
    if (input.len == 0) return null;

    if (matchesBracketedPastePrefix(input)) {
        return .need_more_bytes;
    }

    if (std.mem.startsWith(u8, input, BRACKETED_PASTE_START)) {
        const content_start = BRACKETED_PASTE_START.len;
        const end_relative = std.mem.indexOf(u8, input[content_start..], BRACKETED_PASTE_END) orelse return .need_more_bytes;
        const content_end = content_start + end_relative;
        return .{
            .parsed = .{
                .event = .{ .paste = input[content_start..content_end] },
                .consumed = content_end + BRACKETED_PASTE_END.len,
            },
        };
    }

    const result = parseKeyWithMode(input, mode) orelse return null;
    return switch (result) {
        .parsed => |parsed_key| .{
            .parsed = .{
                .event = .{ .key = parsed_key.key },
                .consumed = parsed_key.consumed,
            },
        },
        .need_more_bytes => .need_more_bytes,
    };
}

fn matchesBracketedPastePrefix(input: []const u8) bool {
    return input.len < BRACKETED_PASTE_START.len and std.mem.startsWith(u8, BRACKETED_PASTE_START, input);
}

fn parsed(key: Key, consumed: usize) ParseResult {
    return .{
        .parsed = .{
            .key = key,
            .consumed = consumed,
        },
    };
}

fn parseEscapeSequence(input: []const u8, mode: ParseMode) ParseResult {
    if (input.len == 1) {
        return switch (mode) {
            .buffering => .need_more_bytes,
            .flush => parsed(.escape, 1),
        };
    }

    return switch (input[1]) {
        '[' => parseCsiSequence(input, mode),
        'O' => parseSs3Sequence(input, mode),
        else => parseMetaEscapeSequence(input, mode),
    };
}

fn parseCsiSequence(input: []const u8, mode: ParseMode) ParseResult {
    const sequence_len = findCsiSequenceLength(input) orelse {
        return switch (mode) {
            .buffering => .need_more_bytes,
            .flush => parsed(.unknown_escape, input.len),
        };
    };

    return parseCompleteCsiSequence(input[0..sequence_len]);
}

fn findCsiSequenceLength(input: []const u8) ?usize {
    var index: usize = 2;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (byte >= 0x40 and byte <= 0x7e) return index + 1;
    }
    return null;
}

fn parseCompleteCsiSequence(sequence: []const u8) ParseResult {
    if (std.mem.eql(u8, sequence, "\x1b[A")) return parsed(.up, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[B")) return parsed(.down, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[C")) return parsed(.right, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[D")) return parsed(.left, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[H") or std.mem.eql(u8, sequence, "\x1b[1~") or std.mem.eql(u8, sequence, "\x1b[7~")) {
        return parsed(.home, sequence.len);
    }
    if (std.mem.eql(u8, sequence, "\x1b[F") or std.mem.eql(u8, sequence, "\x1b[4~") or std.mem.eql(u8, sequence, "\x1b[8~")) {
        return parsed(.end, sequence.len);
    }
    if (std.mem.eql(u8, sequence, "\x1b[Z")) return parsed(.shift_tab, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[2~")) return parsed(.insert, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[3~")) return parsed(.delete, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[5~") or std.mem.eql(u8, sequence, "\x1b[[5~")) return parsed(.page_up, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[6~") or std.mem.eql(u8, sequence, "\x1b[[6~")) return parsed(.page_down, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[200~")) return parsed(.bracketed_paste_start, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[201~")) return parsed(.bracketed_paste_end, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[11~") or std.mem.eql(u8, sequence, "\x1b[[A")) return parsed(.f1, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[12~") or std.mem.eql(u8, sequence, "\x1b[[B")) return parsed(.f2, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[13~") or std.mem.eql(u8, sequence, "\x1b[[C")) return parsed(.f3, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[14~") or std.mem.eql(u8, sequence, "\x1b[[D")) return parsed(.f4, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[15~") or std.mem.eql(u8, sequence, "\x1b[[E")) return parsed(.f5, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[17~")) return parsed(.f6, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[18~")) return parsed(.f7, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[19~")) return parsed(.f8, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[20~")) return parsed(.f9, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[21~")) return parsed(.f10, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[23~")) return parsed(.f11, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[24~")) return parsed(.f12, sequence.len);
    return parsed(.unknown_escape, sequence.len);
}

fn parseSs3Sequence(input: []const u8, mode: ParseMode) ParseResult {
    if (input.len < 3) {
        return switch (mode) {
            .buffering => .need_more_bytes,
            .flush => parsed(.unknown_escape, input.len),
        };
    }

    return switch (input[2]) {
        'A' => parsed(.up, 3),
        'B' => parsed(.down, 3),
        'C' => parsed(.right, 3),
        'D' => parsed(.left, 3),
        'H' => parsed(.home, 3),
        'F' => parsed(.end, 3),
        'P' => parsed(.f1, 3),
        'Q' => parsed(.f2, 3),
        'R' => parsed(.f3, 3),
        'S' => parsed(.f4, 3),
        else => parsed(.unknown_escape, 3),
    };
}

fn parseMetaEscapeSequence(input: []const u8, mode: ParseMode) ParseResult {
    const sequence_len = 1 + (std.unicode.utf8ByteSequenceLength(input[1]) catch 1);
    if (input.len < sequence_len) {
        return switch (mode) {
            .buffering => .need_more_bytes,
            .flush => parsed(.unknown_escape, input.len),
        };
    }
    return parsed(.unknown_escape, sequence_len);
}

test "parse printable keys" {
    const ascii = parseKey("a").?;
    try std.testing.expectEqualDeep(ParseResult{
        .parsed = .{
            .key = .{ .printable = PrintableKey.fromSlice("a") },
            .consumed = 1,
        },
    }, ascii);

    const utf8 = parseKey("é").?;
    try std.testing.expectEqualDeep(ParseResult{
        .parsed = .{
            .key = .{ .printable = PrintableKey.fromSlice("é") },
            .consumed = 2,
        },
    }, utf8);
}

test "parse arrow keys from escape sequences" {
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .up, .consumed = 3 } }, parseKey("\x1b[A").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .down, .consumed = 3 } }, parseKey("\x1bOB").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .right, .consumed = 3 } }, parseKey("\x1b[C").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .left, .consumed = 3 } }, parseKey("\x1bOD").?);
}

test "parse enter backspace and ctrl sequences" {
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .enter, .consumed = 1 } }, parseKey("\r").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .tab, .consumed = 1 } }, parseKey("\t").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .backspace, .consumed = 1 } }, parseKey("\x7f").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .{ .ctrl = 'c' }, .consumed = 1 } }, parseKey("\x03").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .{ .ctrl = 'd' }, .consumed = 1 } }, parseKey("\x04").?);
}

test "split escape sequences request more bytes before parsing" {
    try std.testing.expectEqualDeep(ParseResult.need_more_bytes, parseKey("\x1b").?);
    try std.testing.expectEqualDeep(ParseResult.need_more_bytes, parseKey("\x1b[").?);
    try std.testing.expectEqualDeep(ParseResult.need_more_bytes, parseKey("\x1b[20").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .f9, .consumed = 5 } }, parseKey("\x1b[20~").?);
}

test "flushKey resolves standalone escape and discards incomplete escape sequences" {
    try std.testing.expectEqualDeep(ParsedKey{ .key = .escape, .consumed = 1 }, flushKey("\x1b").?);
    try std.testing.expectEqualDeep(ParsedKey{ .key = .unknown_escape, .consumed = 2 }, flushKey("\x1b[").?);
}

test "flushKey keeps incomplete UTF-8 buffered until the sequence is complete" {
    try std.testing.expectEqualDeep(ParseResult.need_more_bytes, parseKey("\xc3").?);
    try std.testing.expect(flushKey("\xc3") == null);
    try std.testing.expectEqualDeep(ParsedKey{
        .key = .{ .printable = PrintableKey.fromSlice("é") },
        .consumed = 2,
    }, flushKey("é").?);
}

test "parse home end function and bracketed paste sequences" {
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .home, .consumed = 3 } }, parseKey("\x1bOH").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .end, .consumed = 3 } }, parseKey("\x1bOF").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .page_up, .consumed = 4 } }, parseKey("\x1b[5~").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .f1, .consumed = 3 } }, parseKey("\x1bOP").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .f12, .consumed = 5 } }, parseKey("\x1b[24~").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .bracketed_paste_start, .consumed = 6 } }, parseKey("\x1b[200~").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .bracketed_paste_end, .consumed = 6 } }, parseKey("\x1b[201~").?);
}

test "parseInputEvent returns bracketed paste content as a single event" {
    const input = "\x1b[200~hello\nworld\x1b[201~!";
    const result = parseInputEvent(input).?;
    try std.testing.expect(result == .parsed);
    try std.testing.expectEqual(@as(usize, 23), result.parsed.consumed);
    switch (result.parsed.event) {
        .paste => |content| try std.testing.expectEqualStrings("hello\nworld", content),
        else => return error.UnexpectedKey,
    }
}

test "parseInputEvent waits for a complete bracketed paste" {
    try std.testing.expectEqualDeep(InputParseResult.need_more_bytes, parseInputEvent("\x1b[20").?);
    try std.testing.expectEqualDeep(InputParseResult.need_more_bytes, parseInputEvent("\x1b[200~partial").?);
    try std.testing.expect(flushInputEvent("\x1b[200~partial") == null);
}

test "parseInputEvent assembles split UTF-8 codepoints across reads" {
    try std.testing.expectEqualDeep(InputParseResult.need_more_bytes, parseInputEvent("\xc3").?);
    try std.testing.expect(flushInputEvent("\xc3") == null);

    const two_byte = parseInputEvent("é").?;
    try std.testing.expect(two_byte == .parsed);
    try std.testing.expectEqual(@as(usize, 2), two_byte.parsed.consumed);
    switch (two_byte.parsed.event) {
        .key => |key| try std.testing.expectEqualDeep(Key{ .printable = PrintableKey.fromSlice("é") }, key),
        else => return error.UnexpectedPaste,
    }

    try std.testing.expectEqualDeep(InputParseResult.need_more_bytes, parseInputEvent("\xf0\x9f").?);
    try std.testing.expect(flushInputEvent("\xf0\x9f") == null);
    try std.testing.expectEqualDeep(InputParseResult.need_more_bytes, parseInputEvent("\xf0\x9f\x99").?);
    try std.testing.expect(flushInputEvent("\xf0\x9f\x99") == null);

    const four_byte = parseInputEvent("🙂").?;
    try std.testing.expect(four_byte == .parsed);
    try std.testing.expectEqual(@as(usize, 4), four_byte.parsed.consumed);
    switch (four_byte.parsed.event) {
        .key => |key| try std.testing.expectEqualDeep(Key{ .printable = PrintableKey.fromSlice("🙂") }, key),
        else => return error.UnexpectedPaste,
    }
}
