const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");

/// A compact single-line progress bar.
pub const LineGauge = struct {
    ratio: f64 = 0,
    label: ?[]const u8 = null,
    filled_symbol: []const u8 = "█",
    unfilled_symbol: []const u8 = "░",
    filled_style: vaxis.Cell.Style = .{},
    unfilled_style: vaxis.Cell.Style = .{},

    pub fn drawComponent(self: *const LineGauge) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn draw(
        self: *const LineGauge,
        window: vaxis.Window,
        _: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (window.height == 0 or window.width == 0) return .{ .width = 0, .height = 0 };

        const clamped = std.math.clamp(self.ratio, 0.0, 1.0);
        const width = @as(usize, window.width);
        const filled = @as(u16, @intFromFloat(@round(clamped * @as(f64, @floatFromInt(width)))));

        const label_text = self.label orelse label: {
            var buf: [16]u8 = undefined;
            const pct = @as(u16, @intFromFloat(@round(clamped * 100.0)));
            const s = std.fmt.bufPrint(&buf, "{d}%", .{pct}) catch "0%";
            break :label s;
        };

        var col: u16 = 0;
        var index: usize = 0;
        while (index < label_text.len and col < window.width) {
            const cluster = ansi.nextDisplayCluster(label_text, index);
            if (cluster.end <= index) break;
            if (cluster.width == 0) {
                index = cluster.end;
                continue;
            }
            if (@as(usize, col) + cluster.width > window.width) break;
            window.writeCell(col, 0, .{
                .char = .{
                    .grapheme = label_text[index..cluster.end],
                    .width = @intCast(cluster.width),
                },
                .style = if (col < filled) self.filled_style else self.unfilled_style,
            });
            col += @intCast(cluster.width);
            index = cluster.end;
        }

        const bar_start = col;
        for (bar_start..width) |c| {
            const is_filled = c < filled;
            window.writeCell(@intCast(c), 0, .{
                .char = .{
                    .grapheme = if (is_filled) self.filled_symbol else self.unfilled_symbol,
                    .width = 1,
                },
                .style = if (is_filled) self.filled_style else self.unfilled_style,
            });
        }

        return .{ .width = window.width, .height = 1 };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const LineGauge = @ptrCast(@alignCast(ptr));
        return try self.draw(window, ctx);
    }
};

test "line gauge renders filled and unfilled parts" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 1,
        .cols = 10,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const gauge = LineGauge{ .ratio = 0.5 };
    const window = draw_mod.rootWindow(&screen);
    window.clear();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try gauge.draw(window, .{ .window = window, .arena = arena.allocator() });

    const first = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("5", first.char.grapheme);

    const filled = screen.readCell(3, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("█", filled.char.grapheme);

    const unfilled = screen.readCell(5, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("░", unfilled.char.grapheme);
}

test "line gauge empty window returns zero size" {
    const gauge = LineGauge{ .ratio = 0.5 };
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
    const size = try gauge.draw(window, .{ .window = window, .arena = arena.allocator() });
    try std.testing.expectEqual(@as(u16, 0), size.width);
}
