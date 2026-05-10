const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Tooltip = struct {
    text: []const u8,
    style: vaxis.Cell.Style = .{ .fg = .{ .index = 250 }, .bg = .{ .index = 235 } },
    border_style: vaxis.Cell.Style = .{ .fg = .{ .index = 240 } },
    max_width: usize = 40,
    padding_x: usize = 1,

    pub fn drawComponent(self: *const Tooltip) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Tooltip,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        const content_width = @min(self.max_width - 2 - self.padding_x * 2, @as(usize, window.width) - 2);
        const lines = try wrapTextToLines(ctx.arena, self.text, content_width);
        const line_count = @min(lines.len, @as(usize, window.height) - 2);
        const tooltip_width = @min(content_width + 2 + self.padding_x * 2, window.width);
        const tooltip_height = line_count + 2;

        if (tooltip_width == 0 or tooltip_height == 0) {
            return .{ .width = 0, .height = 0 };
        }

        // Draw border
        const bstyle = self.border_style;
        for (0..tooltip_width) |col| {
            window.writeCell(@intCast(col), 0, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = bstyle,
            });
            window.writeCell(@intCast(col), @intCast(tooltip_height - 1), .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = bstyle,
            });
        }
        for (1..tooltip_height - 1) |row| {
            window.writeCell(0, @intCast(row), .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = bstyle,
            });
            window.writeCell(@intCast(tooltip_width - 1), @intCast(row), .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = bstyle,
            });
        }
        window.writeCell(0, 0, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = bstyle });
        window.writeCell(@intCast(tooltip_width - 1), 0, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = bstyle });
        window.writeCell(0, @intCast(tooltip_height - 1), .{ .char = .{ .grapheme = "└", .width = 1 }, .style = bstyle });
        window.writeCell(@intCast(tooltip_width - 1), @intCast(tooltip_height - 1), .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = bstyle });

        // Content
        const inner = window.child(.{
            .x_off = @intCast(1 + self.padding_x),
            .y_off = 1,
            .width = @intCast(tooltip_width - 2 - self.padding_x * 2),
            .height = @intCast(tooltip_height - 2),
        });
        inner.clear();

        for (lines[0..line_count], 0..) |line, i| {
            if (i >= inner.height) break;
            const row_window = inner.child(.{ .y_off = @intCast(i), .height = 1 });
            _ = row_window.printSegment(.{ .text = line, .style = self.style }, .{ .wrap = .none });
        }

        return .{ .width = @intCast(tooltip_width), .height = @intCast(tooltip_height) };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Tooltip = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

fn wrapTextToLines(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_width: usize,
) std.mem.Allocator.Error![]const []const u8 {
    if (max_width == 0 or text.len == 0) return &[_][]const u8{};

    var lines = std.ArrayList([]const u8).empty;
    var current_line = std.ArrayList(u8).empty;
    errdefer current_line.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\n') {
            try lines.append(allocator, try allocator.dupe(u8, current_line.items));
            current_line.clearRetainingCapacity();
            index += 1;
            continue;
        }

        const cluster = ansi.nextDisplayCluster(text, index);
        if (cluster.end <= index) break;
        const cluster_width = ansi.visibleWidth(text[index..cluster.end]);
        const current_width = ansi.visibleWidth(current_line.items);

        if (current_width + cluster_width > max_width and current_width > 0) {
            try lines.append(allocator, try allocator.dupe(u8, current_line.items));
            current_line.clearRetainingCapacity();
        }

        try current_line.appendSlice(allocator, text[index..cluster.end]);
        index = cluster.end;
    }

    if (current_line.items.len > 0) {
        try lines.append(allocator, try allocator.dupe(u8, current_line.items));
    }

    current_line.deinit(allocator);
    return lines.toOwnedSlice(allocator);
}

test "tooltip renders wrapped text with border" {
    const tooltip = Tooltip{
        .text = "This is a longer tooltip that should wrap across multiple lines within the max width.",
        .max_width = 20,
    };

    var screen = try test_helpers.renderToScreen(tooltip.drawComponent(), 20, 6);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "└") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "This") != null);
}
