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

pub const EditorAction = enum {
    cursor_up,
    cursor_down,
    cursor_left,
    cursor_right,
    cursor_word_left,
    cursor_word_right,
    cursor_line_start,
    cursor_line_end,
    jump_forward,
    jump_backward,
    page_up,
    page_down,
    delete_char_backward,
    delete_char_forward,
    delete_word_backward,
    delete_word_forward,
    delete_to_line_start,
    delete_to_line_end,
    yank,
    yank_pop,
    undo,
    input_new_line,
    input_tab,
    select_cancel,
    select_up,
    select_down,
    select_page_up,
    select_page_down,
    select_confirm,
};

const DEFAULT_PAGE_LINE_COUNT: usize = 5;
const HISTORY_LIMIT: usize = 100;

const LastAction = enum {
    none,
    kill,
    yank,
    type_word,
};

const JumpDirection = enum {
    forward,
    backward,
};

const UndoSnapshot = struct {
    text: []u8,
    cursor: usize,
};

const PasteEntry = struct {
    id: usize,
    marker: []u8,
    content: []u8,
};

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
    history: std.ArrayList([]u8) = .empty,
    history_index: ?usize = null,
    undo_stack: std.ArrayList(UndoSnapshot) = .empty,
    kill_ring: std.ArrayList([]u8) = .empty,
    pastes: std.ArrayList(PasteEntry) = .empty,
    paste_counter: usize = 0,
    last_action: LastAction = .none,
    jump_direction: ?JumpDirection = null,

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Editor) void {
        self.clearAutocomplete();
        self.freeAutocompleteCatalog();
        self.freeHistory();
        self.clearUndoStack();
        self.undo_stack.deinit(self.allocator);
        self.freeKillRing();
        self.clearPastes();
        self.pastes.deinit(self.allocator);
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

    pub fn expandedTextAlloc(self: *const Editor, allocator: std.mem.Allocator) ![]u8 {
        var expanded = std.ArrayList(u8).empty;
        errdefer expanded.deinit(allocator);

        var index: usize = 0;
        while (index < self.buffer.items.len) {
            if (self.pasteEntryAt(index)) |entry| {
                try expanded.appendSlice(allocator, entry.content);
                index += entry.marker.len;
            } else {
                try expanded.append(allocator, self.buffer.items[index]);
                index += 1;
            }
        }

        return try expanded.toOwnedSlice(allocator);
    }

    pub fn cursorPrecededBy(self: *const Editor, value: []const u8) bool {
        return self.cursor >= value.len and std.mem.eql(u8, self.buffer.items[self.cursor - value.len .. self.cursor], value);
    }

    pub fn cursorPosition(self: *const Editor) CursorPosition {
        const line_start = lineStart(self.buffer.items, self.cursor);
        return .{
            .line = lineNumber(self.buffer.items, self.cursor),
            .column = displayColumn(self.buffer.items, line_start, self.cursor),
        };
    }

    pub fn setText(self: *Editor, text_value: []const u8) !void {
        if (!std.mem.eql(u8, self.buffer.items, text_value)) {
            try self.pushUndoSnapshot();
        }
        try self.setTextInternal(text_value);
        self.history_index = null;
        self.last_action = .none;
        self.jump_direction = null;
        self.clearAutocomplete();
    }

    pub fn addToHistory(self: *Editor, text_value: []const u8) !void {
        const trimmed = std.mem.trim(u8, text_value, " \t\r\n");
        if (trimmed.len == 0) return;
        if (self.history.items.len > 0 and std.mem.eql(u8, self.history.items[0], trimmed)) return;

        const owned = try self.allocator.dupe(u8, trimmed);
        errdefer self.allocator.free(owned);
        try self.history.insert(self.allocator, 0, owned);
        if (self.history.items.len > HISTORY_LIMIT) {
            const removed = self.history.orderedRemove(self.history.items.len - 1);
            self.allocator.free(removed);
        }
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
                if (self.jump_direction) |direction| {
                    self.jumpToChar(printable.slice(), direction);
                    self.jump_direction = null;
                    self.last_action = .none;
                    try self.refreshAutocomplete(false);
                    return .handled;
                }
                try self.insertTypedSlice(printable.slice());
                try self.refreshAutocomplete(false);
                return .handled;
            },
            .tab => {
                return self.handleAction(.input_tab);
            },
            .enter => {
                return self.handleAction(.input_new_line);
            },
            .backspace => {
                return self.handleAction(.delete_char_backward);
            },
            .left => {
                return self.handleAction(.cursor_left);
            },
            .right => {
                return self.handleAction(.cursor_right);
            },
            .ctrl_left => {
                return self.handleAction(.cursor_word_left);
            },
            .ctrl_right => {
                return self.handleAction(.cursor_word_right);
            },
            .up => {
                return self.handleAction(.cursor_up);
            },
            .down => {
                return self.handleAction(.cursor_down);
            },
            .home => {
                return self.handleAction(.cursor_line_start);
            },
            .end => {
                return self.handleAction(.cursor_line_end);
            },
            .delete => {
                return self.handleAction(.delete_char_forward);
            },
            .page_up => {
                return self.handleAction(.page_up);
            },
            .page_down => {
                return self.handleAction(.page_down);
            },
            .ctrl => |ctrl| switch (ctrl) {
                'a' => {
                    return self.handleAction(.cursor_line_start);
                },
                'c' => return .interrupt,
                'd' => return .exit,
                'e' => {
                    return self.handleAction(.cursor_line_end);
                },
                ']' => {
                    return self.handleAction(.jump_forward);
                },
                'k' => {
                    return self.handleAction(.delete_to_line_end);
                },
                else => return .ignored,
            },
            .escape => {
                if (self.jump_direction != null) {
                    self.jump_direction = null;
                    return .handled;
                }
                return .ignored;
            },
            else => return .ignored,
        }
    }

    pub fn handleAction(self: *Editor, action: EditorAction) !HandleResult {
        if (self.autocomplete_list) |*list| {
            switch (action) {
                .select_cancel => {
                    self.clearAutocomplete();
                    return .handled;
                },
                .cursor_up, .select_up => {
                    _ = list.handleKey(.up);
                    return .handled;
                },
                .cursor_down, .select_down => {
                    _ = list.handleKey(.down);
                    return .handled;
                },
                .page_up, .select_page_up => {
                    _ = list.handleKey(.page_up);
                    return .handled;
                },
                .page_down, .select_page_down => {
                    _ = list.handleKey(.page_down);
                    return .handled;
                },
                .input_tab, .select_confirm => {
                    try self.applySelectedAutocomplete();
                    return .handled;
                },
                else => {},
            }
        }

        switch (action) {
            .cursor_up => {
                if (self.isEditorEmpty()) {
                    try self.navigateHistory(.older);
                } else if (self.history_index != null and self.isOnFirstLogicalLine()) {
                    try self.navigateHistory(.older);
                } else if (self.isOnFirstLogicalLine()) {
                    self.moveToLineStart();
                } else {
                    self.moveVertical(-1);
                }
                try self.refreshAutocomplete(false);
                return .handled;
            },
            .cursor_down => {
                if (self.history_index != null and self.isOnLastLogicalLine()) {
                    try self.navigateHistory(.newer);
                } else if (self.isOnLastLogicalLine()) {
                    self.moveToLineEnd();
                } else {
                    self.moveVertical(1);
                }
                try self.refreshAutocomplete(false);
                return .handled;
            },
            .cursor_left => self.moveLeft(),
            .cursor_right => self.moveRight(),
            .cursor_word_left => self.moveWordBackwards(),
            .cursor_word_right => self.moveWordForwards(),
            .cursor_line_start => self.moveToLineStart(),
            .cursor_line_end => self.moveToLineEnd(),
            .jump_forward => self.beginJump(.forward),
            .jump_backward => self.beginJump(.backward),
            .page_up => self.movePage(-1),
            .page_down => self.movePage(1),
            .delete_char_backward => try self.backspace(),
            .delete_char_forward => try self.deleteForward(),
            .delete_word_backward => try self.deleteWordBackward(),
            .delete_word_forward => try self.deleteWordForward(),
            .delete_to_line_start => try self.deleteToLineStart(),
            .delete_to_line_end => try self.deleteToLineEnd(),
            .input_new_line => {
                try self.pushUndoSnapshot();
                self.last_action = .none;
                self.jump_direction = null;
                try self.insertSlice("\n");
                self.clearAutocomplete();
                return .handled;
            },
            .input_tab => {
                try self.refreshAutocomplete(true);
                return .handled;
            },
            .select_cancel, .select_up, .select_down, .select_page_up, .select_page_down, .select_confirm => return .ignored,
            .undo => self.undo(),
            .yank => try self.yank(),
            .yank_pop => try self.yankPop(),
        }

        try self.refreshAutocomplete(false);
        return .handled;
    }

    pub fn handlePaste(self: *Editor, pasted: []const u8) !HandleResult {
        try self.pushUndoSnapshot();
        self.last_action = .none;
        self.jump_direction = null;
        const filtered = try normalizePaste(self.allocator, pasted);
        defer self.allocator.free(filtered);
        if (filtered.len == 0) {
            self.clearAutocomplete();
            return .handled;
        }

        const needs_leading_space = startsWithPathPrefix(filtered) and self.cursor > 0 and isWordByte(self.buffer.items[self.cursor - 1]);
        const line_count = countLines(filtered);
        const total_chars = filtered.len + if (needs_leading_space) @as(usize, 1) else @as(usize, 0);
        const is_large = line_count > 10 or total_chars > 1000;

        var paste_text = std.ArrayList(u8).empty;
        defer paste_text.deinit(self.allocator);
        if (needs_leading_space) try paste_text.append(self.allocator, ' ');
        try paste_text.appendSlice(self.allocator, filtered);

        if (is_large) {
            self.paste_counter += 1;
            const marker = if (line_count > 10)
                try std.fmt.allocPrint(self.allocator, "[paste #{d} +{d} lines]", .{ self.paste_counter, line_count })
            else
                try std.fmt.allocPrint(self.allocator, "[paste #{d} {d} chars]", .{ self.paste_counter, total_chars });
            errdefer self.allocator.free(marker);
            const content = try paste_text.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(content);
            try self.pastes.append(self.allocator, .{
                .id = self.paste_counter,
                .marker = marker,
                .content = content,
            });
            try self.insertSlice(marker);
        } else {
            try self.insertSlice(paste_text.items);
        }
        self.clearAutocomplete();
        return .handled;
    }

    pub fn reset(self: *Editor) void {
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
        self.history_index = null;
        self.clearUndoStack();
        self.last_action = .none;
        self.jump_direction = null;
        self.clearAutocomplete();
        self.clearPastes();
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

        if (content_window.height == 1) {
            const cursor_col = drawSingleRowViewport(self.buffer.items, self.cursor, content_window, base_style);
            content_window.showCursor(cursor_col, 0);
            content_window.setCursorShape(self.cursor_shape);
            return .{
                .width = window.width,
                .height = @min(window.height, @as(u16, @intCast(self.padding_y * 2 + 1))),
            };
        }

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
        self.history_index = null;
        try self.buffer.ensureUnusedCapacity(self.allocator, slice.len);

        const old_len = self.buffer.items.len;
        self.buffer.items.len = old_len + slice.len;
        std.mem.copyBackwards(u8, self.buffer.items[self.cursor + slice.len ..], self.buffer.items[self.cursor..old_len]);
        @memcpy(self.buffer.items[self.cursor .. self.cursor + slice.len], slice);
        self.cursor += slice.len;
    }

    fn insertTypedSlice(self: *Editor, slice: []const u8) !void {
        self.history_index = null;
        self.jump_direction = null;
        if (slice.len == 0) return;
        if (isWhitespaceSlice(slice) or self.last_action != .type_word) {
            try self.pushUndoSnapshot();
        }
        self.last_action = .type_word;
        try self.insertSlice(slice);
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
        try self.pushUndoSnapshot();
        self.last_action = .none;
        self.jump_direction = null;
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
        self.history_index = null;
    }

    fn backspace(self: *Editor) !void {
        if (self.cursor == 0) return;

        try self.pushUndoSnapshot();
        self.last_action = .none;
        self.jump_direction = null;
        if (self.pasteMarkerStartBeforeCursor()) |marker_start| {
            deleteRange(&self.buffer, marker_start, self.cursor);
            self.cursor = marker_start;
            self.history_index = null;
            return;
        }
        const start = prevGraphemeStart(self.buffer.items, self.cursor);
        deleteRange(&self.buffer, start, self.cursor);
        self.cursor = start;
        self.history_index = null;
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

    fn freeHistory(self: *Editor) void {
        for (self.history.items) |entry| {
            self.allocator.free(entry);
        }
        self.history.clearRetainingCapacity();
        self.history.deinit(self.allocator);
        self.history = .empty;
    }

    fn clearUndoStack(self: *Editor) void {
        for (self.undo_stack.items) |snapshot| {
            self.allocator.free(snapshot.text);
        }
        self.undo_stack.clearRetainingCapacity();
    }

    fn pushUndoSnapshot(self: *Editor) !void {
        const owned = try self.allocator.dupe(u8, self.buffer.items);
        errdefer self.allocator.free(owned);
        try self.undo_stack.append(self.allocator, .{
            .text = owned,
            .cursor = self.cursor,
        });
    }

    fn undo(self: *Editor) void {
        const snapshot = self.undo_stack.pop() orelse return;
        defer self.allocator.free(snapshot.text);

        self.buffer.clearRetainingCapacity();
        self.buffer.appendSlice(self.allocator, snapshot.text) catch {
            return;
        };
        self.cursor = @min(snapshot.cursor, self.buffer.items.len);
        self.history_index = null;
        self.last_action = .none;
        self.jump_direction = null;
        self.clearAutocomplete();
    }

    fn freeKillRing(self: *Editor) void {
        for (self.kill_ring.items) |entry| {
            self.allocator.free(entry);
        }
        self.kill_ring.clearRetainingCapacity();
        self.kill_ring.deinit(self.allocator);
        self.kill_ring = .empty;
    }

    fn clearPastes(self: *Editor) void {
        for (self.pastes.items) |*entry| {
            self.allocator.free(entry.marker);
            self.allocator.free(entry.content);
        }
        self.pastes.clearRetainingCapacity();
        self.paste_counter = 0;
    }

    fn pasteEntryAt(self: *const Editor, index: usize) ?PasteEntry {
        for (self.pastes.items) |entry| {
            if (index + entry.marker.len <= self.buffer.items.len and
                std.mem.eql(u8, self.buffer.items[index .. index + entry.marker.len], entry.marker))
            {
                return entry;
            }
        }
        return null;
    }

    fn pasteMarkerStartBeforeCursor(self: *const Editor) ?usize {
        for (self.pastes.items) |entry| {
            if (self.cursor < entry.marker.len) continue;
            const start = self.cursor - entry.marker.len;
            if (std.mem.eql(u8, self.buffer.items[start..self.cursor], entry.marker)) return start;
        }
        return null;
    }

    fn pushKill(self: *Editor, text_value: []const u8, prepend: bool, accumulate: bool) !void {
        if (text_value.len == 0) return;

        if (accumulate and self.kill_ring.items.len > 0) {
            const last_index = self.kill_ring.items.len - 1;
            const last = self.kill_ring.items[last_index];
            const combined_len = text_value.len + last.len;
            const combined = try self.allocator.alloc(u8, combined_len);
            errdefer self.allocator.free(combined);
            if (prepend) {
                @memcpy(combined[0..text_value.len], text_value);
                @memcpy(combined[text_value.len..], last);
            } else {
                @memcpy(combined[0..last.len], last);
                @memcpy(combined[last.len..], text_value);
            }
            self.allocator.free(last);
            self.kill_ring.items[last_index] = combined;
            return;
        }

        const owned = try self.allocator.dupe(u8, text_value);
        errdefer self.allocator.free(owned);
        try self.kill_ring.append(self.allocator, owned);
    }

    fn peekKill(self: *const Editor) ?[]const u8 {
        if (self.kill_ring.items.len == 0) return null;
        return self.kill_ring.items[self.kill_ring.items.len - 1];
    }

    fn rotateKillRing(self: *Editor) !void {
        if (self.kill_ring.items.len <= 1) return;
        const last = self.kill_ring.pop().?;
        errdefer self.kill_ring.append(self.allocator, last) catch {};
        try self.kill_ring.insert(self.allocator, 0, last);
    }

    fn setTextInternal(self: *Editor, text_value: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.allocator, text_value);
        self.cursor = self.buffer.items.len;
    }

    fn isEditorEmpty(self: *const Editor) bool {
        return self.buffer.items.len == 0;
    }

    fn isOnFirstLogicalLine(self: *const Editor) bool {
        return lineStart(self.buffer.items, self.cursor) == 0;
    }

    fn isOnLastLogicalLine(self: *const Editor) bool {
        return lineEnd(self.buffer.items, self.cursor) == self.buffer.items.len;
    }

    const HistoryDirection = enum { older, newer };

    fn navigateHistory(self: *Editor, direction: HistoryDirection) !void {
        self.last_action = .none;
        self.jump_direction = null;
        if (self.history.items.len == 0) return;

        const next_index: ?usize = switch (direction) {
            .older => if (self.history_index) |index|
                if (index + 1 >= self.history.items.len) return else index + 1
            else
                0,
            .newer => if (self.history_index) |index|
                if (index == 0) null else index - 1
            else
                return,
        };

        self.history_index = next_index;
        if (next_index) |index| {
            try self.setTextInternal(self.history.items[index]);
        } else {
            try self.setTextInternal("");
        }
        self.clearAutocomplete();
    }

    fn moveLeft(self: *Editor) void {
        self.last_action = .none;
        self.jump_direction = null;
        self.cursor = prevGraphemeStart(self.buffer.items, self.cursor);
    }

    fn moveRight(self: *Editor) void {
        self.last_action = .none;
        self.jump_direction = null;
        self.cursor = nextGraphemeEnd(self.buffer.items, self.cursor);
    }

    fn moveToLineStart(self: *Editor) void {
        self.last_action = .none;
        self.jump_direction = null;
        self.cursor = lineStart(self.buffer.items, self.cursor);
    }

    fn moveToLineEnd(self: *Editor) void {
        self.last_action = .none;
        self.jump_direction = null;
        self.cursor = lineEnd(self.buffer.items, self.cursor);
    }

    fn deleteForward(self: *Editor) !void {
        if (self.cursor >= self.buffer.items.len) return;

        try self.pushUndoSnapshot();
        self.last_action = .none;
        self.jump_direction = null;
        if (self.pasteEntryAt(self.cursor)) |entry| {
            deleteRange(&self.buffer, self.cursor, self.cursor + entry.marker.len);
            self.history_index = null;
            return;
        }
        const end = nextGraphemeEnd(self.buffer.items, self.cursor);
        deleteRange(&self.buffer, self.cursor, end);
        self.history_index = null;
    }

    fn deleteToLineStart(self: *Editor) !void {
        const current_start = lineStart(self.buffer.items, self.cursor);
        if (self.cursor > current_start) {
            try self.pushUndoSnapshot();
            const deleted = self.buffer.items[current_start..self.cursor];
            try self.pushKill(deleted, true, self.last_action == .kill);
            deleteRange(&self.buffer, current_start, self.cursor);
            self.cursor = current_start;
            self.history_index = null;
            self.last_action = .kill;
            self.jump_direction = null;
            return;
        }

        if (current_start > 0) {
            try self.pushUndoSnapshot();
            try self.pushKill("\n", true, self.last_action == .kill);
            deleteRange(&self.buffer, current_start - 1, current_start);
            self.cursor = current_start - 1;
            self.history_index = null;
            self.last_action = .kill;
            self.jump_direction = null;
        }
    }

    fn deleteToLineEnd(self: *Editor) !void {
        const content = self.buffer.items;
        const current_end = lineEnd(content, self.cursor);

        if (self.cursor < current_end) {
            try self.pushUndoSnapshot();
            const deleted = self.buffer.items[self.cursor..current_end];
            try self.pushKill(deleted, false, self.last_action == .kill);
            deleteRange(&self.buffer, self.cursor, current_end);
            self.history_index = null;
            self.last_action = .kill;
            self.jump_direction = null;
            return;
        }

        if (current_end < content.len) {
            try self.pushUndoSnapshot();
            try self.pushKill("\n", false, self.last_action == .kill);
            deleteRange(&self.buffer, current_end, current_end + 1);
            self.history_index = null;
            self.last_action = .kill;
            self.jump_direction = null;
        }
    }

    fn deleteWordBackward(self: *Editor) !void {
        const end = self.cursor;
        const was_kill = self.last_action == .kill;
        self.moveWordBackwards();
        const start = self.cursor;
        if (start == end) return;
        self.cursor = end;
        try self.pushUndoSnapshot();
        const deleted = self.buffer.items[start..end];
        try self.pushKill(deleted, true, was_kill);
        deleteRange(&self.buffer, start, end);
        self.cursor = start;
        self.history_index = null;
        self.last_action = .kill;
        self.jump_direction = null;
    }

    fn deleteWordForward(self: *Editor) !void {
        const start = self.cursor;
        const was_kill = self.last_action == .kill;
        self.moveWordForwards();
        const end = self.cursor;
        if (start == end) return;
        self.cursor = start;
        try self.pushUndoSnapshot();
        const deleted = self.buffer.items[start..end];
        try self.pushKill(deleted, false, was_kill);
        deleteRange(&self.buffer, start, end);
        self.cursor = start;
        self.history_index = null;
        self.last_action = .kill;
        self.jump_direction = null;
    }

    fn yank(self: *Editor) !void {
        const text_value = self.peekKill() orelse return;

        try self.pushUndoSnapshot();
        self.last_action = .none;
        self.jump_direction = null;
        try self.insertSlice(text_value);
        self.last_action = .yank;
    }

    fn yankPop(self: *Editor) !void {
        if (self.last_action != .yank or self.kill_ring.items.len <= 1) return;
        const previous = self.peekKill() orelse return;
        if (previous.len > self.cursor) return;

        try self.pushUndoSnapshot();
        const start = self.cursor - previous.len;
        deleteRange(&self.buffer, start, self.cursor);
        self.cursor = start;
        try self.rotateKillRing();
        const next = self.peekKill() orelse return;
        try self.insertSlice(next);
        self.last_action = .yank;
        self.jump_direction = null;
        self.history_index = null;
    }

    fn beginJump(self: *Editor, direction: JumpDirection) void {
        if (self.jump_direction) |current| {
            if (current == direction) {
                self.jump_direction = null;
                return;
            }
        }
        self.jump_direction = direction;
        self.last_action = .none;
    }

    fn jumpToChar(self: *Editor, needle: []const u8, direction: JumpDirection) void {
        if (needle.len == 0) return;

        switch (direction) {
            .forward => {
                const search_start = nextGraphemeEnd(self.buffer.items, self.cursor);
                const index = std.mem.indexOfPos(u8, self.buffer.items, search_start, needle) orelse return;
                self.cursor = index;
            },
            .backward => {
                if (self.cursor == 0) return;
                const end = prevGraphemeStart(self.buffer.items, self.cursor);
                const index = std.mem.lastIndexOf(u8, self.buffer.items[0..end], needle) orelse return;
                self.cursor = index;
            },
        }
    }

    fn moveVertical(self: *Editor, direction: i2) void {
        self.last_action = .none;
        self.jump_direction = null;
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
        self.last_action = .none;
        self.jump_direction = null;
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
        self.last_action = .none;
        self.jump_direction = null;
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
            const previous = prevGraphemeStart(content, cursor);
            if (classifySlice(content[previous..cursor]) != .whitespace) break;
            cursor = previous;
        }

        if (cursor == current_start) {
            self.cursor = current_start;
            return;
        }

        var previous = prevGraphemeStart(content, cursor);
        const target_class = classifySlice(content[previous..cursor]);
        cursor = previous;

        while (cursor > current_start) {
            previous = prevGraphemeStart(content, cursor);
            if (classifySlice(content[previous..cursor]) != target_class) break;
            cursor = previous;
        }

        self.cursor = cursor;
    }

    fn moveWordForwards(self: *Editor) void {
        self.last_action = .none;
        self.jump_direction = null;
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
            const next = nextGraphemeEnd(content, cursor);
            if (classifySlice(content[cursor..next]) != .whitespace) break;
            cursor = next;
        }

        if (cursor >= current_end) {
            self.cursor = current_end;
            return;
        }

        const target_class = classifySlice(content[cursor..nextGraphemeEnd(content, cursor)]);
        while (cursor < current_end) {
            const next = nextGraphemeEnd(content, cursor);
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

fn drawSingleRowViewport(text: []const u8, cursor_index: usize, window: vaxis.Window, style: vaxis.Cell.Style) u16 {
    if (text.len == 0 or window.width == 0) return 0;

    const clamped_cursor = @min(cursor_index, text.len);
    const current_start = lineStart(text, clamped_cursor);
    const current_end = lineEnd(text, clamped_cursor);
    const max_left_width = if (window.width > 1) @as(usize, window.width - 1) else 0;

    var start = clamped_cursor;
    var used_width: usize = 0;
    while (start > current_start) {
        const previous = prevCodepointStart(text, start);
        const cluster = ansi.nextDisplayCluster(text, previous);
        if (used_width + cluster.width > max_left_width) break;
        used_width += cluster.width;
        start = previous;
    }

    _ = window.printSegment(.{
        .text = text[start..current_end],
        .style = style,
    }, .{ .wrap = .none });

    return @intCast(@min(displayColumn(text, start, clamped_cursor), @as(usize, window.width - 1)));
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

fn isWhitespaceSlice(slice: []const u8) bool {
    return slice.len == 1 and isWhitespaceByte(slice[0]);
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

fn prevGraphemeStart(text: []const u8, index: usize) usize {
    const clamped = @min(index, text.len);
    if (clamped == 0) return 0;

    var cursor: usize = 0;
    var previous: usize = 0;
    while (cursor < clamped) {
        previous = cursor;
        const next = nextGraphemeEnd(text, cursor);
        if (next >= clamped or next <= cursor) return previous;
        cursor = next;
    }
    return previous;
}

fn nextGraphemeEnd(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    return ansi.nextDisplayCluster(text, index).end;
}

fn normalizePaste(allocator: std.mem.Allocator, pasted: []const u8) ![]u8 {
    var decoded = std.ArrayList(u8).empty;
    defer decoded.deinit(allocator);

    var index: usize = 0;
    while (index < pasted.len) {
        if (std.mem.startsWith(u8, pasted[index..], "\x1b[")) {
            var cursor = index + 2;
            var codepoint: usize = 0;
            var saw_digit = false;
            while (cursor < pasted.len and std.ascii.isDigit(pasted[cursor])) : (cursor += 1) {
                saw_digit = true;
                codepoint = codepoint * 10 + (pasted[cursor] - '0');
            }
            if (saw_digit and std.mem.startsWith(u8, pasted[cursor..], ";5u")) {
                if (codepoint >= 'a' and codepoint <= 'z') {
                    try decoded.append(allocator, @intCast(codepoint - 96));
                    index = cursor + 3;
                    continue;
                }
                if (codepoint >= 'A' and codepoint <= 'Z') {
                    try decoded.append(allocator, @intCast(codepoint - 64));
                    index = cursor + 3;
                    continue;
                }
            }
        }

        try decoded.append(allocator, pasted[index]);
        index += 1;
    }

    var normalized = std.ArrayList(u8).empty;
    errdefer normalized.deinit(allocator);
    index = 0;
    while (index < decoded.items.len) {
        const byte = decoded.items[index];
        if (byte == '\r') {
            try normalized.append(allocator, '\n');
            if (index + 1 < decoded.items.len and decoded.items[index + 1] == '\n') index += 1;
        } else if (byte == '\t') {
            try normalized.appendSlice(allocator, "    ");
        } else if (byte == '\n' or byte >= 32) {
            try normalized.append(allocator, byte);
        }
        index += 1;
    }

    return try normalized.toOwnedSlice(allocator);
}

fn countLines(text: []const u8) usize {
    var count: usize = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn startsWithPathPrefix(text: []const u8) bool {
    if (text.len == 0) return false;
    return text[0] == '/' or text[0] == '~' or text[0] == '.';
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
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

test "editor undo coalesces word typing and restores cursor for atomic edits" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    for ([_][]const u8{ "h", "e", "l", "l", "o", " ", "w", "o", "r", "l", "d" }) |slice| {
        try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.{
            .printable = keys.PrintableKey.fromSlice(slice),
        }));
    }
    try std.testing.expectEqualStrings("hello world", editor.text());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.undo));
    try std.testing.expectEqualStrings("hello", editor.text());
    try std.testing.expectEqual(@as(usize, 5), editor.cursorIndex());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.undo));
    try std.testing.expectEqualStrings("", editor.text());
    try std.testing.expectEqual(@as(usize, 0), editor.cursorIndex());

    try std.testing.expectEqual(HandleResult.handled, try editor.handlePaste("alpha\nbeta"));
    try std.testing.expectEqualStrings("alpha\nbeta", editor.text());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.undo));
    try std.testing.expectEqualStrings("", editor.text());
    try std.testing.expectEqual(@as(usize, 0), editor.cursorIndex());
}

