const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
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

    pub fn component(self: *const TruncatedText) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn drawComponent(self: *const TruncatedText) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
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
        const display = try truncateCodepointsAlloc(ctx.arena, single_line, content_window.width, self.ellipsis, self.mode);
        _ = content_window.printSegment(.{ .text = display }, .{ .wrap = .none });

        const total_height = @min(window.height, @as(u16, @intCast(self.padding_y * 2 + 1)));
        return .{ .width = window.width, .height = total_height };
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
        const display = try truncateCodepointsAlloc(allocator, single_line, content_width, self.ellipsis, self.mode);
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

fn truncateCodepointsAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_units: usize,
    ellipsis: []const u8,
    mode: TruncationMode,
) std.mem.Allocator.Error![]u8 {
    if (max_units == 0) return allocator.dupe(u8, "");

    const unit_count = countCodepoints(text);
    if (unit_count <= max_units) return allocator.dupe(u8, text);

    const ellipsis_units = countCodepoints(ellipsis);
    if (ellipsis_units == 0) return sliceCodepointsAlloc(allocator, text, 0, max_units);
    if (ellipsis_units >= max_units) return sliceCodepointsAlloc(allocator, ellipsis, 0, max_units);

    const kept_units = max_units - ellipsis_units;
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    switch (mode) {
        .end => {
            const prefix = try sliceCodepointsAlloc(allocator, text, 0, kept_units);
            defer allocator.free(prefix);
            try builder.appendSlice(allocator, prefix);
            try builder.appendSlice(allocator, ellipsis);
        },
        .start => {
            const suffix = try sliceCodepointsAlloc(allocator, text, unit_count - kept_units, kept_units);
            defer allocator.free(suffix);
            try builder.appendSlice(allocator, ellipsis);
            try builder.appendSlice(allocator, suffix);
        },
        .middle => {
            const prefix_units = std.math.divCeil(usize, kept_units, 2) catch kept_units;
            const suffix_units = kept_units - prefix_units;

            const prefix = try sliceCodepointsAlloc(allocator, text, 0, prefix_units);
            defer allocator.free(prefix);
            try builder.appendSlice(allocator, prefix);
            try builder.appendSlice(allocator, ellipsis);

            if (suffix_units > 0) {
                const suffix = try sliceCodepointsAlloc(allocator, text, unit_count - suffix_units, suffix_units);
                defer allocator.free(suffix);
                try builder.appendSlice(allocator, suffix);
            }
        },
    }

    return builder.toOwnedSlice(allocator);
}

fn countCodepoints(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[index]) catch break;
        index += sequence_len;
        count += 1;
    }
    return count;
}

fn sliceCodepointsAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    start: usize,
    count: usize,
) std.mem.Allocator.Error![]u8 {
    if (count == 0) return allocator.dupe(u8, "");

    var index: usize = 0;
    var current: usize = 0;
    var start_byte: ?usize = null;
    var end_byte: ?usize = null;

    while (index < text.len) {
        if (current == start and start_byte == null) start_byte = index;
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[index]) catch break;
        index += sequence_len;
        current += 1;
        if (current == start + count) {
            end_byte = index;
            break;
        }
    }

    const begin = start_byte orelse return allocator.dupe(u8, "");
    return allocator.dupe(u8, text[begin .. end_byte orelse text.len]);
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
