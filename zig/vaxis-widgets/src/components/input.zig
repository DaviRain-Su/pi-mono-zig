const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

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

        // Compute visible window based on cursor position
        const clamped_cursor = @min(self.cursor, display_text.len);
        var cursor_col: u16 = 0;

        // If text is too wide, scroll to keep cursor visible
        if (self.mask) |mask_char| {
            // Simple mask: all chars show as mask_char
            const mask_width = ansi.visibleWidth(&[_]u8{mask_char});
            const total_mask_width = display_text.len * mask_width;
            if (total_mask_width > effective_width and clamped_cursor > 0) {
                // Center cursor
                const before_width = clamped_cursor * mask_width;
                _ = before_width;
            }

            var col: u16 = 0;
            var i: usize = 0;
            while (i < display_text.len and col < effective_width) : (i += 1) {
                if (i == clamped_cursor and self.show_cursor and !use_placeholder) {
                    cursor_col = col;
                }
                const grapheme = try std.fmt.allocPrint(ctx.arena, "{c}", .{mask_char});
                window.writeCell(col, row, .{
                    .char = .{ .grapheme = grapheme, .width = @intCast(mask_width) },
                    .style = if (i == clamped_cursor and self.show_cursor and !use_placeholder)
                        self.cursor_style
                    else
                        text_style,
                });
                col += @intCast(mask_width);
            }

            if (self.show_cursor and !use_placeholder and cursor_col < effective_width) {
                window.writeCell(cursor_col, row, .{
                    .char = .{ .grapheme = &[_]u8{mask_char}, .width = @intCast(mask_width) },
                    .style = self.cursor_style,
                });
            }
        } else {
            // Normal text rendering with grapheme awareness
            var col: u16 = 0;
            var graphemes = std.ArrayList(struct { byte_start: usize, byte_end: usize, width: usize }).empty;
            defer graphemes.deinit(std.heap.page_allocator);

            var idx: usize = 0;
            while (idx < display_text.len) {
                const cluster = ansi.nextDisplayCluster(display_text, idx);
                if (cluster.end <= idx) break;
                try graphemes.append(std.heap.page_allocator, .{
                    .byte_start = idx,
                    .byte_end = cluster.end,
                    .width = cluster.width,
                });
                idx = cluster.end;
            }

            // Find start grapheme for scrolling
            var start_grapheme: usize = 0;
            if (graphemes.items.len > 0 and clamped_cursor > 0) {
                var width_before: usize = 0;
                for (graphemes.items[0..clamped_cursor], 0..) |g, i| {
                    width_before += g.width;
                    if (width_before > effective_width / 2) {
                        start_grapheme = i;
                        break;
                    }
                }
            }

            for (graphemes.items[start_grapheme..], start_grapheme..) |g, gi| {
                if (col >= effective_width) break;
                const is_cursor = gi == clamped_cursor and self.show_cursor and !use_placeholder;
                if (is_cursor) cursor_col = col;
                window.writeCell(col, row, .{
                    .char = .{ .grapheme = display_text[g.byte_start..g.byte_end], .width = @intCast(g.width) },
                    .style = if (is_cursor) self.cursor_style else text_style,
                });
                col += @intCast(g.width);
            }

            if (self.show_cursor and !use_placeholder and cursor_col < effective_width) {
                const g = if (clamped_cursor < graphemes.items.len)
                    graphemes.items[clamped_cursor]
                else if (graphemes.items.len > 0)
                    graphemes.items[graphemes.items.len - 1]
                else
                    null;
                if (g) |grapheme| {
                    window.writeCell(cursor_col, row, .{
                        .char = .{ .grapheme = display_text[grapheme.byte_start..grapheme.byte_end], .width = @intCast(grapheme.width) },
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
