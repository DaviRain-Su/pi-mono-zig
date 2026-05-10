const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const keys = @import("../keys.zig");
const test_helpers = @import("../test_helpers.zig");

pub const SelectItem = struct {
    value: []const u8,
    label: []const u8 = "",
    description: ?[]const u8 = null,

    pub fn display(self: SelectItem) []const u8 {
        return if (self.label.len > 0) self.label else self.value;
    }
};

pub const HandleResult = union(enum) {
    handled,
    confirmed: usize,
    dismissed,
    ignored,
};

pub const SelectList = struct {
    items: []const SelectItem,
    selected_index: usize = 0,
    max_visible: usize = 5,
    padding_x: usize = 0,
    padding_y: usize = 0,
    selected_style: vaxis.Cell.Style = .{},
    description_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },
    empty_style: vaxis.Cell.Style = .{ .dim = true },
    scroll_style: vaxis.Cell.Style = .{ .dim = true },
    show_scrollbar: bool = false,
    scrollbar_thumb: []const u8 = "█",
    scrollbar_track: []const u8 = "│",
    highlight_symbol: []const u8 = "→ ",
    unselected_symbol: []const u8 = "  ",

    pub fn drawComponent(self: *const SelectList) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn selectedIndex(self: *const SelectList) usize {
        if (self.items.len == 0) return 0;
        return @min(self.selected_index, self.items.len - 1);
    }

    pub fn selectedItem(self: *const SelectList) ?SelectItem {
        if (self.items.len == 0) return null;
        return self.items[self.selectedIndex()];
    }

    pub fn setSelectedIndex(self: *SelectList, index: usize) void {
        if (self.items.len == 0) {
            self.selected_index = 0;
            return;
        }
        self.selected_index = @min(index, self.items.len - 1);
    }

    pub fn handleKey(self: *SelectList, key: keys.Key) HandleResult {
        switch (key) {
            .up => {
                if (self.items.len == 0) return .ignored;
                self.selected_index = if (self.selectedIndex() == 0) self.items.len - 1 else self.selectedIndex() - 1;
                return .handled;
            },
            .down => {
                if (self.items.len == 0) return .ignored;
                self.selected_index = if (self.selectedIndex() + 1 >= self.items.len) 0 else self.selectedIndex() + 1;
                return .handled;
            },
            .enter => {
                if (self.items.len == 0) return .ignored;
                return .{ .confirmed = self.selectedIndex() };
            },
            .escape => return .dismissed,
            .ctrl => |ctrl| if (ctrl == 'c') return .dismissed else return .ignored,
            else => return .ignored,
        }
    }

    pub fn draw(
        self: *const SelectList,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        const top_padding: u16 = @intCast(@min(self.padding_y, window.height));
        var row: u16 = top_padding;

        if (self.items.len == 0) {
            if (row < window.height) {
                const empty_window = window.child(.{ .y_off = @intCast(row), .height = 1 });
                empty_window.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = self.empty_style });
                _ = empty_window.printSegment(.{ .text = "No items", .style = self.empty_style }, .{ .wrap = .none });
                row += 1;
            }
        } else {
            const available_rows = @as(usize, window.height - top_padding);
            var visible_count = @min(@min(@max(self.max_visible, 1), self.items.len), available_rows);
            if (!self.show_scrollbar and self.items.len > visible_count and visible_count > 1) {
                visible_count -= 1;
            }
            const start_index = self.visibleStartIndexFor(visible_count);
            const end_index = @min(start_index + visible_count, self.items.len);
            const scrollbar_width: u16 = if (self.show_scrollbar and self.items.len > visible_count and visible_count > 0) 1 else 0;
            const content_width = if (window.width > scrollbar_width) window.width - scrollbar_width else 0;

            for (start_index..end_index) |index| {
                if (row >= window.height) break;
                const row_window = window.child(.{ .y_off = @intCast(row), .height = 1, .width = content_width });
                try self.drawItemRow(ctx.arena, row_window, self.items[index], index == self.selectedIndex());
                row += 1;
            }

            if (self.show_scrollbar and scrollbar_width > 0 and visible_count > 0) {
                const thumb_height = @max(1, (visible_count * visible_count) / self.items.len);
                const max_offset = self.items.len - visible_count;
                const thumb_start = if (max_offset == 0) 0 else (start_index * (visible_count - thumb_height)) / max_offset;
                const scroll_col = window.width - 1;
                for (0..visible_count) |i| {
                    const row_y = top_padding + @as(u16, @intCast(i));
                    if (row_y >= window.height) break;
                    const is_thumb = i >= thumb_start and i < thumb_start + thumb_height;
                    window.writeCell(scroll_col, row_y, .{
                        .char = .{ .grapheme = if (is_thumb) self.scrollbar_thumb else self.scrollbar_track, .width = 1 },
                        .style = .{},
                    });
                }
            }

            if (self.items.len > visible_count and row < window.height and !self.show_scrollbar) {
                const info_window = window.child(.{ .y_off = @intCast(row), .height = 1 });
                info_window.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = self.scroll_style });
                const info = try std.fmt.allocPrint(ctx.arena, "  ({d}/{d})", .{ self.selectedIndex() + 1, self.items.len });
                _ = info_window.printSegment(.{ .text = info, .style = self.scroll_style }, .{ .wrap = .none });
                row += 1;
            }
        }

        const bottom_padding: u16 = @intCast(@min(self.padding_y, window.height - row));
        row += bottom_padding;
        return .{ .width = window.width, .height = row };
    }

    fn drawItemRow(
        self: *const SelectList,
        allocator: std.mem.Allocator,
        row_window: vaxis.Window,
        item: SelectItem,
        is_selected: bool,
    ) std.mem.Allocator.Error!void {
        const prefix = if (is_selected) self.highlight_symbol else self.unselected_symbol;
        const prefix_width = ansi.visibleWidth(prefix);
        const content_width = @as(usize, row_window.width) - @min(@as(usize, row_window.width), prefix_width);

        const row_style = if (is_selected) self.selected_style else vaxis.Cell.Style{};
        row_window.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = row_style });

        var segments = std.ArrayList(vaxis.Segment).empty;
        try segments.append(allocator, .{ .text = prefix, .style = row_style });

        const display = item.display();
        if (item.description) |description| {
            if (content_width > 16) {
                const primary_width = @max(@as(usize, 1), content_width / 2);
                const truncated_label = try truncatePlainAlloc(allocator, display, primary_width);
                const truncated_description = try truncatePlainAlloc(
                    allocator,
                    normalizeSingleLine(description),
                    content_width - @min(content_width, primary_width),
                );
                try segments.append(allocator, .{ .text = truncated_label, .style = row_style });

                const used_width = prefix_width + ansi.visibleWidth(truncated_label);
                const gap = @max(@as(usize, 1), primary_width + prefix_width - used_width);
                if (gap > 0) {
                    const spaces = try allocator.alloc(u8, gap);
                    @memset(spaces, ' ');
                    try segments.append(allocator, .{ .text = spaces, .style = row_style });
                }

                const description_style = if (is_selected) row_style else self.description_style;
                try segments.append(allocator, .{ .text = truncated_description, .style = description_style });
            } else {
                const truncated = try truncatePlainAlloc(allocator, display, content_width);
                try segments.append(allocator, .{ .text = truncated, .style = row_style });
            }
        } else {
            const truncated = try truncatePlainAlloc(allocator, display, content_width);
            try segments.append(allocator, .{ .text = truncated, .style = row_style });
        }

        _ = row_window.print(segments.items, .{ .wrap = .none });
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const SelectList = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }

    pub fn visibleStartIndex(self: *const SelectList) usize {
        return self.visibleStartIndexFor(@min(@max(self.max_visible, 1), self.items.len));
    }

    fn visibleStartIndexFor(self: *const SelectList, visible_count: usize) usize {
        if (visible_count == 0 or self.selectedIndex() < visible_count / 2) return 0;

        const centered = self.selectedIndex() - visible_count / 2;
        const max_start = self.items.len - visible_count;
        return @min(centered, max_start);
    }

};