test "editor undo treats spaces and newlines as separate atomic groups" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    for ([_][]const u8{ "h", "i", " ", " " }) |slice| {
        _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice(slice) });
    }
    try std.testing.expectEqualStrings("hi  ", editor.text());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.undo));
    try std.testing.expectEqualStrings("hi ", editor.text());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.undo));
    try std.testing.expectEqualStrings("hi", editor.text());

    editor.reset();
    for ([_][]const u8{ "h", "i" }) |slice| {
        _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice(slice) });
    }
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.input_new_line));
    for ([_][]const u8{ "y", "o" }) |slice| {
        _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice(slice) });
    }
    try std.testing.expectEqualStrings("hi\nyo", editor.text());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.undo));
    try std.testing.expectEqualStrings("hi\n", editor.text());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.undo));
    try std.testing.expectEqualStrings("hi", editor.text());
}

test "editor kill ring accumulates kills and yanks latest entry" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try editor.setText("one two three");
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.delete_word_backward));
    try std.testing.expectEqualStrings("one two ", editor.text());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.delete_word_backward));
    try std.testing.expectEqualStrings("one ", editor.text());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.delete_word_backward));
    try std.testing.expectEqualStrings("", editor.text());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.yank));
    try std.testing.expectEqualStrings("one two three", editor.text());
}

