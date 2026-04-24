const std = @import("std");
const autocomplete = @import("autocomplete.zig");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
const keys = @import("../keys.zig");
const select_list = @import("select_list.zig");

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
    autocomplete_catalog: std.ArrayList(select_list.SelectItem) = .empty,
    autocomplete_matches: []select_list.SelectItem = &.{},
    autocomplete_list: ?select_list.SelectList = null,
    autocomplete_max_visible: usize = 5,

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Editor) void {
        self.clearAutocomplete();
        self.freeAutocompleteCatalog();
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
            .column = displayColumn(self.buffer.items, line_start, self.cursor),
        };
    }

    pub fn setAutocompleteItems(self: *Editor, items: []const select_list.SelectItem) !void {
        self.clearAutocomplete();
        self.freeAutocompleteCatalog();

        try self.autocomplete_catalog.ensureTotalCapacity(self.allocator, items.len);
        for (items) |item| {
            const value = try self.allocator.dupe(u8, item.value);
            errdefer self.allocator.free(value);
            const label = try self.allocator.dupe(u8, item.label);
            errdefer self.allocator.free(label);
            const description = if (item.description) |description|
                try self.allocator.dupe(u8, description)
            else
                null;
            errdefer if (description) |owned| self.allocator.free(owned);

            try self.autocomplete_catalog.append(self.allocator, .{
                .value = value,
                .label = label,
                .description = description,
            });
        }
    }

    pub fn isShowingAutocomplete(self: *const Editor) bool {
        return self.autocomplete_list != null;
    }

    pub fn selectedAutocompleteItem(self: *const Editor) ?select_list.SelectItem {
        const list = self.autocomplete_list orelse return null;
        return list.selectedItem();
    }

    pub fn renderAutocompleteInto(
        self: *const Editor,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const list = self.autocomplete_list orelse return;
        try list.renderInto(allocator, width, lines);
    }

    pub fn handleKey(self: *Editor, key: keys.Key) !HandleResult {
        if (self.autocomplete_list) |*list| {
            switch (key) {
                .escape => {
                    self.clearAutocomplete();
                    return .handled;
                },
                .up, .down => {
                    _ = list.handleKey(key);
                    return .handled;
                },
                .tab, .enter => {
                    try self.applySelectedAutocomplete();
                    return .handled;
                },
                else => {},
            }
        }

        switch (key) {
            .printable => |printable| {
                try self.insertSlice(printable.slice());
                try self.refreshAutocomplete(false);
                return .handled;
            },
            .tab => {
                try self.refreshAutocomplete(true);
                return .handled;
            },
            .enter => {
                try self.insertSlice("\n");
                self.clearAutocomplete();
                return .handled;
            },
            .backspace => {
                self.backspace();
                try self.refreshAutocomplete(false);
                return .handled;
            },
            .left => {
                self.moveLeft();
                try self.refreshAutocomplete(false);
                return .handled;
            },
            .right => {
                self.moveRight();
                try self.refreshAutocomplete(false);
                return .handled;
            },
            .up => {
                self.moveVertical(-1);
                try self.refreshAutocomplete(false);
                return .handled;
            },
            .down => {
                self.moveVertical(1);
                try self.refreshAutocomplete(false);
                return .handled;
            },
            .ctrl => |ctrl| switch (ctrl) {
                'c' => return .interrupt,
                'd' => return .exit,
                else => return .ignored,
            },
            .escape => return .ignored,
            else => return .ignored,
        }
    }

    pub fn handlePaste(self: *Editor, pasted: []const u8) !HandleResult {
        try self.insertSlice(pasted);
        self.clearAutocomplete();
        return .handled;
    }

    pub fn renderInto(
        self: *const Editor,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        try self.renderTextInto(allocator, width, lines);

        if (self.autocomplete_list) |list| {
            const effective_width = @max(width, 1);
            try list.renderInto(allocator, effective_width, lines);
        }
    }

    pub fn renderTextInto(
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
            const rendered = try renderVisualLine(allocator, "", 0, self.padding_x, effective_width);
            defer allocator.free(rendered);
            try component_mod.appendOwnedLine(lines, allocator, rendered);
        } else {
            var start: usize = 0;
            while (true) {
                const rel_end = std.mem.indexOfScalar(u8, self.buffer.items[start..], '\n');
                const end = if (rel_end) |index| start + index else self.buffer.items.len;
                const cursor_offset = if (self.cursor >= start and self.cursor <= end) self.cursor - start else null;
                try appendWrappedLogicalLine(
                    allocator,
                    self.buffer.items[start..end],
                    cursor_offset,
                    self.padding_x,
                    effective_width,
                    lines,
                );

                if (rel_end == null) break;

                start = end + 1;
                if (start == self.buffer.items.len) {
                    const trailing_cursor = if (self.cursor == self.buffer.items.len) @as(?usize, 0) else null;
                    try appendWrappedLogicalLine(allocator, "", trailing_cursor, self.padding_x, effective_width, lines);
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

    fn applySelectedAutocomplete(self: *Editor) !void {
        const list = self.autocomplete_list orelse return;
        const item = list.selectedItem() orelse {
            self.clearAutocomplete();
            return;
        };
        const range = self.currentAutocompleteRange(true) orelse {
            self.clearAutocomplete();
            return;
        };
        try self.replaceRange(range.start, range.end, item.value);
        self.clearAutocomplete();
    }

    fn replaceRange(self: *Editor, start: usize, end: usize, replacement: []const u8) !void {
        std.debug.assert(start <= end);
        std.debug.assert(end <= self.buffer.items.len);

        const removed_len = end - start;
        const old_len = self.buffer.items.len;

        if (replacement.len > removed_len) {
            const growth = replacement.len - removed_len;
            try self.buffer.ensureUnusedCapacity(self.allocator, growth);
            self.buffer.items.len = old_len + growth;
            std.mem.copyBackwards(u8, self.buffer.items[start + replacement.len ..], self.buffer.items[end..old_len]);
        } else if (replacement.len < removed_len) {
            const new_len = old_len - (removed_len - replacement.len);
            std.mem.copyForwards(u8, self.buffer.items[start + replacement.len .. new_len], self.buffer.items[end..old_len]);
            self.buffer.items.len = new_len;
        }

        @memcpy(self.buffer.items[start .. start + replacement.len], replacement);
        self.cursor = start + replacement.len;
    }

    fn backspace(self: *Editor) void {
        if (self.cursor == 0) return;

        const start = prevCodepointStart(self.buffer.items, self.cursor);
        deleteRange(&self.buffer, start, self.cursor);
        self.cursor = start;
    }

    fn refreshAutocomplete(self: *Editor, force_show_all: bool) !void {
        self.clearAutocomplete();
        if (self.autocomplete_catalog.items.len == 0) return;

        const range = self.currentAutocompleteRange(force_show_all) orelse return;
        const prefix = self.buffer.items[range.start..range.end];

        const matches = try autocomplete.fuzzyFilterAlloc(self.allocator, self.autocomplete_catalog.items, prefix);
        if (matches.len == 0) {
            self.allocator.free(matches);
            return;
        }

        self.autocomplete_matches = matches;
        self.autocomplete_list = .{
            .items = self.autocomplete_matches,
            .max_visible = self.autocomplete_max_visible,
        };
    }

    const Range = struct {
        start: usize,
        end: usize,
    };

    fn currentAutocompleteRange(self: *const Editor, force_show_all: bool) ?Range {
        if (self.cursor > self.buffer.items.len) return null;

        var start = self.cursor;
        while (start > 0 and !isAutocompleteDelimiter(self.buffer.items[start - 1])) : (start -= 1) {}

        if (!force_show_all and start == self.cursor) return null;
        return .{ .start = start, .end = self.cursor };
    }

    fn clearAutocomplete(self: *Editor) void {
        if (self.autocomplete_matches.len > 0) {
            self.allocator.free(self.autocomplete_matches);
        }
        self.autocomplete_matches = &.{};
        self.autocomplete_list = null;
    }

    fn freeAutocompleteCatalog(self: *Editor) void {
        for (self.autocomplete_catalog.items) |item| {
            self.allocator.free(item.value);
            self.allocator.free(item.label);
            if (item.description) |description| self.allocator.free(description);
        }
        self.autocomplete_catalog.clearRetainingCapacity();
        self.autocomplete_catalog.deinit(self.allocator);
        self.autocomplete_catalog = .empty;
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
        const target_column = displayColumn(content, current_start, self.cursor);

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

fn appendWrappedLogicalLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    cursor_offset: ?usize,
    padding_x: usize,
    width: usize,
    lines: *component_mod.LineList,
) std.mem.Allocator.Error!void {
    const content_width = @max(@as(usize, 1), if (width > padding_x) width - padding_x else 1);

    if (line.len == 0) {
        const rendered = try renderVisualLine(allocator, "", cursor_offset, padding_x, width);
        defer allocator.free(rendered);
        try component_mod.appendOwnedLine(lines, allocator, rendered);
        return;
    }

    var segment_start: usize = 0;
    var segment_width: usize = 0;
    var cursor: usize = 0;

    while (cursor < line.len) {
        const cluster = ansi.nextDisplayCluster(line, cursor);
        if (segment_width > 0 and segment_width + cluster.width > content_width) {
            try appendWrappedSegment(allocator, line, segment_start, cursor, cursor_offset, padding_x, width, false, lines);
            segment_start = cursor;
            segment_width = 0;
        }

        segment_width += cluster.width;
        cursor = cluster.end;
    }

    try appendWrappedSegment(allocator, line, segment_start, line.len, cursor_offset, padding_x, width, true, lines);
}

fn appendWrappedSegment(
    allocator: std.mem.Allocator,
    line: []const u8,
    segment_start: usize,
    segment_end: usize,
    cursor_offset: ?usize,
    padding_x: usize,
    width: usize,
    is_last_segment: bool,
    lines: *component_mod.LineList,
) std.mem.Allocator.Error!void {
    const segment_cursor = if (cursor_offset) |offset|
        if (offset >= segment_start and (offset < segment_end or (is_last_segment and offset == segment_end)))
            @as(?usize, offset - segment_start)
        else
            null
    else
        null;

    const rendered = try renderVisualLine(allocator, line[segment_start..segment_end], segment_cursor, padding_x, width);
    defer allocator.free(rendered);
    try component_mod.appendOwnedLine(lines, allocator, rendered);
}

fn renderVisualLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    cursor_offset: ?usize,
    padding_x: usize,
    width: usize,
) std.mem.Allocator.Error![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    try builder.appendNTimes(allocator, ' ', padding_x);

    if (cursor_offset) |offset| {
        const clamped = @min(offset, line.len);
        try builder.appendSlice(allocator, line[0..clamped]);
        if (clamped < line.len) {
            const cluster = ansi.nextDisplayCluster(line, clamped);
            try builder.appendSlice(allocator, "\x1b[7m");
            try builder.appendSlice(allocator, line[clamped..cluster.end]);
            try builder.appendSlice(allocator, "\x1b[0m");
            try builder.appendSlice(allocator, line[cluster.end..]);
        } else {
            try builder.appendSlice(allocator, "\x1b[7m \x1b[0m");
        }
    } else {
        try builder.appendSlice(allocator, line);
    }

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

fn displayColumn(text: []const u8, start: usize, end: usize) usize {
    var column: usize = 0;
    var cursor = start;
    while (cursor < @min(end, text.len)) {
        const cluster = ansi.nextDisplayCluster(text, cursor);
        cursor = cluster.end;
        column += cluster.width;
    }
    return column;
}

fn indexForColumn(text: []const u8, start: usize, end: usize, target_column: usize) usize {
    var cursor = start;
    var column: usize = 0;
    while (cursor < end) {
        const cluster = ansi.nextDisplayCluster(text, cursor);
        if (column + cluster.width > target_column) break;
        cursor = cluster.end;
        column += cluster.width;
        if (column >= target_column) break;
    }
    return cursor;
}

fn isAutocompleteDelimiter(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

test "editor accepts typed characters and renders content" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    const inputs = [_][]const u8{ "h", "e", "l", "l", "o" };
    for (inputs) |input| {
        const parsed = keys.parseKey(input).?;
        try std.testing.expect(parsed == .parsed);
        try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(parsed.parsed.key));
    }

    try std.testing.expectEqualStrings("hello", editor.text());
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 5 }, editor.cursorPosition());

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try editor.renderInto(allocator, 8, &lines);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(usize, 8), ansi.visibleWidth(lines.items[0]));
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "\x1b[7m \x1b[0m") != null);
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

