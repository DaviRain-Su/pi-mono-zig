const std = @import("std");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
const keys = @import("../keys.zig");

pub const HandleResult = enum {
    handled,
    interrupt,
    exit,
    ignored,
};

pub const CursorPosition = struct {
    line: usize,
    column: usize,
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    padding_x: usize = 0,
    padding_y: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn component(self: *const Editor) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn text(self: *const Editor) []const u8 {
        return self.buffer.items;
    }

    pub fn cursorIndex(self: *const Editor) usize {
        return self.cursor;
    }

    pub fn cursorPosition(self: *const Editor) CursorPosition {
        const line_start = lineStart(self.buffer.items, self.cursor);
        return .{
            .line = lineNumber(self.buffer.items, self.cursor),
            .column = utf8Column(self.buffer.items, line_start, self.cursor),
        };
    }

    pub fn handleKey(self: *Editor, key: keys.Key) !HandleResult {
        switch (key) {
            .printable => |printable| {
                try self.insertSlice(printable.slice());
                return .handled;
            },
            .enter => {
                try self.insertSlice("\n");
                return .handled;
            },
            .backspace => {
                self.backspace();
                return .handled;
            },
            .left => {
                self.moveLeft();
                return .handled;
            },
            .right => {
                self.moveRight();
                return .handled;
            },
            .up => {
                self.moveVertical(-1);
                return .handled;
            },
            .down => {
                self.moveVertical(1);
                return .handled;
            },
            .ctrl => |ctrl| switch (ctrl) {
                'c' => return .interrupt,
                'd' => return .exit,
                else => return .ignored,
            },
            .escape => return .ignored,
        }
    }

    pub fn renderInto(
        self: *const Editor,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const effective_width = @max(width, 1);

        const blank_line = try allocator.alloc(u8, effective_width);
        defer allocator.free(blank_line);
        @memset(blank_line, ' ');

        for (0..self.padding_y) |_| {
            try component_mod.appendOwnedLine(lines, allocator, blank_line);
        }

        if (self.buffer.items.len == 0) {
            try component_mod.appendOwnedLine(lines, allocator, blank_line);
        } else {
            var start: usize = 0;
            while (true) {
                const rel_end = std.mem.indexOfScalar(u8, self.buffer.items[start..], '\n');
                const end = if (rel_end) |index| start + index else self.buffer.items.len;

                const padded = try renderLine(allocator, self.buffer.items[start..end], self.padding_x, effective_width);
                defer allocator.free(padded);
                try component_mod.appendOwnedLine(lines, allocator, padded);

                if (rel_end == null) break;

                start = end + 1;
                if (start == self.buffer.items.len) {
                    const trailing = try renderLine(allocator, "", self.padding_x, effective_width);
                    defer allocator.free(trailing);
                    try component_mod.appendOwnedLine(lines, allocator, trailing);
                    break;
                }
            }
        }

        for (0..self.padding_y) |_| {
            try component_mod.appendOwnedLine(lines, allocator, blank_line);
        }
    }

    fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const Editor = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }

    fn insertSlice(self: *Editor, slice: []const u8) !void {
        try self.buffer.ensureUnusedCapacity(self.allocator, slice.len);

        const old_len = self.buffer.items.len;
        self.buffer.items.len = old_len + slice.len;
        std.mem.copyBackwards(u8, self.buffer.items[self.cursor + slice.len ..], self.buffer.items[self.cursor..old_len]);
        @memcpy(self.buffer.items[self.cursor .. self.cursor + slice.len], slice);
        self.cursor += slice.len;
    }

    fn backspace(self: *Editor) void {
        if (self.cursor == 0) return;

        const start = prevCodepointStart(self.buffer.items, self.cursor);
        deleteRange(&self.buffer, start, self.cursor);
        self.cursor = start;
    }

    fn moveLeft(self: *Editor) void {
        self.cursor = prevCodepointStart(self.buffer.items, self.cursor);
    }

    fn moveRight(self: *Editor) void {
        self.cursor = nextCodepointEnd(self.buffer.items, self.cursor);
    }

    fn moveVertical(self: *Editor, direction: i2) void {
        const content = self.buffer.items;
        const current_start = lineStart(content, self.cursor);
        const current_end = lineEnd(content, self.cursor);
        const target_column = utf8Column(content, current_start, self.cursor);

        if (direction < 0) {
            if (current_start == 0) return;

            const previous_end = current_start - 1;
            const previous_start = lineStart(content, previous_end);
            self.cursor = indexForColumn(content, previous_start, previous_end, target_column);
            return;
        }

        if (current_end == content.len) return;

        const next_start = current_end + 1;
        const next_end = lineEnd(content, next_start);
        self.cursor = indexForColumn(content, next_start, next_end, target_column);
    }
};