test "editor yank pop rotates only immediately after yank" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try editor.setText("FIRST");
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.delete_word_backward));
    try editor.setText("SECOND");
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.delete_word_backward));
    try editor.setText("hello world");
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_line_start));
    for (0..6) |_| {
        try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_right));
    }

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.yank));
    try std.testing.expectEqualStrings("hello SECONDworld", editor.text());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.yank_pop));
    try std.testing.expectEqualStrings("hello FIRSTworld", editor.text());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.{
        .printable = keys.PrintableKey.fromSlice("!"),
    }));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.yank_pop));
    try std.testing.expectEqualStrings("hello FIRST!world", editor.text());
}

test "editor navigation and deletion do not split grapheme clusters" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try std.testing.expectEqual(HandleResult.handled, try editor.handlePaste("a👍🏽éb"));
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 5 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_left));
    try std.testing.expectEqual(@as(usize, "a👍🏽é".len), editor.cursorIndex());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.delete_char_backward));
    try std.testing.expectEqualStrings("a👍🏽b", editor.text());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.delete_char_backward));
    try std.testing.expectEqualStrings("ab", editor.text());
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 1 }, editor.cursorPosition());
}

test "editor character jump searches forward and backward without inserting target" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try editor.setText("hello\nworld");
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_up));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_line_start));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.jump_forward));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.{
        .printable = keys.PrintableKey.fromSlice("o"),
    }));
    try std.testing.expectEqual(@as(usize, 4), editor.cursorIndex());
    try std.testing.expectEqualStrings("hello\nworld", editor.text());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.jump_forward));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.{
        .printable = keys.PrintableKey.fromSlice("w"),
    }));
    try std.testing.expectEqual(CursorPosition{ .line = 1, .column = 0 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.jump_backward));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.{
        .printable = keys.PrintableKey.fromSlice("h"),
    }));
    try std.testing.expectEqual(@as(usize, 0), editor.cursorIndex());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.jump_forward));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.jump_forward));
    try std.testing.expectEqual(HandleResult.handled, try editor.handleKey(.{
        .printable = keys.PrintableKey.fromSlice("x"),
    }));
    try std.testing.expectEqualStrings("xhello\nworld", editor.text());
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

