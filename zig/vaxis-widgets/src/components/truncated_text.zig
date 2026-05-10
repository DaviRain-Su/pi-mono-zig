const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const TruncationMode = enum {
    start,
    middle,
    end,
};

pub const TruncatedText = struct {
    text: []const u8 = "",
    padding_x: usize = 0,
    padding_y: usize = 0,
    ellipsis: []const u8 = "…",
    mode: TruncationMode = .end,

    pub fn drawComponent(self: *const TruncatedText) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn draw(
        self: *const TruncatedText,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        const content_window = innerWindow(window, self.padding_x, self.padding_y) orelse {
            return .{ .width = window.width, .height = @min(window.height, @as(u16, @intCast(self.padding_y * 2))) };
        };

        const single_line = firstLine(self.text);
        const display = try truncateVisibleAlloc(ctx.arena, single_line, content_window.width, self.ellipsis, self.mode);
        _ = content_window.printSegment(.{ .text = display }, .{ .wrap = .none });

        const total_height = @min(window.height, @as(u16, @intCast(self.padding_y * 2 + 1)));
        return .{ .width = window.width, .height = total_height };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const TruncatedText = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
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
            const suffix = try suffixVisibleAlloc(allocator, text, kept_width);
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
                const suffix = try suffixVisibleAlloc(allocator, text, suffix_width);
                defer allocator.free(suffix);
                try builder.appendSlice(allocator, suffix);
            }
        },
    }

    return builder.toOwnedSlice(allocator);
}

fn suffixVisibleAlloc(allocator: std.mem.Allocator, text: []const u8, width: usize) std.mem.Allocator.Error![]u8 {
    if (width == 0) return allocator.dupe(u8, "");
    const text_width = ansi.visibleWidth(text);
    if (text_width <= width) return allocator.dupe(u8, text);
    return ansi.sliceVisibleAlloc(allocator, text, text_width - width, width);
}

test "truncated text ellipsizes overflowing content at the end" {
    const text = TruncatedText{ .text = "abcdefghij" };

    var screen = try test_helpers.renderToScreen(text.drawComponent(), 8, 1);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("abcdefg…", rendered);
    try test_helpers.expectCell(&screen, 7, 0, "…", .{});
}

test "truncated text supports start truncation" {
    const text = TruncatedText{
        .text = "abcdefghij",
        .mode = .start,
    };

    var screen = try test_helpers.renderToScreen(text.drawComponent(), 8, 1);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("…defghij", rendered);
}

test "truncated text supports middle truncation" {
    const text = TruncatedText{
        .text = "abcdefghij",
        .mode = .middle,
    };

    var screen = try test_helpers.renderToScreen(text.drawComponent(), 8, 1);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("abcd…hij", rendered);
}

test "truncated text respects display width for wide graphemes" {
    const allocator = std.testing.allocator;

    const end = try truncateVisibleAlloc(allocator, "你好世界", 5, "…", .end);
    defer allocator.free(end);
    try std.testing.expectEqualStrings("你好…", end);
    try std.testing.expect(ansi.visibleWidth(end) <= 5);

    const start = try truncateVisibleAlloc(allocator, "你好世界", 5, "…", .start);
    defer allocator.free(start);
    try std.testing.expectEqualStrings("…世界", start);
    try std.testing.expect(ansi.visibleWidth(start) <= 5);

    const emoji = try truncateVisibleAlloc(allocator, "🙂🙂x", 4, "…", .end);
    defer allocator.free(emoji);
    try std.testing.expectEqualStrings("🙂…", emoji);
    try std.testing.expect(ansi.visibleWidth(emoji) <= 4);
}

test "truncated text respects padding and only renders the first line" {
    const text = TruncatedText{
        .text = "hello\nworld",
        .padding_x = 1,
        .padding_y = 1,
    };

    var screen = try test_helpers.renderToScreen(text.drawComponent(), 8, 3);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("        \n hello  \n        ", rendered);
}
