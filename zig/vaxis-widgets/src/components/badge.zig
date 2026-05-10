const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Badge = struct {
    count: usize,
    style: vaxis.Cell.Style = .{ .fg = .{ .index = 255 }, .bg = .{ .index = 196 } },
    empty_style: vaxis.Cell.Style = .{ .dim = true },
    max_display: usize = 99,
    overflow_text: []const u8 = "+",

    pub fn drawComponent(self: *const Badge) draw_mod.Component {
        return .{ .ptr = self, .drawFn = drawOpaque };
    }

    pub fn draw(
        self: *const Badge,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        window.clear();

        if (self.count == 0) {
            window.writeCell(0, 0, .{ .char = .{ .grapheme = "○", .width = 1 }, .style = self.empty_style });
            return .{ .width = 1, .height = 1 };
        }

        var buf: [8]u8 = undefined;
        const text = if (self.count > self.max_display)
            std.fmt.bufPrint(&buf, "{d}{s}", .{ self.max_display, self.overflow_text }) catch "99+"
        else
            std.fmt.bufPrint(&buf, "{d}", .{self.count}) catch "0";

        var col: u16 = 0;
        var idx: usize = 0;
        while (idx < text.len and col < window.width) {
            window.writeCell(col, 0, .{
                .char = .{ .grapheme = text[idx .. idx + 1], .width = 1 },
                .style = self.style,
            });
            col += 1;
            idx += 1;
        }

        return .{ .width = col, .height = 1 };
    }

    pub fn increment(self: *Badge) void {
        self.count += 1;
    }

    pub fn decrement(self: *Badge) void {
        if (self.count > 0) self.count -= 1;
    }

    pub fn clear(self: *Badge) void {
        self.count = 0;
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Badge = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "badge renders count and overflow" {
    const b1 = Badge{ .count = 5 };
    var screen1 = try test_helpers.renderToScreen(b1.drawComponent(), 4, 1);
    defer screen1.deinit(std.testing.allocator);
    try test_helpers.expectCell(&screen1, 0, 0, "5", .{ .bg = .{ .index = 196 } });

    const b2 = Badge{ .count = 0 };
    var screen2 = try test_helpers.renderToScreen(b2.drawComponent(), 4, 1);
    defer screen2.deinit(std.testing.allocator);
    try test_helpers.expectCell(&screen2, 0, 0, "○", .{ .dim = true });

    const b3 = Badge{ .count = 150 };
    var screen3 = try test_helpers.renderToScreen(b3.drawComponent(), 6, 1);
    defer screen3.deinit(std.testing.allocator);
    const rendered = try test_helpers.screenToString(&screen3);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "99+") != null);
}