test "editor single-row viewport scrolls to keep overflowing cursor visible" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try std.testing.expectEqual(HandleResult.handled, try editor.handlePaste("abcdefghi"));

    var cursor_screen = try renderEditorWithCursor(&editor, 6, 1);
    defer cursor_screen.deinit(std.testing.allocator);

    try std.testing.expect(cursor_screen.cursor_vis);
    try std.testing.expectEqual(@as(u16, 5), cursor_screen.cursor.col);

    var screen = try test_helpers.renderToScreen(editor.drawComponent(), 6, 1);
    defer screen.deinit(std.testing.allocator);
    try test_helpers.expectCell(&screen, 0, 0, "e", .{});
    try test_helpers.expectCell(&screen, 4, 0, "i", .{});
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

test "editor backspace deletes a full Chinese character" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice("你好") });
    _ = try editor.handleKey(.backspace);

    try std.testing.expectEqualStrings("你", editor.text());
    try std.testing.expectEqual(@as(usize, "你".len), editor.cursorIndex());
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 2 }, editor.cursorPosition());
}

test "editor prompt history skips empty and consecutive duplicates with one hundred entry cap" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try editor.addToHistory("");
    try editor.addToHistory("   ");
    try editor.addToHistory("same");
    try editor.addToHistory("same");
    try editor.addToHistory("other");
    try editor.addToHistory("same");

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_up));
    try std.testing.expectEqualStrings("same", editor.text());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_up));
    try std.testing.expectEqualStrings("other", editor.text());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_up));
    try std.testing.expectEqualStrings("same", editor.text());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_up));
    try std.testing.expectEqualStrings("same", editor.text());

    editor.reset();
    for (0..105) |index| {
        const entry = try std.fmt.allocPrint(allocator, "prompt {d}", .{index});
        defer allocator.free(entry);
        try editor.addToHistory(entry);
    }
    for (0..100) |_| {
        try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_up));
    }
    try std.testing.expectEqualStrings("prompt 5", editor.text());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_up));
    try std.testing.expectEqualStrings("prompt 5", editor.text());
}

