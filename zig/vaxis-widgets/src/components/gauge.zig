const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");

pub const Gauge = struct {
    ratio: f64 = 0,
    label: ?[]const u8 = null,
    style: vaxis.Cell.Style = .{},
    gauge_style: vaxis.Cell.Style = .{},
    use_unicode: bool = false,

    pub fn drawComponent(self: *const Gauge) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn draw(
        self: *const Gauge,
        window: vaxis.Window,
        _: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (window.height == 0 or window.width == 0) return .{ .width = 0, .height = 0 };

        const clamped_ratio = std.math.clamp(self.ratio, 0.0, 1.0);
        const width = @as(usize, window.width);
        const filled_width_f = @as(f64, @floatFromInt(width)) * clamped_ratio;
        const end = if (self.use_unicode)
            @as(u16, @intFromFloat(@floor(filled_width_f)))
        else
            @as(u16, @intFromFloat(@round(filled_width_f)));

        // background fill
        for (0..@as(usize, window.height)) |row| {
            for (0..width) |col| {
                window.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = self.style,
                });
            }
        }

        // gauge fill
        for (0..@as(usize, window.height)) |row| {
            for (0..end) |col| {
                window.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = "█", .width = 1 },
                    .style = self.gauge_style,
                });
            }
        }

        // unicode fractional block
        if (self.use_unicode and clamped_ratio < 1.0 and end < window.width) {
            const frac = filled_width_f - @floor(filled_width_f);
            const symbol = unicodeBlockSymbol(frac);
            for (0..@as(usize, window.height)) |row| {
                window.writeCell(end, @intCast(row), .{
                    .char = .{ .grapheme = symbol, .width = 1 },
                    .style = self.gauge_style,
                });
            }
        }

        // label (centered)
        const label_text = self.label orelse label: {
            var buf: [16]u8 = undefined;
            const percent = @as(u16, @intFromFloat(@round(clamped_ratio * 100.0)));
            const s = std.fmt.bufPrint(&buf, "{d}%", .{percent}) catch "0%";
            break :label s;
        };
        const label_width = ansi.visibleWidth(label_text);
        if (label_width <= width) {
            const label_col = (width - label_width) / 2;
            const label_row = @as(usize, window.height) / 2;
            var col: u16 = @intCast(label_col);
            var index: usize = 0;
            while (index < label_text.len and col < window.width) {
                const cluster = ansi.nextDisplayCluster(label_text, index);
                if (cluster.end <= index) break;
                if (cluster.width == 0) {
                    index = cluster.end;
                    continue;
                }
                if (@as(usize, col) + cluster.width > window.width) break;
                const is_filled = @as(usize, col) < end or
                    (self.use_unicode and @as(usize, col) == end and clamped_ratio > 0);
                const bg = self.gauge_style;
                const fg = self.style;
                const cell_style: vaxis.Cell.Style = if (is_filled) .{
                    .fg = bg.fg,
                    .bg = bg.bg,
                } else .{
                    .fg = fg.fg,
                    .bg = fg.bg,
                };
                window.writeCell(col, @intCast(label_row), .{
                    .char = .{
                        .grapheme = label_text[index..cluster.end],
                        .width = @intCast(cluster.width),
                    },
                    .style = cell_style,
                });
                col += @intCast(cluster.width);
                index = cluster.end;
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
        const self: *const Gauge = @ptrCast(@alignCast(ptr));
        return try self.draw(window, ctx);
    }
};

fn unicodeBlockSymbol(frac: f64) []const u8 {
    const level = @as(u16, @intFromFloat(@round(frac * 8.0)));
    return switch (level) {
        1 => "▏",
        2 => "▎",
        3 => "▍",
        4 => "▌",
        5 => "▋",
        6 => "▊",
        7 => "▉",
        8 => "█",
        else => " ",
    };
}

test "gauge renders filled bar" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 1,
        .cols = 10,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const gauge = Gauge{ .ratio = 0.5 };
    const window = draw_mod.rootWindow(&screen);
    window.clear();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try gauge.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    });

    const cell = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("█", cell.char.grapheme);
}

test "gauge renders label" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 1,
        .cols = 10,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const gauge = Gauge{ .ratio = 0.5, .label = "half" };
    const window = draw_mod.rootWindow(&screen);
    window.clear();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try gauge.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    });

    const cell = screen.readCell(3, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("h", cell.char.grapheme);
}

test "gauge empty window returns zero size" {
    const gauge = Gauge{ .ratio = 0.5 };
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
    const size = try gauge.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    });
    try std.testing.expectEqual(@as(u16, 0), size.width);
    try std.testing.expectEqual(@as(u16, 0), size.height);
}
