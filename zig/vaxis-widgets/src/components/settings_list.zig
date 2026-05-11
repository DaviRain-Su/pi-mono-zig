const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const keys = @import("../keys.zig");
const test_helpers = @import("../test_helpers.zig");

pub const SettingItem = struct {
    id: []const u8,
    label: []const u8,
    description: ?[]const u8 = null,
    current_value: []const u8,
    values: []const []const u8 = &.{},
};

pub const SettingsListTheme = struct {
    label_style: vaxis.Cell.Style = .{},
    selected_label_style: vaxis.Cell.Style = .{ .reverse = true },
    value_style: vaxis.Cell.Style = .{ .dim = true },
    selected_value_style: vaxis.Cell.Style = .{ .reverse = true },
    description_style: vaxis.Cell.Style = .{ .dim = true },
    hint_style: vaxis.Cell.Style = .{ .dim = true },
    search_style: vaxis.Cell.Style = .{},
    cursor: []const u8 = "→ ",
};

pub const HandleResult = union(enum) {
    handled,
    changed: struct {
        id: []const u8,
        value: []const u8,
    },
    dismissed,
    ignored,
};

pub const SettingsList = struct {
    items: []SettingItem,
    selected_index: usize = 0,
    max_visible: usize = 8,
    theme: SettingsListTheme = .{},
    enable_search: bool = false,
    search_query: []const u8 = "",

    pub fn drawComponent(self: *const SettingsList) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn updateValue(self: *SettingsList, id: []const u8, new_value: []const u8) bool {
        for (self.items) |*item| {
            if (std.mem.eql(u8, item.id, id)) {
                item.current_value = new_value;
                return true;
            }
        }
        return false;
    }

    pub fn selectedItem(self: *const SettingsList) ?SettingItem {
        const index = self.selectedBackingIndex() orelse return null;
        return self.items[index];
    }

    pub fn handleKey(self: *SettingsList, key: keys.Key) HandleResult {
        const count = self.filteredCount();
        switch (key) {
            .up => {
                if (count == 0) return .ignored;
                self.selected_index = if (self.selected_index == 0) count - 1 else self.selected_index - 1;
                return .handled;
            },
            .down => {
                if (count == 0) return .ignored;
                self.selected_index = if (self.selected_index + 1 >= count) 0 else self.selected_index + 1;
                return .handled;
            },
            .enter => return self.activateSelected(),
            .printable => |printable| {
                if (printable.len == 1 and printable.slice()[0] == ' ') return self.activateSelected();
                return .ignored;
            },
            .escape => return .dismissed,
            .ctrl => |ctrl| if (ctrl == 'c') return .dismissed else return .ignored,
            else => return .ignored,
        }
    }

    pub fn activateSelected(self: *SettingsList) HandleResult {
        const index = self.selectedBackingIndex() orelse return .ignored;
        var item = &self.items[index];
        if (item.values.len == 0) return .ignored;

        const current_index = valueIndex(item.values, item.current_value) orelse item.values.len - 1;
        const next_index = (current_index + 1) % item.values.len;
        item.current_value = item.values[next_index];
        return .{ .changed = .{ .id = item.id, .value = item.current_value } };
    }

    pub fn draw(
        self: *const SettingsList,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();
        var row: u16 = 0;

        if (self.enable_search and row < window.height) {
            const search_text = try std.fmt.allocPrint(ctx.arena, "Search: {s}", .{self.search_query});
            try drawLine(window, row, search_text, self.theme.search_style);
            row += 1;
            if (row < window.height) row += 1;
        }

        const count = self.filteredCount();
        if (self.items.len == 0) {
            if (row < window.height) {
                try drawLine(window, row, "  No settings available", self.theme.hint_style);
                row += 1;
            }
            return .{ .width = window.width, .height = row };
        }
        if (count == 0) {
            if (row < window.height) {
                try drawLine(window, row, "  No matching settings", self.theme.hint_style);
                row += 1;
            }
            return .{ .width = window.width, .height = row };
        }

        const visible_count = @min(@max(self.max_visible, 1), count);
        const start_index = self.visibleStartIndexFor(visible_count, count);
        const end_index = @min(start_index + visible_count, count);
        const label_width = self.maxLabelWidth();

        var filtered_index: usize = 0;
        for (self.items) |item| {
            if (!self.matchesFilter(item)) continue;
            defer filtered_index += 1;
            if (filtered_index < start_index or filtered_index >= end_index) continue;
            if (row >= window.height) break;
            try self.drawItemRow(ctx.arena, window.child(.{ .y_off = @intCast(row), .height = 1 }), item, filtered_index == self.selectedIndex(), label_width);
            row += 1;
        }

        if (count > visible_count and row < window.height) {
            const scroll_text = try std.fmt.allocPrint(ctx.arena, "  ({d}/{d})", .{ self.selectedIndex() + 1, count });
            try drawLine(window, row, scroll_text, self.theme.hint_style);
            row += 1;
        }

        if (self.selectedItem()) |item| {
            if (item.description) |description| {
                if (row + 1 < window.height) {
                    row += 1;
                    const line = try std.fmt.allocPrint(ctx.arena, "  {s}", .{std.mem.trim(u8, description, " \t\r\n")});
                    try drawLine(window, row, line, self.theme.description_style);
                    row += 1;
                }
            }
        }

        if (row + 1 < window.height) {
            row += 1;
            const hint = if (self.enable_search)
                "  Type to search · Enter/Space to change · Esc to cancel"
            else
                "  Enter/Space to change · Esc to cancel";
            try drawLine(window, row, hint, self.theme.hint_style);
            row += 1;
        }

        return .{ .width = window.width, .height = row };
    }

    fn drawItemRow(
        self: *const SettingsList,
        allocator: std.mem.Allocator,
        row_window: vaxis.Window,
        item: SettingItem,
        selected: bool,
        label_width: usize,
    ) std.mem.Allocator.Error!void {
        const prefix = if (selected) self.theme.cursor else "  ";
        const prefix_width = ansi.visibleWidth(prefix);
        const separator = "  ";
        const used_width = prefix_width + label_width + ansi.visibleWidth(separator);
        const value_width = if (row_window.width > used_width) row_window.width - @as(u16, @intCast(used_width)) else 0;

        const padded_label = try padRightVisibleAlloc(allocator, item.label, label_width);
        const value = try truncatePlainAlloc(allocator, item.current_value, value_width);

        var segments = std.ArrayList(vaxis.Segment).empty;
        try segments.append(allocator, .{ .text = prefix, .style = if (selected) self.theme.selected_label_style else self.theme.label_style });
        try segments.append(allocator, .{ .text = padded_label, .style = if (selected) self.theme.selected_label_style else self.theme.label_style });
        try segments.append(allocator, .{ .text = separator, .style = if (selected) self.theme.selected_label_style else self.theme.label_style });
        try segments.append(allocator, .{ .text = value, .style = if (selected) self.theme.selected_value_style else self.theme.value_style });

        row_window.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = if (selected) self.theme.selected_label_style else vaxis.Cell.Style{} });
        _ = row_window.print(segments.items, .{ .wrap = .none });
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const SettingsList = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }

    fn selectedIndex(self: *const SettingsList) usize {
        const count = self.filteredCount();
        if (count == 0) return 0;
        return @min(self.selected_index, count - 1);
    }

    fn selectedBackingIndex(self: *const SettingsList) ?usize {
        const wanted = self.selectedIndex();
        var filtered_index: usize = 0;
        for (self.items, 0..) |item, backing_index| {
            if (!self.matchesFilter(item)) continue;
            if (filtered_index == wanted) return backing_index;
            filtered_index += 1;
        }
        return null;
    }

    fn visibleStartIndexFor(self: *const SettingsList, visible_count: usize, filtered_count: usize) usize {
        if (visible_count == 0 or self.selectedIndex() < visible_count / 2) return 0;
        const centered = self.selectedIndex() - visible_count / 2;
        return @min(centered, filtered_count - visible_count);
    }

    fn filteredCount(self: *const SettingsList) usize {
        var count: usize = 0;
        for (self.items) |item| {
            if (self.matchesFilter(item)) count += 1;
        }
        return count;
    }

    fn matchesFilter(self: *const SettingsList, item: SettingItem) bool {
        if (!self.enable_search or self.search_query.len == 0) return true;
        return fuzzySubsequenceMatch(item.label, self.search_query);
    }

    fn maxLabelWidth(self: *const SettingsList) usize {
        var max_width: usize = 0;
        for (self.items) |item| max_width = @max(max_width, ansi.visibleWidth(item.label));
        return @min(max_width, 30);
    }
};