fn renderPaddedLine(
    allocator: std.mem.Allocator,
    text: []const u8,
    width: usize,
    selected: bool,
) std.mem.Allocator.Error![]u8 {
    _ = selected;
    const padded = try ansi.padRightVisibleAlloc(allocator, text, width);
    defer allocator.free(padded);
    return allocator.dupe(u8, padded);
}

fn truncatePlainAlloc(allocator: std.mem.Allocator, text: []const u8, max_width: usize) std.mem.Allocator.Error![]u8 {
    if (max_width == 0) return allocator.dupe(u8, "");

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    var visible_width: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const cluster = ansi.nextDisplayCluster(text, index);
        if (cluster.end <= index) break;
        if (visible_width + cluster.width > max_width) break;

        try builder.appendSlice(allocator, text[index..cluster.end]);
        index = cluster.end;
        visible_width += cluster.width;
    }

    return builder.toOwnedSlice(allocator);
}

fn normalizeSingleLine(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

test "select list highlights current selection and navigates" {
    var list = SelectList{
        .items = &[_]SelectItem{
            .{ .value = "one", .description = "first item" },
            .{ .value = "two", .description = "second item" },
            .{ .value = "three", .description = "third item" },
        },
        .max_visible = 3,
    };

    {
        var screen = try test_helpers.renderToScreen(list.drawComponent(), 24, 3);
        defer screen.deinit(std.testing.allocator);

        const selected = screen.readCell(2, 0) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("o", selected.char.grapheme);
        try std.testing.expect(!selected.style.reverse);
    }

    try std.testing.expectEqualDeep(HandleResult.handled, list.handleKey(.down));
    try std.testing.expectEqual(@as(usize, 1), list.selectedIndex());

    {
        var screen = try test_helpers.renderToScreen(list.drawComponent(), 24, 3);
        defer screen.deinit(std.testing.allocator);

        const first_row = screen.readCell(2, 0) orelse return error.TestUnexpectedResult;
        const second_row = screen.readCell(2, 1) orelse return error.TestUnexpectedResult;
        try std.testing.expect(!first_row.style.reverse);
        try std.testing.expect(!second_row.style.reverse);
        try std.testing.expectEqualStrings("t", second_row.char.grapheme);
    }
}

test "select list confirms the selected item on enter" {
    var list = SelectList{
        .items = &[_]SelectItem{
            .{ .value = "one" },
            .{ .value = "two" },
        },
    };
    list.setSelectedIndex(1);

    const result = list.handleKey(.enter);
    try std.testing.expect(result == .confirmed);
    try std.testing.expectEqual(@as(usize, 1), result.confirmed);
    try std.testing.expectEqualStrings("two", list.selectedItem().?.value);
}

test "select list uses selected token and muted description styling" {
    var list = SelectList{
        .items = &[_]SelectItem{
            .{ .value = "one", .description = "first" },
            .{ .value = "two", .description = "second" },
        },
        .selected_index = 1,
        .selected_style = .{ .reverse = true },
        .description_style = .{ .fg = .{ .index = 8 } },
    };

    var screen = try test_helpers.renderToScreen(list.drawComponent(), 24, 2);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 13, 0, "f", .{ .fg = .{ .index = 8 } });
    try test_helpers.expectCell(&screen, 13, 1, "s", .{ .reverse = true });

    const selected_label = screen.readCell(2, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(selected_label.style.reverse);
}

test "select list truncation respects display width for wide and combining graphemes" {
    const cjk = try truncatePlainAlloc(std.testing.allocator, "ab你好", 4);
    defer std.testing.allocator.free(cjk);
    try std.testing.expectEqualStrings("ab你", cjk);
    try std.testing.expectEqual(@as(usize, 4), ansi.visibleWidth(cjk));

    const emoji = try truncatePlainAlloc(std.testing.allocator, "🙂🙂x", 4);
    defer std.testing.allocator.free(emoji);
    try std.testing.expectEqualStrings("🙂🙂", emoji);
    try std.testing.expectEqual(@as(usize, 4), ansi.visibleWidth(emoji));

    const combining = try truncatePlainAlloc(std.testing.allocator, "e\u{0301}x", 1);
    defer std.testing.allocator.free(combining);
    try std.testing.expectEqualStrings("e\u{0301}", combining);
    try std.testing.expectEqual(@as(usize, 1), ansi.visibleWidth(combining));
}

test "select list render keeps unicode labels within requested width" {
    var list = SelectList{
        .items = &[_]SelectItem{
            .{ .value = "wide", .label = "你好世界🙂" },
        },
        .max_visible = 1,
    };

    var screen = try test_helpers.renderToScreen(list.drawComponent(), 8, 1);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "你好世界🙂") == null);
}

test "select list keeps selected item visible in short windows" {
    var list = SelectList{
        .items = &[_]SelectItem{
            .{ .value = "zero" },
            .{ .value = "one" },
            .{ .value = "two" },
            .{ .value = "three" },
            .{ .value = "four" },
        },
        .selected_index = 4,
        .max_visible = 5,
        .selected_style = .{ .reverse = true },
        .show_scrollbar = true,
    };

    var screen = try test_helpers.renderToScreen(list.drawComponent(), 12, 2);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "four") != null);
    const selected = screen.readCell(2, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(selected.style.reverse);
}
