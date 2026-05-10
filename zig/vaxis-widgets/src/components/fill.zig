const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

/// A widget that fills its render area with a single repeated symbol and style.
pub const Fill = struct {
    symbol: []const u8 = " ",
    style: vaxis.Cell.Style = .{},

    pub fn init(symbol: []const u8) Fill {
        return .{ .symbol = symbol };
    }

    pub fn drawComponent(self: *const Fill) draw_mod.Component {
        return .{ .ptr = self, .drawFn = drawOpaque };
    }

    pub fn draw(
        self: *const Fill,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        if (window.width == 0 or window.height == 0) {
            return .{ .width = window.width, .height = window.height };
        }

        // Use window.fill if symbol is a single ASCII space
        if (self.symbol.len == 1 and self.symbol[0] == ' ') {
            window.fill(.{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = self.style,
            });
            return .{ .width = window.width, .height = window.height };
        }

        for (0..window.height) |row| {
            for (0..window.width) |col| {
                window.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = self.symbol, .width = 1 },
                    .style = self.style,
                });
            }
        }

        return .{ .width = window.width, .height = window.height };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Fill = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "fill paints area with symbol and style" {
    const fill = Fill{ .symbol = "X", .style = .{ .fg = .{ .index = 196 } } };
    var screen = try test_helpers.renderToScreen(fill.drawComponent(), 5, 3);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "X", .{ .fg = .{ .index = 196 } });
    try test_helpers.expectCell(&screen, 4, 2, "X", .{ .fg = .{ .index = 196 } });
}

test "fill with space uses window.fill" {
    const fill = Fill{ .symbol = " ", .style = .{ .bg = .{ .index = 240 } } };
    var screen = try test_helpers.renderToScreen(fill.drawComponent(), 3, 2);
    defer screen.deinit(std.testing.allocator);

    const cell = screen.readCell(1, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(" ", cell.char.grapheme);
    try std.testing.expectEqual(@as(?vaxis.Color, .{ .index = 240 }), cell.style.bg);
}
