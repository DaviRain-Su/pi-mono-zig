const std = @import("std");
const autocomplete = @import("autocomplete.zig");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
const draw_mod = @import("../draw.zig");
const keys = @import("../keys.zig");
const select_list = @import("select_list.zig");
const style_mod = @import("../style.zig");
const test_helpers = @import("../test_helpers.zig");
const resources_mod = @import("../theme.zig");

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

const DEFAULT_PAGE_LINE_COUNT: usize = 5;

pub const Editor = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    padding_x: usize = 0,
    padding_y: usize = 0,
    cursor_shape: vaxis.Cell.CursorShape = .beam_blink,
    theme: ?*const resources_mod.Theme = null,
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

    pub fn drawComponent(self: *const Editor) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
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

    pub fn drawAutocomplete(
        self: *const Editor,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const list = self.autocomplete_list orelse {
            window.clear();
            return .{ .width = window.width, .height = 0 };
        };
        return list.draw(window, ctx);
    }

    pub fn drawAutocompleteComponent(self: *const Editor) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawAutocompleteOpaque,
        };
    }

    pub fn setTheme(self: *Editor, theme: ?*const resources_mod.Theme) void {
        self.theme = theme;
        if (self.autocomplete_list) |*list| {
            list.theme = theme;
        }
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
            .ctrl_left => {
                self.moveWordBackwards();
                try self.refreshAutocomplete(false);
                return .handled;
            },
            .ctrl_right => {
                self.moveWordForwards();
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
            .home => {
                self.moveToLineStart();
                try self.refreshAutocomplete(false);
                return .handled;
            },
            .end => {
                self.moveToLineEnd();
                try self.refreshAutocomplete(false);
                return .handled;
            },
            .delete => {
                self.deleteForward();
                try self.refreshAutocomplete(false);
                return .handled;
            },
            .page_up => {
                self.movePage(-1);
                try self.refreshAutocomplete(false);
                return .handled;
            },
            .page_down => {
                self.movePage(1);
                try self.refreshAutocomplete(false);
                return .handled;
            },
            .ctrl => |ctrl| switch (ctrl) {
                'a' => {
                    self.moveToLineStart();
                    try self.refreshAutocomplete(false);
                    return .handled;
                },
                'c' => return .interrupt,
                'd' => return .exit,
                'e' => {
                    self.moveToLineEnd();
                    try self.refreshAutocomplete(false);
                    return .handled;
                },
                'k' => {
                    self.deleteToLineEnd();
                    try self.refreshAutocomplete(false);
                    return .handled;
                },
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

    pub fn reset(self: *Editor) void {
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
        self.clearAutocomplete();
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

    pub fn draw(
        self: *const Editor,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const active_theme = ctx.theme orelse self.theme;
        const base_style = if (active_theme) |theme|
            style_mod.styleFor(theme, .editor)
        else
            vaxis.Cell.Style{};

        window.fill(.{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = base_style,
        });

        const content_window = innerWindow(window, self.padding_x, self.padding_y) orelse {
            return .{
                .width = window.width,
                .height = @min(window.height, @as(u16, @intCast(self.padding_y * 2 + 1))),
            };
        };

        if (self.buffer.items.len > 0) {
            _ = content_window.printSegment(.{
                .text = self.buffer.items,
                .style = base_style,
            }, .{ .wrap = .grapheme });
        }

        const cursor = measureCursor(self.buffer.items, self.cursor, content_window, base_style);
        const text_height = @max(
            measureRenderedHeight(self.buffer.items, content_window, base_style),
            @as(usize, cursor.row) + 1,
        );
        content_window.showCursor(cursor.col, cursor.row);
        content_window.setCursorShape(self.cursor_shape);

        const total_height = @min(
            window.height,
            @as(u16, @intCast(@min(
                @as(usize, std.math.maxInt(u16)),
                self.padding_y * 2 + text_height,
            ))),
        );
        return .{
            .width = window.width,
            .height = total_height,
        };
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
            if (self.theme) |theme| {
                const themed = try theme.applyAlloc(allocator, .editor, blank_line);
                defer allocator.free(themed);
                try component_mod.appendOwnedLine(lines, allocator, themed);
            } else {
                try component_mod.appendOwnedLine(lines, allocator, blank_line);
            }
        }

        if (self.buffer.items.len == 0) {
            const rendered = try renderVisualLine(allocator, self.theme, "", 0, self.padding_x, effective_width);
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
                    self.theme,
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
                    try appendWrappedLogicalLine(allocator, self.theme, "", trailing_cursor, self.padding_x, effective_width, lines);
                    break;
                }
            }
        }

        for (0..self.padding_y) |_| {
            if (self.theme) |theme| {
                const themed = try theme.applyAlloc(allocator, .editor, blank_line);
                defer allocator.free(themed);
                try component_mod.appendOwnedLine(lines, allocator, themed);
            } else {
                try component_mod.appendOwnedLine(lines, allocator, blank_line);
            }
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

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Editor = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }

    fn drawAutocompleteOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Editor = @ptrCast(@alignCast(ptr));
        return self.drawAutocomplete(window, ctx);
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
        const wants_slash_commands = prefix.len > 0 and prefix[0] == '/';

        var filtered_catalog = std.ArrayList(select_list.SelectItem).empty;
        defer filtered_catalog.deinit(self.allocator);
        try filtered_catalog.ensureTotalCapacity(self.allocator, self.autocomplete_catalog.items.len);
        for (self.autocomplete_catalog.items) |item| {
            const is_slash_command = std.mem.startsWith(u8, item.value, "/");
            if (wants_slash_commands != is_slash_command) continue;
            try filtered_catalog.append(self.allocator, item);
        }
        if (filtered_catalog.items.len == 0) return;

        const matches = try autocomplete.fuzzyFilterAlloc(self.allocator, filtered_catalog.items, prefix);
        if (matches.len == 0) {
            self.allocator.free(matches);
            return;
        }

        self.autocomplete_matches = matches;
        self.autocomplete_list = .{
            .items = self.autocomplete_matches,
            .max_visible = self.autocomplete_max_visible,
            .theme = self.theme,
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

    fn moveToLineStart(self: *Editor) void {
        self.cursor = lineStart(self.buffer.items, self.cursor);
    }

    fn moveToLineEnd(self: *Editor) void {
        self.cursor = lineEnd(self.buffer.items, self.cursor);
    }

    fn deleteForward(self: *Editor) void {
        if (self.cursor >= self.buffer.items.len) return;

        const end = nextCodepointEnd(self.buffer.items, self.cursor);
        deleteRange(&self.buffer, self.cursor, end);
    }

    fn deleteToLineEnd(self: *Editor) void {
        const content = self.buffer.items;
        const current_end = lineEnd(content, self.cursor);

        if (self.cursor < current_end) {
            deleteRange(&self.buffer, self.cursor, current_end);
            return;
        }

        if (current_end < content.len) {
            deleteRange(&self.buffer, current_end, current_end + 1);
        }
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

    fn movePage(self: *Editor, direction: i2) void {
        const content = self.buffer.items;
        const current_start = lineStart(content, self.cursor);
        const target_column = displayColumn(content, current_start, self.cursor);

        var target_start = current_start;
        var remaining = DEFAULT_PAGE_LINE_COUNT;
        while (remaining > 0) : (remaining -= 1) {
            if (direction < 0) {
                if (target_start == 0) break;

                const previous_end = target_start - 1;
                target_start = lineStart(content, previous_end);
            } else {
                const target_end = lineEnd(content, target_start);
                if (target_end == content.len) break;

                target_start = target_end + 1;
            }
        }

        const target_end = lineEnd(content, target_start);
        self.cursor = indexForColumn(content, target_start, target_end, target_column);
    }

    fn moveWordBackwards(self: *Editor) void {
        const content = self.buffer.items;
        const current_start = lineStart(content, self.cursor);

        if (self.cursor == current_start) {
            if (current_start == 0) return;

            const previous_end = current_start - 1;
            self.cursor = lineEnd(content, previous_end);
            return;
        }

        var cursor = self.cursor;
        while (cursor > current_start) {
            const previous = prevCodepointStart(content, cursor);
            if (classifySlice(content[previous..cursor]) != .whitespace) break;
            cursor = previous;
        }

        if (cursor == current_start) {
            self.cursor = current_start;
            return;
        }

        var previous = prevCodepointStart(content, cursor);
        const target_class = classifySlice(content[previous..cursor]);
        cursor = previous;

        while (cursor > current_start) {
            previous = prevCodepointStart(content, cursor);
            if (classifySlice(content[previous..cursor]) != target_class) break;
            cursor = previous;
        }

        self.cursor = cursor;
    }

    fn moveWordForwards(self: *Editor) void {
        const content = self.buffer.items;
        const current_end = lineEnd(content, self.cursor);

        if (self.cursor >= current_end) {
            if (current_end < content.len) {
                self.cursor = current_end + 1;
            }
            return;
        }

        var cursor = self.cursor;
        while (cursor < current_end) {
            const next = nextCodepointEnd(content, cursor);
            if (classifySlice(content[cursor..next]) != .whitespace) break;
            cursor = next;
        }

        if (cursor >= current_end) {
            self.cursor = current_end;
            return;
        }

        const target_class = classifySlice(content[cursor..nextCodepointEnd(content, cursor)]);
        while (cursor < current_end) {
            const next = nextCodepointEnd(content, cursor);
            if (classifySlice(content[cursor..next]) != target_class) break;
            cursor = next;
        }

        self.cursor = cursor;
    }
};

fn innerWindow(window: vaxis.Window, padding_x: usize, padding_y: usize) ?vaxis.Window {
    const pad_x: u16 = @intCast(@min(padding_x, window.width));
    const pad_y: u16 = @intCast(@min(padding_y, window.height));
    if (window.width <= pad_x * 2 or window.height <= pad_y * 2) return null;
    return window.child(.{
        .x_off = @intCast(pad_x),
        .y_off = @intCast(pad_y),
        .width = window.width - pad_x * 2,
        .height = window.height - pad_y * 2,
    });
}

const MeasuredCursor = struct {
    col: u16,
    row: u16,
};

fn measureRenderedHeight(text: []const u8, window: vaxis.Window, style: vaxis.Cell.Style) usize {
    if (text.len == 0) return 1;
    const result = window.printSegment(.{
        .text = text,
        .style = style,
    }, .{
        .wrap = .grapheme,
        .commit = false,
    });
    if (result.overflow) return window.height;
    return @max(@as(usize, 1), @as(usize, result.row) + 1);
}

fn measureCursor(text: []const u8, cursor_index: usize, window: vaxis.Window, style: vaxis.Cell.Style) MeasuredCursor {
    if (text.len == 0) return .{ .col = 0, .row = 0 };
    const clamped = @min(cursor_index, text.len);
    if (clamped == 0) return .{ .col = 0, .row = 0 };
    const result = window.printSegment(.{
        .text = text[0..clamped],
        .style = style,
    }, .{
        .wrap = .grapheme,
        .commit = false,
    });
    if (result.col >= window.width and window.width > 0) {
        if (result.row + 1 < window.height) {
            return .{
                .col = 0,
                .row = result.row + 1,
            };
        }
        return .{
            .col = window.width - 1,
            .row = @min(result.row, window.height - 1),
        };
    }
    return .{
        .col = result.col,
        .row = @min(result.row, if (window.height == 0) 0 else window.height - 1),
    };
}

fn appendWrappedLogicalLine(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    line: []const u8,
    cursor_offset: ?usize,
    padding_x: usize,
    width: usize,
    lines: *component_mod.LineList,
) std.mem.Allocator.Error!void {
    const content_width = @max(@as(usize, 1), if (width > padding_x) width - padding_x else 1);

    if (line.len == 0) {
        const rendered = try renderVisualLine(allocator, theme, "", cursor_offset, padding_x, width);
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
            try appendWrappedSegment(allocator, theme, line, segment_start, cursor, cursor_offset, padding_x, width, false, lines);
            segment_start = cursor;
            segment_width = 0;
        }

        segment_width += cluster.width;
        cursor = cluster.end;
    }

    try appendWrappedSegment(allocator, theme, line, segment_start, line.len, cursor_offset, padding_x, width, true, lines);
}

fn appendWrappedSegment(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
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

    const rendered = try renderVisualLine(allocator, theme, line[segment_start..segment_end], segment_cursor, padding_x, width);
    defer allocator.free(rendered);
    try component_mod.appendOwnedLine(lines, allocator, rendered);
}

fn renderVisualLine(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    line: []const u8,
    cursor_offset: ?usize,
    padding_x: usize,
    width: usize,
) std.mem.Allocator.Error![]u8 {
    if (theme == null) {
        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);

        try builder.appendNTimes(allocator, ' ', padding_x);

        if (cursor_offset) |offset| {
            const clamped = @min(offset, line.len);
            try builder.appendSlice(allocator, line[0..clamped]);
            if (clamped < line.len) {
                const cluster = ansi.nextDisplayCluster(line, clamped);
                try builder.appendSlice(allocator, line[clamped..cluster.end]);
                try builder.appendSlice(allocator, line[cluster.end..]);
            } else {
                try builder.append(allocator, ' ');
            }
        } else {
            try builder.appendSlice(allocator, line);
        }

        const padded = try ansi.padRightVisibleAlloc(allocator, builder.items, width);
        builder.deinit(allocator);
        return padded;
    }

    const active_theme = theme.?;
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    if (padding_x > 0) {
        const left_padding = try allocator.alloc(u8, padding_x);
        defer allocator.free(left_padding);
        @memset(left_padding, ' ');
        const themed_padding = try active_theme.applyAlloc(allocator, .editor, left_padding);
        defer allocator.free(themed_padding);
        try builder.appendSlice(allocator, themed_padding);
    }

    if (cursor_offset) |offset| {
        const clamped = @min(offset, line.len);
        if (clamped > 0) {
            const before_cursor = try active_theme.applyAlloc(allocator, .editor, line[0..clamped]);
            defer allocator.free(before_cursor);
            try builder.appendSlice(allocator, before_cursor);
        }
        if (clamped < line.len) {
            const cluster = ansi.nextDisplayCluster(line, clamped);
            const cursor_text = try active_theme.applyAlloc(allocator, .editor_cursor, line[clamped..cluster.end]);
            defer allocator.free(cursor_text);
            try builder.appendSlice(allocator, cursor_text);
            if (cluster.end < line.len) {
                const after_cursor = try active_theme.applyAlloc(allocator, .editor, line[cluster.end..]);
                defer allocator.free(after_cursor);
                try builder.appendSlice(allocator, after_cursor);
            }
        } else {
            const cursor_space = try active_theme.applyAlloc(allocator, .editor_cursor, " ");
            defer allocator.free(cursor_space);
            try builder.appendSlice(allocator, cursor_space);
        }
    } else {
        if (line.len > 0) {
            const themed_line = try active_theme.applyAlloc(allocator, .editor, line);
            defer allocator.free(themed_line);
            try builder.appendSlice(allocator, themed_line);
        }
    }

    const trailing_width = if (width > ansi.visibleWidth(builder.items)) width - ansi.visibleWidth(builder.items) else 0;
    if (trailing_width > 0) {
        const trailing = try allocator.alloc(u8, trailing_width);
        defer allocator.free(trailing);
        @memset(trailing, ' ');
        const themed_trailing = try active_theme.applyAlloc(allocator, .editor, trailing);
        defer allocator.free(themed_trailing);
        try builder.appendSlice(allocator, themed_trailing);
    }

    return builder.toOwnedSlice(allocator);
}

fn deleteRange(buffer: *std.ArrayList(u8), start: usize, end: usize) void {
    if (end <= start) return;

    const count = end - start;
    std.mem.copyForwards(u8, buffer.items[start .. buffer.items.len - count], buffer.items[end..]);
    buffer.items.len -= count;
}

const CharacterClass = enum {
    whitespace,
    punctuation,
    word,
};

fn classifySlice(slice: []const u8) CharacterClass {
    if (slice.len == 1 and isWhitespaceByte(slice[0])) return .whitespace;
    if (slice.len == 1 and isPunctuationByte(slice[0])) return .punctuation;
    return .word;
}

fn isWhitespaceByte(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

fn isPunctuationByte(byte: u8) bool {
    return std.mem.indexOfScalar(u8, "(){}[]<>.,;:'\"!?+-=*/\\|&%^$#@~`", byte) != null;
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

fn renderEditorWithCursor(editor: *const Editor, width: usize, height: usize) !vaxis.Screen {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = @intCast(@max(height, 1)),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    errdefer screen.deinit(std.testing.allocator);

    const window = draw_mod.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try editor.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
        .theme = editor.theme,
    });
    return screen;
}

test "editor accepts typed characters and renders content with a native cursor" {
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
        try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(key));
    }

    try std.testing.expectEqualStrings("hello", editor.text());
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 5 }, editor.cursorPosition());

    var screen = try renderEditorWithCursor(&editor, 8, 1);
    defer screen.deinit(std.testing.allocator);

    try std.testing.expect(screen.cursor_vis);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 5), screen.cursor.col);
    try std.testing.expectEqual(vaxis.Cell.CursorShape.beam_blink, screen.cursor_shape);

    var rendered = try test_helpers.renderToScreen(editor.drawComponent(), 8, 1);
    defer rendered.deinit(std.testing.allocator);
    try test_helpers.expectCell(&rendered, 0, 0, "h", .{});
    try test_helpers.expectCell(&rendered, 4, 0, "o", .{});
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

