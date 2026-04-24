const std = @import("std");
const component = @import("component.zig");

pub const LineList = component.LineList;

pub fn visibleWidth(text: []const u8) usize {
    var index: usize = 0;
    var width: usize = 0;
    while (index < text.len) {
        if (ansiSequenceLength(text, index)) |len| {
            index += len;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        index += @min(len, text.len - index);
        width += 1;
    }
    return width;
}

pub fn padRightVisibleAlloc(allocator: std.mem.Allocator, line: []const u8, width: usize) std.mem.Allocator.Error![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, line);

    const current_width = visibleWidth(line);
    if (current_width < width) {
        try buffer.appendNTimes(allocator, ' ', width - current_width);
    }

    return buffer.toOwnedSlice(allocator);
}

pub fn wrapTextWithAnsi(allocator: std.mem.Allocator, text: []const u8, width: usize, lines: *LineList) std.mem.Allocator.Error!void {
    const effective_width = @max(width, 1);
    var current_line = std.ArrayList(u8).empty;
    defer current_line.deinit(allocator);

    var active_sgr = std.ArrayList(u8).empty;
    defer active_sgr.deinit(allocator);

    var current_width: usize = 0;
    var index: usize = 0;

    while (index < text.len) {
        const byte = text[index];
        if (byte == '\n') {
            try appendWrappedLine(allocator, lines, &current_line, &active_sgr);
            current_width = 0;
            index += 1;
            continue;
        }

        if (ansiSequenceLength(text, index)) |len| {
            const sequence = text[index .. index + len];
            try current_line.appendSlice(allocator, sequence);
            updateActiveSgr(allocator, sequence, &active_sgr);
            index += len;
            continue;
        }

        const rune_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        const actual_len = @min(rune_len, text.len - index);
        if (current_width == effective_width) {
            try appendWrappedLine(allocator, lines, &current_line, &active_sgr);
            current_width = 0;
        }

        try current_line.appendSlice(allocator, text[index .. index + actual_len]);
        current_width += 1;
        index += actual_len;
    }

    if (current_line.items.len > 0 or text.len == 0) {
        try appendWrappedLine(allocator, lines, &current_line, &active_sgr);
    }
}

pub fn sliceVisibleAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    start_col: usize,
    width: usize,
) std.mem.Allocator.Error![]u8 {
    if (width == 0) return allocator.dupe(u8, "");

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    var active_sgr = std.ArrayList(u8).empty;
    defer active_sgr.deinit(allocator);

    const end_col = start_col + width;
    var column: usize = 0;
    var index: usize = 0;
    var started = false;

    while (index < text.len and column < end_col) {
        if (ansiSequenceLength(text, index)) |len| {
            const sequence = text[index .. index + len];
            updateActiveSgr(allocator, sequence, &active_sgr);
            if (started) {
                try builder.appendSlice(allocator, sequence);
            }
            index += len;
            continue;
        }

        const rune_len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const actual_len = @min(rune_len, text.len - index);

        if (column >= start_col and column < end_col) {
            if (!started) {
                started = true;
                if (active_sgr.items.len > 0) {
                    try builder.appendSlice(allocator, active_sgr.items);
                }
            }
            try builder.appendSlice(allocator, text[index .. index + actual_len]);
        }

        column += 1;
        index += actual_len;
    }

    if (started and active_sgr.items.len > 0) {
        try builder.appendSlice(allocator, "\x1b[0m");
    }

    return builder.toOwnedSlice(allocator);
}

fn appendWrappedLine(
    allocator: std.mem.Allocator,
    lines: *LineList,
    current_line: *std.ArrayList(u8),
    active_sgr: *std.ArrayList(u8),
) std.mem.Allocator.Error!void {
    var line = std.ArrayList(u8).empty;
    errdefer line.deinit(allocator);

    try line.appendSlice(allocator, current_line.items);
    if (active_sgr.items.len > 0) {
        try line.appendSlice(allocator, "\x1b[0m");
    }

    try lines.append(allocator, try line.toOwnedSlice(allocator));

    current_line.clearRetainingCapacity();
    if (active_sgr.items.len > 0) {
        try current_line.appendSlice(allocator, active_sgr.items);
    }
}

fn updateActiveSgr(allocator: std.mem.Allocator, sequence: []const u8, active_sgr: *std.ArrayList(u8)) void {
    if (sequence.len < 3) return;
    if (sequence[0] != 0x1b or sequence[1] != '[' or sequence[sequence.len - 1] != 'm') return;

    const params = sequence[2 .. sequence.len - 1];
    if (params.len == 0 or std.mem.eql(u8, params, "0")) {
        active_sgr.clearRetainingCapacity();
        return;
    }

    active_sgr.appendSlice(allocator, sequence) catch return;
}

fn ansiSequenceLength(text: []const u8, start: usize) ?usize {
    if (start + 1 >= text.len or text[start] != 0x1b) return null;

    const kind = text[start + 1];
    switch (kind) {
        '[' => {
            var index = start + 2;
            while (index < text.len) : (index += 1) {
                const byte = text[index];
                if (byte >= 0x40 and byte <= 0x7e) {
                    return index - start + 1;
                }
            }
            return text.len - start;
        },
        ']' => {
            var index = start + 2;
            while (index < text.len) : (index += 1) {
                if (text[index] == 0x07) return index - start + 1;
                if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '\\') {
                    return index - start + 2;
                }
            }
            return text.len - start;
        },
        else => return if (kind >= 0x40 and kind <= 0x5f) 2 else null,
    }
}

test "visible width ignores ANSI escape sequences" {
    try std.testing.expectEqual(@as(usize, 8), visibleWidth("\x1b[31mred\x1b[0m blue"));
}

test "wrap text preserves ANSI state across wrapped lines" {
    const allocator = std.testing.allocator;
    var lines = LineList.empty;
    defer component.freeLines(allocator, &lines);

    try wrapTextWithAnsi(allocator, "\x1b[31mhello world\x1b[0m", 5, &lines);

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("\x1b[31mhello\x1b[0m", lines.items[0]);
    try std.testing.expectEqualStrings("\x1b[31m worl\x1b[0m", lines.items[1]);
    try std.testing.expectEqualStrings("\x1b[31md\x1b[0m", lines.items[2]);
}

test "slice visible range preserves active ANSI state" {
    const allocator = std.testing.allocator;

    const slice = try sliceVisibleAlloc(allocator, "\x1b[31mhello\x1b[0m world", 1, 3);
    defer allocator.free(slice);

    try std.testing.expectEqualStrings("\x1b[31mell\x1b[0m", slice);
}
