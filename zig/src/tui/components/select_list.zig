const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
const draw_mod = @import("../draw.zig");
const keys = @import("../keys.zig");
const style_mod = @import("../style.zig");
const test_helpers = @import("../test_helpers.zig");
const resources_mod = @import("../theme.zig");

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
    theme: ?*const resources_mod.Theme = null,

    pub fn component(self: *const SelectList) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn drawComponent(self: *const SelectList) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
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
        const active_theme = ctx.theme orelse self.theme;
        window.clear();

        const top_padding: u16 = @intCast(@min(self.padding_y, window.height));
        var row: u16 = top_padding;

        if (self.items.len == 0) {
            if (row < window.height) {
                const empty_window = window.child(.{ .y_off = @intCast(row), .height = 1 });
                const empty_style = if (active_theme) |theme|
                    style_mod.styleFor(theme, .select_empty)
                else
                    vaxis.Cell.Style{};
                empty_window.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = empty_style });
                _ = empty_window.printSegment(.{ .text = "No items", .style = empty_style }, .{ .wrap = .none });
                row += 1;
            }
        } else {
            const start_index = self.visibleStartIndex();
            const end_index = @min(start_index + @max(self.max_visible, 1), self.items.len);
            for (start_index..end_index) |index| {
                if (row >= window.height) break;
                const row_window = window.child(.{ .y_off = @intCast(row), .height = 1 });
                try self.drawItemRow(ctx.arena, row_window, active_theme, self.items[index], index == self.selectedIndex());
                row += 1;
            }

            if (self.items.len > @max(self.max_visible, 1) and row < window.height) {
                const info_style = if (active_theme) |theme|
                    style_mod.styleFor(theme, .select_scroll)
                else
                    vaxis.Cell.Style{};
                const info_window = window.child(.{ .y_off = @intCast(row), .height = 1 });
                info_window.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = info_style });
                const info = try std.fmt.allocPrint(ctx.arena, "  ({d}/{d})", .{ self.selectedIndex() + 1, self.items.len });
                _ = info_window.printSegment(.{ .text = info, .style = info_style }, .{ .wrap = .none });
                row += 1;
            }
        }

        const bottom_padding: u16 = @intCast(@min(self.padding_y, window.height - row));
        row += bottom_padding;
        return .{ .width = window.width, .height = row };
    }

    pub fn renderInto(
        self: *const SelectList,
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

        if (self.items.len == 0) {
            const empty = try ansi.padRightVisibleAlloc(allocator, "No items", effective_width);
            defer allocator.free(empty);
            if (self.theme) |theme| {
                const themed = try theme.applyAlloc(allocator, .select_empty, empty);
                defer allocator.free(themed);
                try component_mod.appendOwnedLine(lines, allocator, themed);
            } else {
                try component_mod.appendOwnedLine(lines, allocator, empty);
            }
        } else {
            const start_index = self.visibleStartIndex();
            const end_index = @min(start_index + @max(self.max_visible, 1), self.items.len);
            for (start_index..end_index) |index| {
                const rendered = try self.renderItem(allocator, self.items[index], index == self.selectedIndex(), effective_width);
                defer allocator.free(rendered);
                try component_mod.appendOwnedLine(lines, allocator, rendered);
            }

            if (self.items.len > @max(self.max_visible, 1)) {
                const info = try std.fmt.allocPrint(allocator, "  ({d}/{d})", .{ self.selectedIndex() + 1, self.items.len });
                defer allocator.free(info);
                const styled = try renderPaddedLine(allocator, self.theme, info, effective_width, false);
                defer allocator.free(styled);
                try component_mod.appendOwnedLine(lines, allocator, styled);
            }
        }

        for (0..self.padding_y) |_| {
            try component_mod.appendOwnedLine(lines, allocator, blank_line);
        }
    }

    fn drawItemRow(
        _: *const SelectList,
        allocator: std.mem.Allocator,
        row_window: vaxis.Window,
        active_theme: ?*const resources_mod.Theme,
        item: SelectItem,
        is_selected: bool,
    ) std.mem.Allocator.Error!void {
        const prefix = if (is_selected) "→ " else "  ";
        const prefix_width = ansi.visibleWidth(prefix);
        const content_width = @as(usize, row_window.width) - @min(@as(usize, row_window.width), prefix_width);

        const base_style = if (active_theme) |theme|
            style_mod.styleFor(theme, .text)
        else
            vaxis.Cell.Style{};
        const row_style = withReverse(base_style, is_selected);
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

                var description_style = if (active_theme) |theme|
                    style_mod.styleFor(theme, .select_description)
                else
                    vaxis.Cell.Style{};
                description_style.reverse = is_selected;
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

    fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const SelectList = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const SelectList = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }

    fn visibleStartIndex(self: *const SelectList) usize {
        const visible_count = @min(@max(self.max_visible, 1), self.items.len);
        if (visible_count == 0 or self.selectedIndex() < visible_count / 2) return 0;

        const centered = self.selectedIndex() - visible_count / 2;
        const max_start = self.items.len - visible_count;
        return @min(centered, max_start);
    }

    fn renderItem(
        self: *const SelectList,
        allocator: std.mem.Allocator,
        item: SelectItem,
        is_selected: bool,
        width: usize,
    ) std.mem.Allocator.Error![]u8 {
        const prefix = if (is_selected) "→ " else "  ";
        const prefix_width = ansi.visibleWidth(prefix);
        const content_width = width - @min(width, prefix_width);

        var line = std.ArrayList(u8).empty;
        errdefer line.deinit(allocator);

        try line.appendSlice(allocator, prefix);

        const display = item.display();
        if (item.description) |description| {
            if (content_width > 16) {
                const primary_width = @max(1, content_width / 2);
                const truncated_label = try truncatePlainAlloc(allocator, display, primary_width);
                defer allocator.free(truncated_label);

                const truncated_description = try truncatePlainAlloc(allocator, normalizeSingleLine(description), content_width - @min(content_width, primary_width));
                defer allocator.free(truncated_description);

                try line.appendSlice(allocator, truncated_label);

                const used_width = ansi.visibleWidth(prefix) + ansi.visibleWidth(truncated_label);
                const gap = @max(@as(usize, 1), primary_width + prefix_width - used_width);
                try line.appendNTimes(allocator, ' ', gap);
                try line.appendSlice(allocator, truncated_description);
            } else {
                const truncated = try truncatePlainAlloc(allocator, display, content_width);
                defer allocator.free(truncated);
                try line.appendSlice(allocator, truncated);
            }
        } else {
            const truncated = try truncatePlainAlloc(allocator, display, content_width);
            defer allocator.free(truncated);
            try line.appendSlice(allocator, truncated);
        }

        const padded = try renderPaddedLine(allocator, self.theme, line.items, width, is_selected);
        line.deinit(allocator);
        return padded;
    }
};

