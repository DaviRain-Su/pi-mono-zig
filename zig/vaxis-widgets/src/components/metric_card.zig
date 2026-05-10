const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const TrendDirection = enum {
    up,
    down,
    neutral,
};

pub const MetricCard = struct {
    label: []const u8 = "",
    value: []const u8 = "",
    unit: []const u8 = "",
    trend: TrendDirection = .neutral,
    trend_value: []const u8 = "",
    style: vaxis.Cell.Style = .{},
    value_style: vaxis.Cell.Style = .{ .bold = true },
    label_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },
    trend_up_style: vaxis.Cell.Style = .{ .fg = .{ .index = 82 } },
    trend_down_style: vaxis.Cell.Style = .{ .fg = .{ .index = 196 } },
    trend_neutral_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },
    border: bool = true,
    border_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },
    width: usize = 16,
    height: usize = 3,

    pub fn drawComponent(self: *const MetricCard) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn draw(
        self: *const MetricCard,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        const w = @min(self.width, @as(usize, window.width));
        const h = @min(self.height, @as(usize, window.height));
        if (w == 0 or h == 0) return .{ .width = 0, .height = 0 };

        // Border
        if (self.border) {
            for (0..w) |col| {
                window.writeCell(@intCast(col), 0, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = self.border_style });
                window.writeCell(@intCast(col), @intCast(h - 1), .{ .char = .{ .grapheme = "─", .width = 1 }, .style = self.border_style });
            }
            for (0..h) |row| {
                window.writeCell(0, @intCast(row), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = self.border_style });
                window.writeCell(@intCast(w - 1), @intCast(row), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = self.border_style });
            }
            window.writeCell(0, 0, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = self.border_style });
            window.writeCell(@intCast(w - 1), 0, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = self.border_style });
            window.writeCell(0, @intCast(h - 1), .{ .char = .{ .grapheme = "└", .width = 1 }, .style = self.border_style });
            window.writeCell(@intCast(w - 1), @intCast(h - 1), .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = self.border_style });
        }

        const inner_width = if (self.border) w -| 2 else w;
        const inner_height = if (self.border) h -| 2 else h;
        if (inner_width == 0 or inner_height == 0) {
            return .{ .width = @intCast(w), .height = @intCast(h) };
        }

        const inner = window.child(.{
            .x_off = if (self.border) 1 else 0,
            .y_off = if (self.border) 1 else 0,
            .width = @intCast(inner_width),
            .height = @intCast(inner_height),
        });
        inner.clear();

        // Label
        if (self.label.len > 0 and inner.height >= 1) {
            _ = inner.printSegment(.{ .text = self.label, .style = self.label_style }, .{ .wrap = .none });
        }

        // Value
        if (self.value.len > 0 and inner.height >= 2) {
            const value_row = inner.child(.{ .y_off = 1, .height = 1 });
            const full_value = if (self.unit.len > 0)
                try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ self.value, self.unit })
            else
                self.value;
            _ = value_row.printSegment(.{ .text = full_value, .style = self.value_style }, .{ .wrap = .none });
        }

        // Trend
        if (self.trend_value.len > 0 and inner.height >= 3) {
            const trend_row = inner.child(.{ .y_off = 2, .height = 1 });
            const trend_symbol, const trend_style = switch (self.trend) {
                .up => .{ "↑", self.trend_up_style },
                .down => .{ "↓", self.trend_down_style },
                .neutral => .{ "→", self.trend_neutral_style },
            };
            const trend_text = try std.fmt.allocPrint(ctx.arena, "{s} {s}", .{ trend_symbol, self.trend_value });
            _ = trend_row.printSegment(.{ .text = trend_text, .style = trend_style }, .{ .wrap = .none });
        }

        return .{ .width = @intCast(w), .height = @intCast(h) };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const MetricCard = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "metric card renders label value and trend" {
    const card = MetricCard{
        .label = "CPU",
        .value = "42",
        .unit = "%",
        .trend = .up,
        .trend_value = "5%",
        .width = 10,
        .height = 5,
    };

    var screen = try test_helpers.renderToScreen(card.drawComponent(), 12, 5);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "CPU") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "42%") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "↑") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "┌") != null);
}

test "metric card handles tiny bordered windows" {
    const card = MetricCard{
        .label = "CPU",
        .value = "42",
        .width = 1,
        .height = 1,
        .border = true,
    };

    var screen = try test_helpers.renderToScreen(card.drawComponent(), 1, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "┘", .{ .fg = .{ .index = 8 } });
}
