const std = @import("std");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
const keys = @import("../keys.zig");

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

    pub fn component(self: *const SelectList) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
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
            try component_mod.appendOwnedLine(lines, allocator, empty);
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
                const styled = try renderPaddedLine(allocator, info, effective_width, false);
                defer allocator.free(styled);
                try component_mod.appendOwnedLine(lines, allocator, styled);
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
        const self: *const SelectList = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }

    fn visibleStartIndex(self: *const SelectList) usize {
        const visible_count = @min(@max(self.max_visible, 1), self.items.len);
        if (visible_count == 0 or self.selectedIndex() < visible_count / 2) return 0;

        const centered = self.selectedIndex() - visible_count / 2;
        const max_start = self.items.len - visible_count;
        return @min(centered, max_start);
    }

    fn renderItem(
        _: *const SelectList,
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
                try line.appendSlice(allocator, "\x1b[2m");
                try line.appendSlice(allocator, truncated_description);
                try line.appendSlice(allocator, "\x1b[0m");
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

        const padded = try renderPaddedLine(allocator, line.items, width, is_selected);
        line.deinit(allocator);
        return padded;
    }
};

fn renderPaddedLine(
    allocator: std.mem.Allocator,
    text: []const u8,
    width: usize,
    selected: bool,
) std.mem.Allocator.Error![]u8 {
    const padded = try ansi.padRightVisibleAlloc(allocator, text, width);
    defer allocator.free(padded);

    if (!selected) {
        return allocator.dupe(u8, padded);
    }

    var line = std.ArrayList(u8).empty;
    errdefer line.deinit(allocator);
    try line.appendSlice(allocator, "\x1b[7m");
    try line.appendSlice(allocator, padded);
    try line.appendSlice(allocator, "\x1b[0m");
    return line.toOwnedSlice(allocator);
}

fn truncatePlainAlloc(allocator: std.mem.Allocator, text: []const u8, max_width: usize) std.mem.Allocator.Error![]u8 {
    if (max_width == 0) return allocator.dupe(u8, "");

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len and width < max_width) {
        const rune_len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const actual_len = @min(rune_len, text.len - index);
        try builder.appendSlice(allocator, text[index .. index + actual_len]);
        index += actual_len;
        width += 1;
    }

    return builder.toOwnedSlice(allocator);
}

fn normalizeSingleLine(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

test "select list highlights current selection and navigates" {
    const allocator = std.testing.allocator;

    var list = SelectList{
        .items = &[_]SelectItem{
            .{ .value = "one", .description = "first item" },
            .{ .value = "two", .description = "second item" },
            .{ .value = "three", .description = "third item" },
        },
        .max_visible = 3,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try list.renderInto(allocator, 24, &lines);

    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "\x1b[7m") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "one") != null);

    try std.testing.expectEqualDeep(HandleResult.handled, list.handleKey(.down));
    try std.testing.expectEqual(@as(usize, 1), list.selectedIndex());

    component_mod.freeLines(allocator, &lines);
    lines = .empty;
    try list.renderInto(allocator, 24, &lines);

    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "\x1b[7m") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "two") != null);
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
