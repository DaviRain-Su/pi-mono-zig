const std = @import("std");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");

pub const TruncationMode = enum {
    start,
    middle,
    end,
};

pub const TruncatedText = struct {
    text: []const u8 = "",
    padding_x: usize = 0,
    padding_y: usize = 0,
    ellipsis: []const u8 = "...",
    mode: TruncationMode = .end,

    pub fn component(self: *const TruncatedText) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn renderInto(
        self: *const TruncatedText,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const effective_width = @max(width, 1);
        const content_width = @max(effective_width, self.padding_x * 2 + 1) - self.padding_x * 2;

        const blank_line = try allocator.alloc(u8, effective_width);
        defer allocator.free(blank_line);
        @memset(blank_line, ' ');

        for (0..self.padding_y) |_| {
            try component_mod.appendOwnedLine(lines, allocator, blank_line);
        }

        const single_line = firstLine(self.text);
        const display = try truncateVisibleAlloc(allocator, single_line, content_width, self.ellipsis, self.mode);
        defer allocator.free(display);

        var builder = std.ArrayList(u8).empty;
        defer builder.deinit(allocator);

        try builder.appendNTimes(allocator, ' ', self.padding_x);
        try builder.appendSlice(allocator, display);
        try builder.appendNTimes(allocator, ' ', self.padding_x);

        const padded = try ansi.padRightVisibleAlloc(allocator, builder.items, effective_width);
        defer allocator.free(padded);
        try component_mod.appendOwnedLine(lines, allocator, padded);

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
        const self: *const TruncatedText = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }
};

fn firstLine(text: []const u8) []const u8 {
    const newline_index = std.mem.indexOfScalar(u8, text, '\n') orelse return text;
    return text[0..newline_index];
}

fn truncateVisibleAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_width: usize,
    ellipsis: []const u8,
    mode: TruncationMode,
) std.mem.Allocator.Error![]u8 {
    if (max_width == 0) return allocator.dupe(u8, "");

    const text_width = ansi.visibleWidth(text);
    if (text_width <= max_width) return allocator.dupe(u8, text);

    const ellipsis_width = ansi.visibleWidth(ellipsis);
    if (ellipsis_width == 0) return ansi.sliceVisibleAlloc(allocator, text, 0, max_width);
    if (ellipsis_width >= max_width) return ansi.sliceVisibleAlloc(allocator, ellipsis, 0, max_width);

    const kept_width = max_width - ellipsis_width;

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    switch (mode) {
        .end => {
            const prefix = try ansi.sliceVisibleAlloc(allocator, text, 0, kept_width);
            defer allocator.free(prefix);
            try builder.appendSlice(allocator, prefix);
            try builder.appendSlice(allocator, ellipsis);
        },
        .start => {
            const suffix = try ansi.sliceVisibleAlloc(allocator, text, text_width - kept_width, kept_width);
            defer allocator.free(suffix);
            try builder.appendSlice(allocator, ellipsis);
            try builder.appendSlice(allocator, suffix);
        },
        .middle => {
            const prefix_width = std.math.divCeil(usize, kept_width, 2) catch kept_width;
            const suffix_width = kept_width - prefix_width;

            const prefix = try ansi.sliceVisibleAlloc(allocator, text, 0, prefix_width);
            defer allocator.free(prefix);
            try builder.appendSlice(allocator, prefix);
            try builder.appendSlice(allocator, ellipsis);

            if (suffix_width > 0) {
                const suffix = try ansi.sliceVisibleAlloc(allocator, text, text_width - suffix_width, suffix_width);
                defer allocator.free(suffix);
                try builder.appendSlice(allocator, suffix);
            }
        },
    }

    return builder.toOwnedSlice(allocator);
}

test "truncated text ellipsizes overflowing content at the end" {
    const allocator = std.testing.allocator;

    const text = TruncatedText{ .text = "abcdefghij" };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);

    try text.renderInto(allocator, 8, &lines);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("abcde...", lines.items[0]);
}

test "truncated text supports start truncation" {
    const allocator = std.testing.allocator;

    const text = TruncatedText{
        .text = "abcdefghij",
        .mode = .start,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);

    try text.renderInto(allocator, 8, &lines);

    try std.testing.expectEqualStrings("...fghij", lines.items[0]);
}

test "truncated text supports middle truncation" {
    const allocator = std.testing.allocator;

    const text = TruncatedText{
        .text = "abcdefghij",
        .mode = .middle,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);

    try text.renderInto(allocator, 8, &lines);

    try std.testing.expectEqualStrings("abc...ij", lines.items[0]);
}

test "truncated text respects padding and only renders the first line" {
    const allocator = std.testing.allocator;

    const text = TruncatedText{
        .text = "hello\nworld",
        .padding_x = 1,
        .padding_y = 1,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);

    try text.renderInto(allocator, 8, &lines);

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("        ", lines.items[0]);
    try std.testing.expectEqualStrings(" hello  ", lines.items[1]);
    try std.testing.expectEqualStrings("        ", lines.items[2]);
}