test "editor shows fuzzy-ranked autocomplete suggestions as user types" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();
    try editor.setAutocompleteItems(&[_]select_list.SelectItem{
        .{ .value = "reload", .label = "reload" },
        .{ .value = "read", .label = "read" },
        .{ .value = "render", .label = "render" },
    });

    _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice("r") });
    _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice("d") });

    try std.testing.expect(editor.isShowingAutocomplete());
    try std.testing.expectEqualStrings("read", editor.selectedAutocompleteItem().?.value);

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try editor.renderInto(allocator, 16, &lines);

    try std.testing.expect(lines.items.len >= 2);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "read") != null);
}

test "editor autocomplete navigates suggestions and applies tab selection" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();
    try editor.setAutocompleteItems(&[_]select_list.SelectItem{
        .{ .value = "apple", .label = "apple" },
        .{ .value = "apricot", .label = "apricot" },
    });

    _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice("a") });
    _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice("p") });
    _ = try editor.handleKey(.down);
    _ = try editor.handleKey(.tab);

    try std.testing.expectEqualStrings("apricot", editor.text());
    try std.testing.expect(!editor.isShowingAutocomplete());
}

test "editor autocomplete enter confirms selection without inserting newline" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();
    try editor.setAutocompleteItems(&[_]select_list.SelectItem{
        .{ .value = "model", .label = "model" },
        .{ .value = "modern", .label = "modern" },
    });

    _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice("m") });
    _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice("o") });
    _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice("d") });
    _ = try editor.handleKey(.down);
    _ = try editor.handleKey(.enter);

    try std.testing.expectEqualStrings("modern", editor.text());
    try std.testing.expect(std.mem.indexOfScalar(u8, editor.text(), '\n') == null);
}

test "editor inserts bracketed paste content as a single edit" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice("x") });
    try std.testing.expectEqual(HandleResult.handled, try editor.handlePaste("hello\nworld"));

    try std.testing.expectEqualStrings("xhello\nworld", editor.text());
    try std.testing.expectEqual(CursorPosition{ .line = 1, .column = 5 }, editor.cursorPosition());
}

test "editor renders wrapped multi-line content and tracks wide cursor columns" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try std.testing.expectEqual(HandleResult.handled, try editor.handlePaste("ab你好🙂\nxy"));
    try std.testing.expectEqual(CursorPosition{ .line = 1, .column = 2 }, editor.cursorPosition());

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try editor.renderTextInto(allocator, 6, &lines);

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("ab你好", lines.items[0]);
    try std.testing.expectEqual(@as(usize, 6), ansi.visibleWidth(lines.items[1]));
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "🙂") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[2], "xy") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[2], "\x1b[7m \x1b[0m") != null);
}

test "editor cursor column uses display width for wide graphemes" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try std.testing.expectEqual(HandleResult.handled, try editor.handlePaste("你🙂a"));
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 5 }, editor.cursorPosition());
}