fn renderPaddedLine(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    text: []const u8,
    width: usize,
    selected: bool,
) std.mem.Allocator.Error![]u8 {
    const padded = try ansi.padRightVisibleAlloc(allocator, text, width);
    defer allocator.free(padded);

    if (theme) |active_theme| {
        if (selected) {
            return active_theme.applyAlloc(allocator, .select_selected, padded);
        }
        if (std.mem.startsWith(u8, padded, "  (")) {
            return active_theme.applyAlloc(allocator, .select_scroll, padded);
        }
    }

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

fn withReverse(style: vaxis.Cell.Style, reverse: bool) vaxis.Cell.Style {
    var updated = style;
    updated.reverse = reverse;
    return updated;
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
        try std.testing.expect(selected.style.reverse);
    }

    try std.testing.expectEqualDeep(HandleResult.handled, list.handleKey(.down));
    try std.testing.expectEqual(@as(usize, 1), list.selectedIndex());

    {
        var screen = try test_helpers.renderToScreen(list.drawComponent(), 24, 3);
        defer screen.deinit(std.testing.allocator);

        const first_row = screen.readCell(2, 0) orelse return error.TestUnexpectedResult;
        const second_row = screen.readCell(2, 1) orelse return error.TestUnexpectedResult;
        try std.testing.expect(!first_row.style.reverse);
        try std.testing.expect(second_row.style.reverse);
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

test "select list uses reverse selection and muted description styling" {
    var theme = try resources_mod.Theme.initDefault(std.testing.allocator);
    defer theme.deinit(std.testing.allocator);

    var list = SelectList{
        .items = &[_]SelectItem{
            .{ .value = "one", .description = "first" },
            .{ .value = "two", .description = "second" },
        },
        .selected_index = 1,
        .theme = &theme,
    };

    var screen = try test_helpers.renderToScreenWithTheme(list.drawComponent(), 24, 2, &theme);
    defer screen.deinit(std.testing.allocator);

    const muted = style_mod.styleFor(&theme, .select_description);
    try test_helpers.expectCell(&screen, 13, 0, "f", muted);

    var muted_selected = muted;
    muted_selected.reverse = true;
    try test_helpers.expectCell(&screen, 13, 1, "s", muted_selected);

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