test "editor prompt history traverses newest to empty and typing exits browse mode" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try editor.addToHistory("first");
    try editor.addToHistory("second");
    try editor.addToHistory("third");

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_up));
    try std.testing.expectEqualStrings("third", editor.text());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_up));
    try std.testing.expectEqualStrings("second", editor.text());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_down));
    try std.testing.expectEqualStrings("third", editor.text());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_down));
    try std.testing.expectEqualStrings("", editor.text());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_up));
    try std.testing.expectEqualStrings("third", editor.text());
    _ = try editor.handleKey(.{ .printable = keys.PrintableKey.fromSlice("!") });
    try std.testing.expectEqualStrings("third!", editor.text());
    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_down));
    try std.testing.expectEqualStrings("third!", editor.text());
}

test "editor prompt history lets multiline cursor navigation take precedence" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    try editor.addToHistory("older");
    try editor.addToHistory("line1\nline2\nline3");

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_up));
    try std.testing.expectEqualStrings("line1\nline2\nline3", editor.text());
    try std.testing.expectEqual(CursorPosition{ .line = 2, .column = 5 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_up));
    try std.testing.expectEqualStrings("line1\nline2\nline3", editor.text());
    try std.testing.expectEqual(CursorPosition{ .line = 1, .column = 5 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_up));
    try std.testing.expectEqualStrings("line1\nline2\nline3", editor.text());
    try std.testing.expectEqual(CursorPosition{ .line = 0, .column = 5 }, editor.cursorPosition());

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.cursor_up));
    try std.testing.expectEqualStrings("older", editor.text());
}

