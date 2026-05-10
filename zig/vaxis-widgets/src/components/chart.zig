const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Dataset = struct {
    data: []const f64,
    style: vaxis.Cell.Style = .{},
    symbol: []const u8 = "•",
    line_style: LineStyle = .scatter,

    pub const LineStyle = enum {
        scatter,
        line,
    };
};

pub const Chart = struct {
    datasets: []const Dataset,
    x_axis_label: []const u8 = "",
    y_axis_label: []const u8 = "",
    style: vaxis.Cell.Style = .{},
    axis_style: vaxis.Cell.Style = .{ .dim = true },
    show_axes: bool = true,

    pub fn drawComponent(self: *const Chart) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn draw(
        self: *const Chart,
        window: vaxis.Window,
        _: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (window.width == 0 or window.height == 0 or self.datasets.len == 0) {
            return .{ .width = window.width, .height = 0 };
        }

        window.clear();

        // Find min/max values across all datasets
        var min_value: f64 = std.math.inf(f64);
        var max_value: f64 = -std.math.inf(f64);
        var max_len: usize = 0;
        for (self.datasets) |dataset| {
            for (dataset.data) |value| {
                min_value = @min(min_value, value);
                max_value = @max(max_value, value);
            }
            max_len = @max(max_len, dataset.data.len);
        }

        if (max_len == 0) return .{ .width = window.width, .height = 0 };

        const range = max_value - min_value;
        const effective_range = if (range == 0) 1.0 else range;

        const axis_height: u16 = if (self.show_axes) 1 else 0;
        const plot_height = if (window.height > axis_height) window.height - axis_height else 0;

        // Draw axes
        if (self.show_axes and plot_height > 0) {
            for (0..window.width) |x| {
                window.writeCell(@intCast(x), plot_height, .{
                    .char = .{ .grapheme = "─", .width = 1 },
                    .style = self.axis_style,
                });
            }
        }

        // Draw datasets
        for (self.datasets) |dataset| {
            if (dataset.data.len == 0) continue;

            for (dataset.data, 0..) |value, index| {
                const x = if (max_len <= 1)
                    @as(u16, 0)
                else
                    @as(u16, @intCast((index * @as(usize, window.width -| 1)) / (max_len - 1)));
                const normalized = (value - min_value) / effective_range;
                const y = if (plot_height <= 1)
                    @as(u16, 0)
                else
                    @as(u16, @intCast(@min(
                        @as(usize, plot_height - 1),
                        @as(usize, @intFromFloat(@floor(normalized * @as(f64, @floatFromInt(plot_height - 1))))),
                    )));
                const plot_y = if (plot_height > 0) plot_height - 1 - y else 0;

                if (x < window.width and plot_y < window.height) {
                    window.writeCell(x, plot_y, .{
                        .char = .{ .grapheme = dataset.symbol, .width = 1 },
                        .style = dataset.style,
                    });
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
        const self: *const Chart = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "chart renders dataset points" {
    const chart = Chart{
        .datasets = &[_]Dataset{
            .{
                .data = &[_]f64{ 0.0, 0.5, 1.0 },
                .symbol = "•",
            },
        },
    };

    var screen = try test_helpers.renderToScreen(chart.drawComponent(), 10, 5);
    defer screen.deinit(std.testing.allocator);

    // Bottom point (value 0.0) should be near the axis
    const bottom = screen.readCell(0, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("•", bottom.char.grapheme);

    // Top point (value 1.0) should be near the top
    const top = screen.readCell(9, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("•", top.char.grapheme);
}

test "chart draws axis line when enabled" {
    const chart = Chart{
        .datasets = &[_]Dataset{
            .{ .data = &[_]f64{ 0.5 } },
        },
        .show_axes = true,
    };

    var screen = try test_helpers.renderToScreen(chart.drawComponent(), 5, 3);
    defer screen.deinit(std.testing.allocator);

    const axis = screen.readCell(0, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("─", axis.char.grapheme);
}