fn valueIndex(values: []const []const u8, current_value: []const u8) ?usize {
    for (values, 0..) |value, index| {
        if (std.mem.eql(u8, value, current_value)) return index;
    }
    return null;
}

fn fuzzySubsequenceMatch(text: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    var query_index: usize = 0;
    for (text) |byte| {
        if (query_index >= query.len) return true;
        if (std.ascii.toLower(byte) == std.ascii.toLower(query[query_index])) {
            query_index += 1;
        }
    }
    return query_index == query.len;
}

fn drawLine(window: vaxis.Window, row: u16, text: []const u8, style: vaxis.Cell.Style) std.mem.Allocator.Error!void {
    const row_window = window.child(.{ .y_off = @intCast(row), .height = 1 });
    row_window.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
    _ = row_window.printSegment(.{ .text = text, .style = style }, .{ .wrap = .none });
}

fn padRightVisibleAlloc(allocator: std.mem.Allocator, text: []const u8, width: usize) std.mem.Allocator.Error![]u8 {
    const visible = ansi.visibleWidth(text);
    if (visible >= width) return truncatePlainAlloc(allocator, text, width);
    const padding = width - visible;
    var out = try std.ArrayList(u8).initCapacity(allocator, text.len + padding);
    try out.appendSlice(allocator, text);
    try out.appendNTimes(allocator, ' ', padding);
    return out.toOwnedSlice(allocator);
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

test "settings list cycles selected item values" {
    var items = [_]SettingItem{
        .{ .id = "theme", .label = "Theme", .current_value = "dark", .values = &[_][]const u8{ "dark", "light" } },
    };
    var list = SettingsList{ .items = &items };
    const result = list.handleKey(.enter);
    try std.testing.expect(result == .changed);
    try std.testing.expectEqualStrings("theme", result.changed.id);
    try std.testing.expectEqualStrings("light", result.changed.value);
    try std.testing.expectEqualStrings("light", items[0].current_value);
}

test "settings list renders label and value" {
    var items = [_]SettingItem{
        .{ .id = "theme", .label = "Theme", .current_value = "dark", .values = &[_][]const u8{ "dark", "light" } },
    };
    const list = SettingsList{ .items = &items };
    var screen = try test_helpers.renderToScreen(list.drawComponent(), 24, 4);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "→", .{ .reverse = true });
    try test_helpers.expectCell(&screen, 2, 0, "T", .{ .reverse = true });
    try test_helpers.expectCell(&screen, 9, 0, "d", .{ .reverse = true });
}