test "editor home end and ctrl line navigation move within the current line" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try std.testing.expectEqual(HandleResult.handled, try editor.handlePaste("alpha\nbeta"));
    try std.testing.expectEqual(CursorPosition{ .line = 1, .column = 4 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.home));
    try std.testing.expectEqual(CursorPosition{ .line = 1, .column = 0 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.{ .ctrl = 'e' }));
    try std.testing.expectEqual(CursorPosition{ .line = 1, .column = 4 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.left));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.left));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.{ .ctrl = 'a' }));
    try std.testing.expectEqual(CursorPosition{ .line = 1, .column = 0 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.end));
    try std.testing.expectEqual(CursorPosition{ .line = 1, .column = 4 }, editor.cursorPosition());
}

test "editor delete removes the character under the cursor" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try std.testing.expectEqual(HandleResult.handled, try editor.handlePaste("hello"));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.left));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.left));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.delete));

    try std.testing.expectEqualStrings("helo", editor.text());
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 3 }, editor.cursorPosition());
}

test "editor ctrl+k deletes to the end of the line" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try std.testing.expectEqual(HandleResult.handled, try editor.handlePaste("hello\nworld"));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.up));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.{ .ctrl = 'a' }));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.right));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.right));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.{ .ctrl = 'k' }));

    try std.testing.expectEqualStrings("he\nworld", editor.text());
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 2 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.{ .ctrl = 'k' }));
    try std.testing.expectEqualStrings("heworld", editor.text());
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 2 }, editor.cursorPosition());
}

