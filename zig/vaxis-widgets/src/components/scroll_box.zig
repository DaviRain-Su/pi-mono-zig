const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");
const scroll_mod = @import("../scroll.zig");
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

        const layout = self.scrollLayout(window);
        const content_w = layout.content_w;
        const content_h = layout.content_h;

        // Content area
        if (content_w > 0 and content_h > 0) {
            const viewport_window = window.child(.{
                .width = content_w,
                .height = content_h,
            });
            const render_w = @max(@as(usize, content_w), if (self.content_width > 0) self.content_width else @as(usize, content_w));
            const render_h = @max(@as(usize, content_h), if (self.content_height > 0) self.content_height else @as(usize, content_h));
            var screen = try vaxis.Screen.init(ctx.arena, .{
                .rows = @intCast(render_h),
                .cols = @intCast(render_w),
                .x_pixel = 0,
                .y_pixel = 0,
            });
            defer screen.deinit(ctx.arena);

            const content_window = draw_mod.rootWindow(&screen);
            content_window.clear();
            _ = try self.content.draw(content_window, ctx);

            blitScrolled(&screen, viewport_window, layout.offset_x, layout.offset_y);
        }

        // Vertical scrollbar
        if (layout.has_vscroll and content_h > 0) {
            const track_h: usize = @intCast(content_h);
            const thumb = scroll_mod.thumb(track_h, self.content_height, track_h, layout.offset_y);

            const sb_x: u16 = @intCast(content_w);
            for (0..track_h) |i| {
                const row: u16 = @intCast(i);
                const is_thumb = i >= thumb.start and i < thumb.start + thumb.length;
                window.writeCell(sb_x, row, .{
                    .char = .{ .grapheme = "│", .width = 1 },
                    .style = if (is_thumb) self.scrollbar_thumb_style else self.scrollbar_style,
                });
            }
        }

        // Horizontal scrollbar
        if (layout.has_hscroll and content_w > 0) {
            const track_w: usize = @intCast(content_w);
            const thumb = scroll_mod.thumb(track_w, self.content_width, track_w, layout.offset_x);

            const sb_y: u16 = @intCast(content_h);
            for (0..track_w) |i| {
                const col: u16 = @intCast(i);
                const is_thumb = i >= thumb.start and i < thumb.start + thumb.length;
                window.writeCell(col, sb_y, .{
                    .char = .{ .grapheme = "─", .width = 1 },
                    .style = if (is_thumb) self.scrollbar_thumb_style else self.scrollbar_style,
                });
            }
        }

        // Corner
        if (layout.has_vscroll and layout.has_hscroll) {
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

    const ScrollLayout = struct {
        has_vscroll: bool,
        has_hscroll: bool,
        content_w: u16,
        content_h: u16,
        offset_x: usize,
        offset_y: usize,
    };

    fn scrollLayout(self: *const ScrollBox, window: vaxis.Window) ScrollLayout {
        var has_vscroll = self.scroll_y and self.content_height > @as(usize, window.height);
        var has_hscroll = self.scroll_x and self.content_width > @as(usize, window.width);

        var content_w = reduced(window.width, if (has_vscroll) self.scrollbar_width else 0);
        var content_h = reduced(window.height, if (has_hscroll) self.scrollbar_width else 0);

        if (!has_vscroll and self.scroll_y and self.content_height > @as(usize, content_h)) {
            has_vscroll = true;
            content_w = reduced(window.width, self.scrollbar_width);
        }
        if (!has_hscroll and self.scroll_x and self.content_width > @as(usize, content_w)) {
            has_hscroll = true;
            content_h = reduced(window.height, self.scrollbar_width);
        }

        return .{
            .has_vscroll = has_vscroll,
            .has_hscroll = has_hscroll,
            .content_w = content_w,
            .content_h = content_h,
            .offset_x = scroll_mod.clampOffset(self.content_width, content_w, self.scroll_offset_x),
            .offset_y = scroll_mod.clampOffset(self.content_height, content_h, self.scroll_offset_y),
        };
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

fn reduced(value: u16, amount: u16) u16 {
    return if (value > amount) value - amount else 0;
}

fn blitScrolled(source: *vaxis.Screen, destination: vaxis.Window, offset_x: usize, offset_y: usize) void {
    const row_count = @min(@as(usize, destination.height), @as(usize, source.height) -| offset_y);
    const col_count = @min(@as(usize, destination.width), @as(usize, source.width) -| offset_x);
    for (0..row_count) |row| {
        for (0..col_count) |col| {
            const cell = source.readCell(@intCast(offset_x + col), @intCast(offset_y + row)) orelse continue;
            destination.writeCell(@intCast(col), @intCast(row), cell);
        }
    }
}

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

test "scroll box applies vertical scroll offset to content" {
    const Lines = struct {
        lines: []const []const u8,
        fn drawComponent(self: *const @This()) draw_mod.Component {
            return .{ .ptr = self, .drawFn = draw };
        }
        fn draw(ptr: *const anyopaque, w: vaxis.Window, _: draw_mod.DrawContext) std.mem.Allocator.Error!draw_mod.Size {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            for (self.lines, 0..) |line, row| {
                if (row >= w.height) break;
                _ = w.printSegment(.{ .text = line }, .{ .wrap = .none, .row_offset = @intCast(row) });
            }
            return .{ .width = w.width, .height = @intCast(self.lines.len) };
        }
    };

    const lines = Lines{ .lines = &.{ "one", "two", "three" } };
    const box = ScrollBox{
        .content = lines.drawComponent(),
        .content_height = 3,
        .scroll_offset_y = 1,
        .scroll_y = true,
    };

    var screen = try test_helpers.renderToScreen(box.drawComponent(), 8, 2);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "t", .{});
    try test_helpers.expectCell(&screen, 0, 1, "t", .{});
}

test "scroll box applies horizontal scroll offset to content" {
    const Text = struct {
        text: []const u8,
        fn drawComponent(self: *const @This()) draw_mod.Component {
            return .{ .ptr = self, .drawFn = draw };
        }
        fn draw(ptr: *const anyopaque, w: vaxis.Window, _: draw_mod.DrawContext) std.mem.Allocator.Error!draw_mod.Size {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            _ = w.printSegment(.{ .text = self.text }, .{ .wrap = .none });
            return .{ .width = @intCast(self.text.len), .height = 1 };
        }
    };

    const text = Text{ .text = "abcdef" };
    const box = ScrollBox{
        .content = text.drawComponent(),
        .content_width = 6,
        .scroll_offset_x = 2,
        .scroll_x = true,
        .scroll_y = false,
    };

    var screen = try test_helpers.renderToScreen(box.drawComponent(), 4, 2);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "c", .{});
    try test_helpers.expectCell(&screen, 1, 0, "d", .{});
}
