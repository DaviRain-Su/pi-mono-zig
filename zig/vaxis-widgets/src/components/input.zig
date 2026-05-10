const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

const InputGrapheme = struct {
    byte_start: usize,
    byte_end: usize,
    width: usize,
};

pub const Input = struct {
    text: []const u8 = "",
    placeholder: []const u8 = "",
    cursor: usize = 0,
    style: vaxis.Cell.Style = .{},
    placeholder_style: vaxis.Cell.Style = .{ .dim = true },
    cursor_style: vaxis.Cell.Style = .{ .reverse = true },
    max_width: ?usize = null,
    mask: ?u8 = null, // optional password mask character
    show_cursor: bool = true,

    pub fn drawComponent(self: *const Input) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Input,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (window.width == 0 or window.height == 0) {
            return .{ .width = window.width, .height = 0 };
        }

        const row: u16 = 0;
        const effective_width = if (self.max_width) |mw|
            @min(mw, window.width)
        else
            window.width;

        // Fill background
        for (0..effective_width) |x| {
            window.writeCell(@intCast(x), row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = self.style,
            });
        }

        const display_text = if (self.text.len > 0) self.text else self.placeholder;
        const use_placeholder = self.text.len == 0;
        const text_style = if (use_placeholder) self.placeholder_style else self.style;

        var graphemes = std.ArrayList(InputGrapheme).empty;
        defer graphemes.deinit(ctx.arena);

        var cursor_grapheme_index: usize = 0;
        var idx: usize = 0;
        while (idx < display_text.len) {
            const cluster = ansi.nextDisplayCluster(display_text, idx);
            if (cluster.end <= idx) break;
            if (idx < @min(self.cursor, display_text.len)) cursor_grapheme_index = graphemes.items.len + 1;
            try graphemes.append(ctx.arena, .{
                .byte_start = idx,
                .byte_end = cluster.end,
                .width = cluster.width,
            });
            idx = cluster.end;
        }
        cursor_grapheme_index = @min(cursor_grapheme_index, graphemes.items.len);

        var cursor_col: u16 = 0;

        // If text is too wide, scroll to keep cursor visible
        if (self.mask) |mask_char| {
            // Simple mask: all chars show as mask_char
            const mask_width = ansi.visibleWidth(&[_]u8{mask_char});
            const start_grapheme = visibleStartForCursor(graphemes.items, cursor_grapheme_index, effective_width, mask_width);

            var col: u16 = 0;
            var i: usize = start_grapheme;
            while (i < graphemes.items.len and col < effective_width) : (i += 1) {
                if (col + @as(u16, @intCast(mask_width)) > effective_width) break;
                if (i == cursor_grapheme_index and self.show_cursor and !use_placeholder) {
                    cursor_col = col;
                }
                const grapheme = try std.fmt.allocPrint(ctx.arena, "{c}", .{mask_char});
                window.writeCell(col, row, .{
                    .char = .{ .grapheme = grapheme, .width = @intCast(mask_width) },
                    .style = if (i == cursor_grapheme_index and self.show_cursor and !use_placeholder)
                        self.cursor_style
                    else
                        text_style,
                });
                col += @intCast(mask_width);
            }
            if (cursor_grapheme_index == graphemes.items.len) {
                cursor_col = @intCast(prefixWidth(graphemes.items, cursor_grapheme_index, mask_width) - prefixWidth(graphemes.items, start_grapheme, mask_width));
            }

            if (self.show_cursor and !use_placeholder and cursor_col < effective_width) {
                window.writeCell(cursor_col, row, .{
                    .char = .{ .grapheme = if (cursor_grapheme_index < graphemes.items.len) &[_]u8{mask_char} else " ", .width = @intCast(mask_width) },
                    .style = self.cursor_style,
                });
            }
        } else {
            // Normal text rendering with grapheme awareness
            var col: u16 = 0;

            // Find start grapheme for scrolling
            const start_grapheme = visibleStartForCursor(graphemes.items, cursor_grapheme_index, effective_width, null);

            for (graphemes.items[start_grapheme..], start_grapheme..) |g, gi| {
                if (col >= effective_width) break;
                if (col + @as(u16, @intCast(g.width)) > effective_width) break;
                const is_cursor = gi == cursor_grapheme_index and self.show_cursor and !use_placeholder;
                if (is_cursor) cursor_col = col;
                window.writeCell(col, row, .{
                    .char = .{ .grapheme = display_text[g.byte_start..g.byte_end], .width = @intCast(g.width) },
                    .style = if (is_cursor) self.cursor_style else text_style,
                });
                col += @intCast(g.width);
            }
            if (cursor_grapheme_index == graphemes.items.len) {
                cursor_col = @intCast(prefixWidth(graphemes.items, cursor_grapheme_index, null) - prefixWidth(graphemes.items, start_grapheme, null));
            }

            if (self.show_cursor and !use_placeholder and cursor_col < effective_width) {
                const g = if (cursor_grapheme_index < graphemes.items.len)
                    graphemes.items[cursor_grapheme_index]
                else if (graphemes.items.len > 0)
                    graphemes.items[graphemes.items.len - 1]
                else
                    null;
                if (g) |grapheme| {
                    const available = effective_width - cursor_col;
                    const fits = cursor_grapheme_index >= graphemes.items.len or grapheme.width <= available;
                    window.writeCell(cursor_col, row, .{
                        .char = .{
                            .grapheme = if (cursor_grapheme_index < graphemes.items.len and fits) display_text[grapheme.byte_start..grapheme.byte_end] else " ",
                            .width = if (cursor_grapheme_index < graphemes.items.len and fits) @intCast(grapheme.width) else 1,
                        },
                        .style = self.cursor_style,
                    });
                }
            }
        }

        return .{ .width = @intCast(effective_width), .height = 1 };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Input = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