test "editor ctrl left and ctrl right move by word boundaries" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try std.testing.expectEqual(HandleResult.handled, try editor.handlePaste("one two three"));
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 13 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.ctrl_left));
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 8 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.ctrl_left));
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 4 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.ctrl_left));
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 0 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.ctrl_right));
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 3 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.ctrl_right));
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 7 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.ctrl_right));
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 13 }, editor.cursorPosition());
}

test "editor page up and page down move across multiple lines" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try std.testing.expectEqual(
        HandleResult.handled,
        try editor.handlePaste("l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7"),
    );
    try std.testing.expectEqual(CursorPosition{ .line = 7, .column = 2 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.page_up));
    try std.testing.expectEqual(CursorPosition{ .line = 2, .column = 2 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.page_up));
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 2 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.page_down));
    try std.testing.expectEqual(CursorPosition{ .line = 5, .column = 2 }, editor.cursorPosition());
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

    var screen = try test_helpers.renderToScreen(editor.drawAutocompleteComponent(), 16, 4);
    defer screen.deinit(std.testing.allocator);

    const selected = screen.readCell(2, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("r", selected.char.grapheme);
    try std.testing.expect(selected.style.reverse);
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

test "editor reset clears text and autocomplete state" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();
    try editor.setAutocompleteItems(&[_]select_list.SelectItem{
        .{ .value = "read", .label = "read" },
        .{ .value = "reload", .label = "reload" },
    });

    _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice("r") });

    try std.testing.expect(editor.isShowingAutocomplete());
    try std.testing.expectEqualStrings("r", editor.text());

    editor.reset();

    try std.testing.expectEqualStrings("", editor.text());
    try std.testing.expectEqual(@as(usize, 0), editor.cursorIndex());
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 0 }, editor.cursorPosition());
    try std.testing.expect(!editor.isShowingAutocomplete());
    try std.testing.expect(editor.selectedAutocompleteItem() == null);
}

