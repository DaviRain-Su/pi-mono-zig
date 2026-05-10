const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");

/// Fills the entire window area with blank cells using the given style.
pub const Clear = struct {
    style: vaxis.Cell.Style = .{},

    pub fn drawComponent(self: *const Clear) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn draw(
        self: *const Clear,
        window: vaxis.Window,
        _: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const blank: vaxis.Cell = .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = self.style,
        };
        for (0..@as(usize, window.height)) |row| {
            for (0..@as(usize, window.width)) |col| {
                window.writeCell(@intCast(col), @intCast(row), blank);
            }
        }
        return .{
            .width = window.width,
            .height = window.height,
        };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Clear = @ptrCast(@alignCast(ptr));
        return try self.draw(window, ctx);
    }
};

test "clear fills window with spaces" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 2,
        .cols = 3,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const clear = Clear{ .style = .{ .reverse = true } };
    const window = draw_mod.rootWindow(&screen);
    window.clear();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try clear.draw(window, .{ .window = window, .arena = arena.allocator() });

    const cell = screen.readCell(1, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(" ", cell.char.grapheme);
    try std.testing.expect(cell.style.reverse);
}

test "clear empty window returns zero size" {
    const clear = Clear{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1,
        .cols = 1,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);

    const window = draw_mod.rootWindow(&screen).child(.{ .width = 0, .height = 0 });
    const size = try clear.draw(window, .{ .window = window, .arena = arena.allocator() });
    try std.testing.expectEqual(@as(u16, 0), size.width);
    try std.testing.expectEqual(@as(u16, 0), size.height);
}