fn prefixWidth(graphemes: []const InputGrapheme, end: usize, mask_width: ?usize) usize {
    if (mask_width) |width| return @min(end, graphemes.len) * width;
    var width: usize = 0;
    for (graphemes[0..@min(end, graphemes.len)]) |g| {
        width += g.width;
    }
    return width;
}

fn visibleStartForCursor(
    graphemes: []const InputGrapheme,
    cursor_grapheme_index: usize,
    effective_width: usize,
    mask_width: ?usize,
) usize {
    if (effective_width == 0 or graphemes.len == 0) return 0;

    const cursor_width = prefixWidth(graphemes, cursor_grapheme_index, mask_width);
    var start: usize = 0;
    var start_width: usize = 0;

    while (start < cursor_grapheme_index and cursor_width - start_width >= effective_width) {
        start_width += mask_width orelse graphemes[start].width;
        start += 1;
    }

    return start;
}

test "input renders text" {
    const input = Input{
        .text = "hello",
        .cursor = 2,
    };

    var screen = try test_helpers.renderToScreen(input.drawComponent(), 10, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "h", .{});
    try test_helpers.expectCell(&screen, 1, 0, "e", .{});
}

test "input shows placeholder when empty" {
    const input = Input{
        .placeholder = "Type here...",
    };

    var screen = try test_helpers.renderToScreen(input.drawComponent(), 12, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "T", .{ .dim = true });
    try test_helpers.expectCell(&screen, 1, 0, "y", .{ .dim = true });
}

test "input masks password text" {
    const allocator = std.testing.allocator;

    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 1,
        .cols = 10,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = draw_mod.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const input = Input{
        .text = "secret",
        .mask = '*',
    };

    _ = try input.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    });

    const cell = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("*", cell.char.grapheme);
}

test "input handles multibyte cursor offsets" {
    const input = Input{
        .text = "你🙂x",
        .cursor = "你🙂x".len,
    };

    var screen = try test_helpers.renderToScreen(input.drawComponent(), 10, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "你", .{});
    try test_helpers.expectCell(&screen, 2, 0, "🙂", .{});
    try test_helpers.expectCell(&screen, 4, 0, "x", .{});
    try test_helpers.expectCell(&screen, 5, 0, " ", .{ .reverse = true });
}

test "input scrolls long unicode text to keep cursor visible" {
    const input = Input{
        .text = "abcdef🙂",
        .cursor = "abcdef🙂".len,
    };

    var screen = try test_helpers.renderToScreen(input.drawComponent(), 4, 1);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "a") == null);
    try test_helpers.expectCell(&screen, 3, 0, " ", .{ .reverse = true });
}

test "input does not draw wide grapheme past narrow window" {
    const input = Input{
        .text = "🙂x",
        .cursor = 0,
    };

    var screen = try test_helpers.renderToScreen(input.drawComponent(), 1, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, " ", .{ .reverse = true });
}