test "editor only shows slash-command autocomplete for slash prefixes" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();
    try editor.setAutocompleteItems(&[_]select_list.SelectItem{
        .{ .value = "/settings", .label = "/settings" },
        .{ .value = "/session", .label = "/session" },
        .{ .value = "session-notes", .label = "session-notes" },
    });

    _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice("/") });
    _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice("s") });
    _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice("e") });
    try std.testing.expect(editor.isShowingAutocomplete());
    try std.testing.expect(std.mem.startsWith(u8, editor.selectedAutocompleteItem().?.value, "/"));

    editor.reset();
    for ([_][]const u8{ "/", "n", "a", "m", "e", " ", "D", "e", "m", "o", " ", "s" }) |text| {
        _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice(text) });
    }
    try std.testing.expect(editor.isShowingAutocomplete());
    try std.testing.expectEqualStrings("session-notes", editor.selectedAutocompleteItem().?.value);
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

test "editor renders wrapped multi-line content, wide graphemes, and native cursor position" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try std.testing.expectEqual(HandleResult.handled, try editor.handlePaste("ab你好🙂\nxy"));
    try std.testing.expectEqual(CursorPosition{ .line = 1, .column = 2 }, editor.cursorPosition());

    var cursor_screen = try renderEditorWithCursor(&editor, 6, 3);
    defer cursor_screen.deinit(std.testing.allocator);

    try std.testing.expect(cursor_screen.cursor_vis);
    try std.testing.expectEqual(@as(u16, 2), cursor_screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), cursor_screen.cursor.col);

    var screen = try test_helpers.renderToScreen(editor.drawComponent(), 6, 3);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "a", .{});
    try test_helpers.expectCell(&screen, 2, 0, "你", .{});
    try test_helpers.expectCell(&screen, 4, 0, "好", .{});
    try test_helpers.expectCell(&screen, 0, 1, "🙂", .{});
    try test_helpers.expectCell(&screen, 0, 2, "x", .{});
    try test_helpers.expectCell(&screen, 1, 2, "y", .{});
}

