const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Section = struct {
    text: []const u8 = "",
    style: vaxis.Cell.Style = .{},
};

pub const StatusBar = struct {
    left: []const Section = &.{},
    center: []const Section = &.{},
    right: []const Section = &.{},
    fill_style: vaxis.Cell.Style = .{},
    separator: []const u8 = " ",

    pub fn drawComponent(self: *const StatusBar) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn draw(
        self: *const StatusBar,
        window: vaxis.Window,
        _: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (window.height == 0 or window.width == 0) {
            return .{ .width = window.width, .height = 0 };
        }

        window.clear();

        // Fill background
        for (0..window.width) |x| {
            window.writeCell(@intCast(x), 0, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = self.fill_style,
            });
        }

        // Draw left sections
        var col: u16 = 0;
        col = try drawSections(window, 0, col, self.left, self.separator);

        // Draw center sections
        const center_w = sectionsWidth(self.center, self.separator);
        const center_start = if (center_w < window.width)
            @as(u16, @intCast((window.width - center_w) / 2))
        else
            0;
        _ = try drawSections(window, 0, center_start, self.center, self.separator);

        // Draw right sections
        const right_w = sectionsWidth(self.right, self.separator);
        const right_start = if (right_w < window.width)
            window.width - @as(u16, @intCast(right_w))
        else
            0;
        _ = try drawSections(window, 0, right_start, self.right, self.separator);

        return .{ .width = window.width, .height = 1 };
    }

    fn drawSections(
        window: vaxis.Window,
        row: u16,
        start_col: u16,
        sections: []const Section,
        separator: []const u8,
    ) std.mem.Allocator.Error!u16 {
        var col = start_col;
        for (sections, 0..) |section, i| {
            if (i > 0 and separator.len > 0) {
                var sep_idx: usize = 0;
                while (sep_idx < separator.len and col < window.width) {
                    const cluster = ansi.nextDisplayCluster(separator, sep_idx);
                    if (cluster.end <= sep_idx) break;
                    window.writeCell(col, row, .{
                        .char = .{
                            .grapheme = separator[sep_idx..cluster.end],
                            .width = @intCast(cluster.width),
                        },
                        .style = section.style,
                    });
                    col += @intCast(cluster.width);
                    sep_idx = cluster.end;
                }
            }

            var idx: usize = 0;
            while (idx < section.text.len and col < window.width) {
                const cluster = ansi.nextDisplayCluster(section.text, idx);
                if (cluster.end <= idx) break;
                window.writeCell(col, row, .{
                    .char = .{
                        .grapheme = section.text[idx..cluster.end],
                        .width = @intCast(cluster.width),
                    },
                    .style = section.style,
                });
                col += @intCast(cluster.width);
                idx = cluster.end;
            }
        }
        return col;
    }

    fn sectionsWidth(sections: []const Section, separator: []const u8) usize {
        var total: usize = 0;
        for (sections, 0..) |section, i| {
            if (i > 0) total += ansi.visibleWidth(separator);
            total += ansi.visibleWidth(section.text);
        }
        return total;
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const StatusBar = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "status bar renders left center and right sections" {
    const bar = StatusBar{
        .left = &.{.{ .text = "L" }},
        .center = &.{.{ .text = "C" }},
        .right = &.{.{ .text = "R" }},
    };

    var screen = try test_helpers.renderToScreen(bar.drawComponent(), 9, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "L", .{});
    try test_helpers.expectCell(&screen, 4, 0, "C", .{});
    try test_helpers.expectCell(&screen, 8, 0, "R", .{});
}

test "status bar separates multiple left sections" {
    const bar = StatusBar{
        .left = &.{
            .{ .text = "A" },
            .{ .text = "B" },
        },
        .separator = "|",
    };

    var screen = try test_helpers.renderToScreen(bar.drawComponent(), 6, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "A", .{});
    try test_helpers.expectCell(&screen, 1, 0, "|", .{});
    try test_helpers.expectCell(&screen, 2, 0, "B", .{});
}
