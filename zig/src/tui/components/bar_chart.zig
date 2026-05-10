const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");

pub const Bar = struct {
    value: u64,
    label: []const u8 = "",
    style: vaxis.Cell.Style = .{},
};

pub const BarChart = struct {
    bars: []const Bar,
    max: ?u64 = null,
    bar_width: u16 = 1,
    bar_gap: u16 = 1,
    style: vaxis.Cell.Style = .{},
    direction: Direction = .vertical,

    pub const Direction = enum {
        vertical,
        horizontal,
    };

    pub fn drawComponent(self: *const BarChart) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const BarChart,
        window: vaxis.Window,
        _: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (window.height == 0 or window.width == 0 or self.bars.len == 0) {
            return .{ .width = 0, .height = 0 };
        }

        const max_value = if (self.max) |m| @max(m, 1) else computeMax(self.bars);

        switch (self.direction) {
            .vertical => return self.drawVertical(window, max_value),
            .horizontal => return self.drawHorizontal(window, max_value),
        }
    }

    fn drawVertical(
        self: *const BarChart,
        window: vaxis.Window,
        max_value: u64,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const height = @as(usize, window.height);
        const total_bar_width = self.bar_width + self.bar_gap;
        var x: u16 = 0;

        for (self.bars) |bar| {
            if (x + self.bar_width > window.width) break;
            const scaled = if (max_value == 0) 0 else (bar.value * height) / max_value;
            const bar_style = if (bar.style.fg != .default or bar.style.bg != .default) bar.style else self.style;

            for (0..height) |row_from_top| {
                const row: u16 = @intCast(height - 1 - row_from_top);
                const is_filled = row_from_top < scaled;
                for (0..self.bar_width) |dx| {
                    const col = x + @as(u16, @intCast(dx));
                    if (col >= window.width) break;
                    window.writeCell(col, row, .{
                        .char = .{ .grapheme = if (is_filled) "█" else " ", .width = 1 },
                        .style = bar_style,
                    });
                }
            }
            x += total_bar_width;
        }

        return .{
            .width = @min(x, window.width),
            .height = window.height,
        };
    }

    fn drawHorizontal(
        self: *const BarChart,
        window: vaxis.Window,
        max_value: u64,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const width = @as(usize, window.width);
        const total_bar_height = self.bar_width + self.bar_gap;
        var y: u16 = 0;

        for (self.bars) |bar| {
            if (y + self.bar_width > window.height) break;
            const scaled = if (max_value == 0) 0 else (bar.value * width) / max_value;
            const bar_style = if (bar.style.fg != .default or bar.style.bg != .default) bar.style else self.style;

            for (0..self.bar_width) |dy| {
                const row = y + @as(u16, @intCast(dy));
                if (row >= window.height) break;
                for (0..width) |col| {
                    const is_filled = col < scaled;
                    window.writeCell(@intCast(col), row, .{
                        .char = .{ .grapheme = if (is_filled) "█" else " ", .width = 1 },
                        .style = bar_style,
                    });
                }
            }
            y += total_bar_height;
        }

        return .{
            .width = window.width,
            .height = @min(y, window.height),
        };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const BarChart = @ptrCast(@alignCast(ptr));
        return try self.draw(window, ctx);
    }
};

fn computeMax(bars: []const Bar) u64 {
    var max_val: u64 = 1;
    for (bars) |bar| {
        if (bar.value > max_val) max_val = bar.value;
    }
    return max_val;
}

test "bar chart renders vertical bars" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 4,
        .cols = 5,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const chart = BarChart{
        .bars = &.{
            .{ .value = 2 },
            .{ .value = 4 },
        },
        .bar_width = 1,
        .bar_gap = 1,
    };

    const window = draw_mod.rootWindow(&screen);
    window.clear();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try chart.draw(window, .{ .window = window, .arena = arena.allocator() });

    const top = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(" ", top.char.grapheme);

    const bottom = screen.readCell(0, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("█", bottom.char.grapheme);
}

test "bar chart renders horizontal bars" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 6,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const chart = BarChart{
        .bars = &.{
            .{ .value = 3 },
            .{ .value = 6 },
        },
        .direction = .horizontal,
        .bar_width = 1,
        .bar_gap = 0,
    };

    const window = draw_mod.rootWindow(&screen);
    window.clear();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try chart.draw(window, .{ .window = window, .arena = arena.allocator() });

    const mid = screen.readCell(2, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("█", mid.char.grapheme);

    const end = screen.readCell(5, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("█", end.char.grapheme);
}

test "bar chart empty bars returns zero size" {
    const chart = BarChart{ .bars = &.{} };
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
    const size = try chart.draw(window, .{ .window = window, .arena = arena.allocator() });
    try std.testing.expectEqual(@as(u16, 0), size.width);
}
