const std = @import("std");
const ansi = @import("ansi.zig");
const component_mod = @import("component.zig");

pub const Axis = enum {
    row,
    column,
};

pub const JustifyContent = enum {
    start,
    center,
    end,
    space_between,
    space_around,
    space_evenly,
};

pub const AlignItems = enum {
    start,
    center,
    end,
    stretch,
};

pub const ViewportAnchor = enum {
    top,
    bottom,
};

pub const Insets = struct {
    top: usize = 0,
    right: usize = 0,
    bottom: usize = 0,
    left: usize = 0,

    pub fn uniform(value: usize) Insets {
        return .{
            .top = value,
            .right = value,
            .bottom = value,
            .left = value,
        };
    }

    pub fn symmetric(vertical_padding: usize, horizontal_padding: usize) Insets {
        return .{
            .top = vertical_padding,
            .right = horizontal_padding,
            .bottom = vertical_padding,
            .left = horizontal_padding,
        };
    }

    pub fn horizontal(self: Insets) usize {
        return self.left + self.right;
    }

    pub fn vertical(self: Insets) usize {
        return self.top + self.bottom;
    }
};

pub fn blankLineOwned(allocator: std.mem.Allocator, width: usize) std.mem.Allocator.Error![]u8 {
    const effective_width = @max(width, 1);
    const blank = try allocator.alloc(u8, effective_width);
    @memset(blank, ' ');
    return blank;
}

pub fn appendBlankLines(
    allocator: std.mem.Allocator,
    lines: *component_mod.LineList,
    count: usize,
    width: usize,
) std.mem.Allocator.Error!void {
    if (count == 0) return;

    const blank = try blankLineOwned(allocator, width);
    defer allocator.free(blank);

    for (0..count) |_| {
        try component_mod.appendOwnedLine(lines, allocator, blank);
    }
}

pub fn truncateVisibleAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    width: usize,
) std.mem.Allocator.Error![]u8 {
    if (width == 0) return allocator.dupe(u8, "");
    if (ansi.visibleWidth(text) <= width) return allocator.dupe(u8, text);
    return ansi.sliceVisibleAlloc(allocator, text, 0, width);
}

pub fn alignLineAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    width: usize,
    alignment: AlignItems,
) std.mem.Allocator.Error![]u8 {
    if (width == 0) return allocator.dupe(u8, "");

    const truncated = try truncateVisibleAlloc(allocator, text, width);
    defer allocator.free(truncated);

    const text_width = ansi.visibleWidth(truncated);
    const remaining = width - @min(width, text_width);
    const left_padding = switch (alignment) {
        .start, .stretch => 0,
        .center => remaining / 2,
        .end => remaining,
    };

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    try builder.appendNTimes(allocator, ' ', left_padding);
    try builder.appendSlice(allocator, truncated);

    const aligned = try ansi.padRightVisibleAlloc(allocator, builder.items, width);
    builder.deinit(allocator);
    return aligned;
}

pub fn wrapInsetLineAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    inner_width: usize,
    total_width: usize,
    insets: Insets,
    alignment: AlignItems,
) std.mem.Allocator.Error![]u8 {
    const aligned = try alignLineAlloc(allocator, text, inner_width, alignment);
    defer allocator.free(aligned);

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    try builder.appendNTimes(allocator, ' ', insets.left);
    try builder.appendSlice(allocator, aligned);
    try builder.appendNTimes(allocator, ' ', insets.right);

    const fitted = try ansi.padRightVisibleAlloc(allocator, builder.items, total_width);
    builder.deinit(allocator);
    return fitted;
}

test "align line centers visible content without exceeding width" {
    const allocator = std.testing.allocator;

    const centered = try alignLineAlloc(allocator, "πi", 6, .center);
    defer allocator.free(centered);

    try std.testing.expectEqual(@as(usize, 6), ansi.visibleWidth(centered));
    try std.testing.expect(std.mem.indexOf(u8, centered, "πi") != null);
}

test "wrap inset line applies outer padding and preserves width" {
    const allocator = std.testing.allocator;

    const rendered = try wrapInsetLineAlloc(allocator, "menu", 6, 10, Insets.symmetric(0, 2), .center);
    defer allocator.free(rendered);

    try std.testing.expectEqual(@as(usize, 10), ansi.visibleWidth(rendered));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "menu") != null);
}