test "editor cursor column uses display width for wide graphemes" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try std.testing.expectEqual(HandleResult.handled, try editor.handlePaste("你🙂a"));
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 5 }, editor.cursorPosition());

    var screen = try renderEditorWithCursor(&editor, 8, 1);
    defer screen.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 5), screen.cursor.col);
}

test "editor applies theme colors to content and autocomplete without ansi parsing assertions" {
    const allocator = std.testing.allocator;

    var theme = try resources_mod.Theme.initDefault(allocator);
    defer theme.deinit(allocator);

    var editor = Editor.init(allocator);
    defer editor.deinit();
    editor.setTheme(&theme);
    try editor.setAutocompleteItems(&[_]select_list.SelectItem{
        .{ .value = "apple", .label = "apple" },
        .{ .value = "apricot", .label = "apricot" },
    });

    _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice("a") });

    var editor_screen = try test_helpers.renderToScreenWithTheme(editor.drawComponent(), 12, 1, &theme);
    defer editor_screen.deinit(std.testing.allocator);
    try test_helpers.expectCell(&editor_screen, 0, 0, "a", style_mod.styleFor(&theme, .editor));

    var autocomplete_screen = try test_helpers.renderToScreenWithTheme(editor.drawAutocompleteComponent(), 12, 2, &theme);
    defer autocomplete_screen.deinit(std.testing.allocator);

    const selected = autocomplete_screen.readCell(2, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(selected.style.reverse);
    const description = autocomplete_screen.readCell(2, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(description.style.reverse == false);
}

test "editor accepts multi-byte grapheme via PrintableKey" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice("你好") });

    try std.testing.expectEqualStrings("你好", editor.text());
}
