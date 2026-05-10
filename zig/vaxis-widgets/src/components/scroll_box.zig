const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

/// A generic scrollable container that wraps any component and displays scrollbars.
pub const ScrollBox = struct {
    content: draw_mod.Component,
    scroll_offset_x: usize = 0,
    scroll_offset_y: usize = 0,
    content_width: usize = 0,
    content_height: usize = 0,
    scroll_x: bool = false,
    scroll_y: bool = true,
    scrollbar_width: u16 = 1,
    scrollbar_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },
    scrollbar_thumb_style: vaxis.Cell.Style = .{ .fg = .{ .index = 7 } },

    pub fn drawComponent(self: *const ScrollBox) draw_mod.Component {
        return .{ .ptr = self, .drawFn = drawOpaque };
    }

    pub fn draw(
        self: *const ScrollBox,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        const has_vscroll = self.scroll_y and self.content_height > window.height;
        const has_hscroll = self.scroll_x and self.content_width > window.width;

        const vscroll_width: u16 = if (has_vscroll) self.scrollbar_width else 0;
        const hscroll_height: u16 = if (has_hscroll) self.scrollbar_width else 0;

        const content_w = if (window.width > vscroll_width) window.width - vscroll_width else 0;
        const content_h = if (window.height > hscroll_height) window.height - hscroll_height else 0;

        // Content area
        if (content_w > 0 and content_h > 0) {
            const content_window = window.child(.{
                .width = content_w,
                .height = content_h,
            });
            _ = try self.content.draw(content_window, ctx);
        }

        // Vertical scrollbar
        if (has_vscroll and content_h > 0) {
            const track_h: usize = @intCast(content_h);
            const thumb_h = @max(1, (track_h * track_h) / self.content_height);
            const max_offset = if (self.content_height > track_h) self.content_height - track_h else 0;
            const scroll_ratio = if (max_offset > 0)
                @as(f64, @floatFromInt(@min(self.scroll_offset_y, max_offset))) / @as(f64, @floatFromInt(max_offset))
            else
                0;
            const thumb_y = @as(u16, @intCast(@min(
                max_offset,
                @as(usize, @intFromFloat(scroll_ratio * @as(f64, @floatFromInt(track_h - thumb_h)))),
            )));

            const sb_x: u16 = @intCast(content_w);
            for (0..track_h) |i| {
                const row: u16 = @intCast(i);
                const is_thumb = i >= thumb_y and i < thumb_y + thumb_h;
                window.writeCell(sb_x, row, .{
                    .char = .{ .grapheme = "│", .width = 1 },
                    .style = if (is_thumb) self.scrollbar_thumb_style else self.scrollbar_style,
                });
            }
        }

        // Horizontal scrollbar
        if (has_hscroll and content_w > 0) {
            const track_w: usize = @intCast(content_w);
            const thumb_w = @max(1, (track_w * track_w) / self.content_width);
            const max_offset = if (self.content_width > track_w) self.content_width - track_w else 0;
            const scroll_ratio = if (max_offset > 0)
                @as(f64, @floatFromInt(@min(self.scroll_offset_x, max_offset))) / @as(f64, @floatFromInt(max_offset))
            else
                0;
            const thumb_x = @as(u16, @intCast(@min(
                max_offset,
                @as(usize, @intFromFloat(scroll_ratio * @as(f64, @floatFromInt(track_w - thumb_w)))),
            )));

            const sb_y: u16 = @intCast(content_h);
            for (0..track_w) |i| {
                const col: u16 = @intCast(i);
                const is_thumb = i >= thumb_x and i < thumb_x + thumb_w;
                window.writeCell(col, sb_y, .{
                    .char = .{ .grapheme = "─", .width = 1 },
                    .style = if (is_thumb) self.scrollbar_thumb_style else self.scrollbar_style,
                });
            }
        }

        // Corner
        if (has_vscroll and has_hscroll) {
            window.writeCell(@intCast(content_w), @intCast(content_h), .{
                .char = .{ .grapheme = "┘", .width = 1 },
                .style = self.scrollbar_style,
            });
        }

        return .{ .width = window.width, .height = window.height };
    }

    pub fn scrollDown(self: *ScrollBox, lines: usize) void {
        self.scroll_offset_y += lines;
    }

    pub fn scrollUp(self: *ScrollBox, lines: usize) void {
        self.scroll_offset_y = if (self.scroll_offset_y > lines) self.scroll_offset_y - lines else 0;
    }

    pub fn scrollRight(self: *ScrollBox, cols: usize) void {
        self.scroll_offset_x += cols;
    }

    pub fn scrollLeft(self: *ScrollBox, cols: usize) void {
        self.scroll_offset_x = if (self.scroll_offset_x > cols) self.scroll_offset_x - cols else 0;
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const ScrollBox = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "scroll box renders content with vertical scrollbar" {
    const StaticText = struct {
        text: []const u8,
        fn drawComponent(self: *const @This()) draw_mod.Component {
            return .{ .ptr = self, .drawFn = draw };
        }
        fn draw(ptr: *const anyopaque, w: vaxis.Window, _: draw_mod.DrawContext) std.mem.Allocator.Error!draw_mod.Size {
            const s: *const @This() = @ptrCast(@alignCast(ptr));
            _ = w.printSegment(.{ .text = s.text }, .{ .wrap = .none });
            return .{ .width = w.width, .height = 1 };
        }
    };

    const content = StaticText{ .text = "Hello World" };
    const box = ScrollBox{
        .content = content.drawComponent(),
        .content_height = 10,
        .scroll_y = true,
    };

    var screen = try test_helpers.renderToScreen(box.drawComponent(), 15, 5);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "H", .{});
    try test_helpers.expectCell(&screen, 14, 0, "│", .{ .fg = .{ .index = 7 } });
}

test "scroll box scroll navigation" {
    var box = ScrollBox{ .content = undefined, .content_height = 20 };
    box.scrollDown(5);
    try std.testing.expectEqual(@as(usize, 5), box.scroll_offset_y);
    box.scrollUp(3);
    try std.testing.expectEqual(@as(usize, 2), box.scroll_offset_y);
    box.scrollUp(10);
    try std.testing.expectEqual(@as(usize, 0), box.scroll_offset_y);
}