fn renderLine(allocator: std.mem.Allocator, line: []const u8, padding_x: usize, width: usize) std.mem.Allocator.Error![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    try builder.appendNTimes(allocator, ' ', padding_x);
    try builder.appendSlice(allocator, line);

    const padded = try ansi.padRightVisibleAlloc(allocator, builder.items, width);
    builder.deinit(allocator);
    return padded;
}

fn deleteRange(buffer: *std.ArrayList(u8), start: usize, end: usize) void {
    if (end <= start) return;

    const count = end - start;
    std.mem.copyForwards(u8, buffer.items[start .. buffer.items.len - count], buffer.items[end..]);
    buffer.items.len -= count;
}

fn prevCodepointStart(text: []const u8, index: usize) usize {
    if (index == 0) return 0;

    var result = index - 1;
    while (result > 0 and isContinuationByte(text[result])) : (result -= 1) {}
    return result;
}

fn nextCodepointEnd(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;

    var result = index + 1;
    while (result < text.len and isContinuationByte(text[result])) : (result += 1) {}
    return result;
}

fn isContinuationByte(byte: u8) bool {
    return (byte & 0b1100_0000) == 0b1000_0000;
}

fn lineStart(text: []const u8, index: usize) usize {
    var cursor = @min(index, text.len);
    while (cursor > 0) : (cursor -= 1) {
        if (text[cursor - 1] == '\n') return cursor;
    }
    return 0;
}

fn lineEnd(text: []const u8, index: usize) usize {
    var cursor = @min(index, text.len);
    while (cursor < text.len and text[cursor] != '\n') : (cursor += 1) {}
    return cursor;
}

fn lineNumber(text: []const u8, index: usize) usize {
    var count: usize = 0;
    var cursor: usize = 0;
    while (cursor < @min(index, text.len)) : (cursor += 1) {
        if (text[cursor] == '\n') count += 1;
    }
    return count;
}

fn utf8Column(text: []const u8, start: usize, end: usize) usize {
    var column: usize = 0;
    var cursor = start;
    while (cursor < @min(end, text.len)) {
        cursor = nextCodepointEnd(text, cursor);
        column += 1;
    }
    return column;
}

fn indexForColumn(text: []const u8, start: usize, end: usize, target_column: usize) usize {
    var cursor = start;
    var column: usize = 0;
    while (cursor < end and column < target_column) {
        cursor = nextCodepointEnd(text, cursor);
        column += 1;
    }
    return cursor;
}

test "editor accepts typed characters and renders content" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    const inputs = [_][]const u8{ "h", "e", "l", "l", "o" };
    for (inputs) |input| {
        const parsed = keys.parseKey(input).?;
        try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(parsed.key));
    }

    try std.testing.expectEqualStrings("hello", editor.text());
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 5 }, editor.cursorPosition());

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try editor.renderInto(allocator, 8, &lines);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("hello   ", lines.items[0]);
}

test "editor cursor moves with arrow keys" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    for ([_]keys.Key{
        .{ .printable = keys.PrintableKey.fromSlice("h") },
        .{ .printable = keys.PrintableKey.fromSlice("e") },
        .{ .printable = keys.PrintableKey.fromSlice("l") },
        .{ .printable = keys.PrintableKey.fromSlice("l") },
        .{ .printable = keys.PrintableKey.fromSlice("o") },
    }) |key| {
        _ = try editor.handleKey(key);
    }

    _ = try editor.handleKey(.left);
    _ = try editor.handleKey(.left);

    try std.testing.expectEqual(@as(usize, 3), editor.cursorIndex());
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 3 }, editor.cursorPosition());
}

test "editor backspace deletes before cursor" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    for ([_]keys.Key{
        .{ .printable = keys.PrintableKey.fromSlice("h") },
        .{ .printable = keys.PrintableKey.fromSlice("e") },
        .{ .printable = keys.PrintableKey.fromSlice("l") },
        .{ .printable = keys.PrintableKey.fromSlice("l") },
        .{ .printable = keys.PrintableKey.fromSlice("o") },
    }) |key| {
        _ = try editor.handleKey(key);
    }

    _ = try editor.handleKey(.left);
    _ = try editor.handleKey(.backspace);

    try std.testing.expectEqualStrings("helo", editor.text());
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 3 }, editor.cursorPosition());
}
