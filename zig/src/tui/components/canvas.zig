const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Point = struct {
    x: f64,
    y: f64,
    symbol: []const u8 = "•",
    style: vaxis.Cell.Style = .{},
};

pub const Line = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    symbol: []const u8 = "─",
    style: vaxis.Cell.Style = .{},
};

pub const Label = struct {
    x: f64,
    y: f64,
    text: []const u8,
    style: vaxis.Cell.Style = .{},
};

pub const Canvas = struct {
    x_bounds: [2]f64 = .{ 0, 1 },
    y_bounds: [2]f64 = .{ 0, 1 },
    points: []const Point = &.{},
    lines: []const Line = &.{},
    labels: []const Label = &.{},
    background_style: vaxis.Cell.Style = .{},
    x_labels: []const []const u8 = &.{},
    y_labels: []const []const u8 = &.{},
    label_style: vaxis.Cell.Style = .{ .dim = true },

    pub fn drawComponent(self: *const Canvas) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Canvas,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        if (window.width == 0 or window.height == 0) {
            return .{ .width = window.width, .height = 0 };
        }

        window.fill(.{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = self.background_style,
        });

        const x_range = self.x_bounds[1] - self.x_bounds[0];
        const y_range = self.y_bounds[1] - self.y_bounds[0];
        const eff_x_range = if (x_range == 0) 1.0 else x_range;
        const eff_y_range = if (y_range == 0) 1.0 else y_range;

        // Draw points
        for (self.points) |point| {
            const col = mapXToCol(point.x, self.x_bounds[0], eff_x_range, window.width);
            const row = mapYToRow(point.y, self.y_bounds[0], eff_y_range, window.height);
            if (col < window.width and row < window.height) {
                window.writeCell(col, row, .{
                    .char = .{ .grapheme = point.symbol, .width = 1 },
                    .style = point.style,
                });
            }
        }

        // Draw lines (Bresenham-like)
        for (self.lines) |line| {
            const x1 = mapXToCol(line.x1, self.x_bounds[0], eff_x_range, window.width);
            const y1 = mapYToRow(line.y1, self.y_bounds[0], eff_y_range, window.height);
            const x2 = mapXToCol(line.x2, self.x_bounds[0], eff_x_range, window.width);
            const y2 = mapYToRow(line.y2, self.y_bounds[0], eff_y_range, window.height);
            try drawLine(window, x1, y1, x2, y2, line.symbol, line.style);
        }

        // Draw labels
        for (self.labels) |label| {
            const col = mapXToCol(label.x, self.x_bounds[0], eff_x_range, window.width);
            const row = mapYToRow(label.y, self.y_bounds[0], eff_y_range, window.height);
            if (col < window.width and row < window.height) {
                var c = col;
                var idx: usize = 0;
                while (idx < label.text.len and c < window.width) {
                    window.writeCell(c, row, .{
                        .char = .{ .grapheme = label.text[idx..idx + 1], .width = 1 },
                        .style = label.style,
                    });
                    c += 1;
                    idx += 1;
                }
            }
        }

        return .{ .width = window.width, .height = window.height };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Canvas = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

fn mapXToCol(x: f64, x_min: f64, x_range: f64, width: u16) u16 {
    const normalized = (x - x_min) / x_range;
    const clamped = std.math.clamp(normalized, 0.0, 1.0);
    return @intCast(@min(@as(usize, width -| 1), @as(usize, @intFromFloat(@floor(clamped * @as(f64, @floatFromInt(width -| 1)))))));
}

fn mapYToRow(y: f64, y_min: f64, y_range: f64, height: u16) u16 {
    const normalized = (y - y_min) / y_range;
    const clamped = std.math.clamp(normalized, 0.0, 1.0);
    const row_from_bottom = @min(@as(usize, height -| 1), @as(usize, @intFromFloat(@floor(clamped * @as(f64, @floatFromInt(height -| 1))))));
    return @intCast((height -| 1) - @as(u16, @intCast(row_from_bottom)));
}

fn drawLine(
    window: vaxis.Window,
    x1: u16,
    y1: u16,
    x2: u16,
    y2: u16,
    symbol: []const u8,
    style: vaxis.Cell.Style,
) std.mem.Allocator.Error!void {
    const dx: i32 = @as(i32, x2) - @as(i32, x1);
    const dy: i32 = @as(i32, y2) - @as(i32, y1);
    const steps = @max(@abs(dx), @abs(dy));
    if (steps == 0) {
        if (x1 < window.width and y1 < window.height) {
            window.writeCell(x1, y1, .{
                .char = .{ .grapheme = symbol, .width = 1 },
                .style = style,
            });
        }
        return;
    }

    for (0..@as(u16, @intCast(steps + 1))) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const x = @as(u16, @intCast(@min(@as(u16, @intCast(@abs(x1) + @as(u16, @intFromFloat(t * @as(f64, @floatFromInt(dx)))))), window.width -| 1)));
        const y = @as(u16, @intCast(@min(@as(u16, @intCast(@abs(y1) + @as(u16, @intFromFloat(t * @as(f64, @floatFromInt(dy)))))), window.height -| 1)));
        if (x < window.width and y < window.height) {
            window.writeCell(x, y, .{
                .char = .{ .grapheme = symbol, .width = 1 },
                .style = style,
            });
        }
    }
}

test "canvas maps points to window coordinates" {
    const allocator = std.testing.allocator;

    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 5,
        .cols = 10,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = draw_mod.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const canvas = Canvas{
        .x_bounds = .{ 0, 10 },
        .y_bounds = .{ 0, 10 },
        .points = &[_]Point{
            .{ .x = 0, .y = 0 },
            .{ .x = 10, .y = 10 },
            .{ .x = 5, .y = 5 },
        },
    };

    _ = try canvas.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    });

    // Bottom-left corner (0,0) maps to bottom row
    const bottom_left = screen.readCell(0, 4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("•", bottom_left.char.grapheme);

    // Top-right corner (10,10) maps to top row
    const top_right = screen.readCell(9, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("•", top_right.char.grapheme);
}

test "canvas draws lines between coordinates" {
    const allocator = std.testing.allocator;

    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 5,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = draw_mod.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const canvas = Canvas{
        .x_bounds = .{ 0, 4 },
        .y_bounds = .{ 0, 2 },
        .lines = &[_]Line{
            .{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 2 },
        },
    };

    _ = try canvas.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    });

    // Line should have multiple points
    const start = screen.readCell(0, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("─", start.char.grapheme);
}

test "canvas draws labels at coordinates" {
    const allocator = std.testing.allocator;

    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 6,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = draw_mod.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const canvas = Canvas{
        .x_bounds = .{ 0, 5 },
        .y_bounds = .{ 0, 2 },
        .labels = &[_]Label{
            .{ .x = 0, .y = 1, .text = "A" },
        },
    };

    _ = try canvas.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    });

    const label = screen.readCell(0, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("A", label.char.grapheme);
}