test "editor paste normalizes text and expands large markers atomically" {
    const allocator = std.testing.allocator;

    var editor = Editor.init(allocator);
    defer editor.deinit();

    _ = try editor.handlePaste("hello");
    _ = try editor.handlePaste("/tmp/file\r\nnext\tline\x01");
    try std.testing.expectEqualStrings("hello /tmp/file\nnext    line", editor.text());

    editor.reset();
    _ = try editor.handlePaste("one\r\ntwo\rthree\tfour\x02!");
    try std.testing.expectEqualStrings("one\ntwo\nthree    four!", editor.text());

    editor.reset();
    var large = std.ArrayList(u8).empty;
    defer large.deinit(allocator);
    for (0..11) |index| {
        if (index > 0) try large.append(allocator, '\n');
        const line = try std.fmt.allocPrint(allocator, "line {d}", .{index});
        defer allocator.free(line);
        try large.appendSlice(allocator, line);
    }
    _ = try editor.handlePaste(large.items);
    try std.testing.expectEqualStrings("[paste #1 +11 lines]", editor.text());

    const expanded = try editor.expandedTextAlloc(allocator);
    defer allocator.free(expanded);
    try std.testing.expectEqualStrings(large.items, expanded);

    try std.testing.expectEqual(HandleResult.handled, try editor.handleAction(.delete_char_backward));
    try std.testing.expectEqualStrings("", editor.text());

    _ = try editor.handlePaste(large.items);
    editor.reset();
    const reset_expanded = try editor.expandedTextAlloc(allocator);
    defer allocator.free(reset_expanded);
    try std.testing.expectEqualStrings("", reset_expanded);
}
