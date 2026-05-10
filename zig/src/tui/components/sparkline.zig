const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");

pub const Sparkline = struct {
    data: []const u64,
    max: ?u64 = null,
    style: vaxis.Cell.Style = .{},

    pub fn drawComponent(self: *const Sparkline) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Sparkline,
        window: vaxis.Window,
        _: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (window.height == 0 or window.width == 0 or self.data.len == 0) {
            return .{ .width = 0, .height = 0 };
        }

        const max_value = if (self.max) |m| @max(m, 1) else computeMax(self.data);
        const height = @as(usize, window.height);
        const levels = height * 8;

        for (0..@min(self.data.len, @as(usize, window.width))) |i| {
            const value = self.data[i];
            const scaled = if (max_value == 0) 0 else (value * levels) / max_value;
            const col: u16 = @intCast(i);

            for (0..height) |row_from_top| {
                const row: u16 = @intCast(height - 1 - row_from_top);
                const threshold = (row_from_top + 1) * 8;
                const actual = @min(@max(scaled + 8 -| threshold, 0), 8);
                const symbol = barSymbol(actual);

                window.writeCell(col, row, .{
                    .char = .{ .grapheme = symbol, .width = 1 },
                    .style = self.style,
                });
            }
        }

        return .{
            .width = @intCast(@min(self.data.len, @as(usize, window.width))),
            .height = window.height,
        };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Sparkline = @ptrCast(@alignCast(ptr));
        return try self.draw(window, ctx);
    }
};

fn computeMax(data: []const u64) u64 {
    var max_val: u64 = 1;
    for (data) |v| {
        if (v > max_val) max_val = v;
    }
    return max_val;
}

fn barSymbol(level: u64) []const u8 {
    return switch (level) {
        0 => " ",
        1 => "▁",
        2 => "▂",
        3 => "▃",
        4 => "▄",
        5 => "▅",
        6 => "▆",
        7 => "▇",
        else => "█",
    };
}

test "sparkline renders bars" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 1,
        .cols = 9,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const sparkline = Sparkline{
        .data = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 },
    };

    const window = draw_mod.rootWindow(&screen);
    window.clear();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try sparkline.draw(window, .{ .window = window, .arena = arena.allocator() });

    const first = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(" ", first.char.grapheme);

    const last = screen.readCell(8, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("█", last.char.grapheme);
}

test "sparkline respects max" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 1,
        .cols = 3,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const sparkline = Sparkline{
        .data = &.{ 5, 10, 15 },
        .max = 20,
    };

    const window = draw_mod.rootWindow(&screen);
    window.clear();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try sparkline.draw(window, .{ .window = window, .arena = arena.allocator() });

    const mid = screen.readCell(1, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("▄", mid.char.grapheme);
}

test "sparkline empty data returns zero size" {
    const sparkline = Sparkline{ .data = &.{} };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1,
        .cols = 1,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);

    const window = draw_mod.rootWindow(&screen);
    const size = try sparkline.draw(window, .{ .window = window, .arena = arena.allocator() });
    try std.testing.expectEqual(@as(u16, 0), size.width);
}
