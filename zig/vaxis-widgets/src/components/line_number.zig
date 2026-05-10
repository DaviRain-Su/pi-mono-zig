const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

/// A line number gutter that renders alongside content.
/// Displays row numbers with optional signs (git diff markers, etc.)
/// and per-line coloring.
pub const LineNumber = struct {
    line_count: usize,
    start_line: usize = 1,
    width: usize = 4,
    style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },
    current_line_style: vaxis.Cell.Style = .{ .fg = .{ .index = 7 }, .bold = true },
    sign_style: vaxis.Cell.Style = .{},
    show_line_numbers: bool = true,
    current_line: ?usize = null,
    /// Signs per line (e.g. "+" for added, "-" for removed)
    signs: ?[]const ?[]const u8 = null,
    /// Per-line colors for the gutter
    line_colors: ?[]const vaxis.Cell.Style = null,

    pub fn drawComponent(self: *const LineNumber) draw_mod.Component {
        return .{ .ptr = self, .drawFn = drawOpaque };
    }

    pub fn draw(
        self: *const LineNumber,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        window.clear();

        for (0..self.line_count) |i| {
            if (i >= window.height) break;
            const line_no = self.start_line + i;
            const is_current = if (self.current_line) |cl| line_no == cl else false;
            const style = if (is_current) self.current_line_style else if (self.line_colors) |colors|
                if (i < colors.len) colors[i] else self.style
            else
                self.style;

            // Sign
            var col: u16 = 0;
            if (self.signs) |signs| {
                if (i < signs.len) {
                    if (signs[i]) |sign| {
                        window.writeCell(col, @intCast(i), .{
                            .char = .{ .grapheme = sign, .width = 1 },
                            .style = self.sign_style,
                        });
                    }
                }
                col += 1;
            }

            // Line number
            if (self.show_line_numbers) {
                var buf: [16]u8 = undefined;
                const num = std.fmt.bufPrint(&buf, "{d: >4}", .{line_no}) catch "";
                var idx: usize = 0;
                while (idx < num.len and col + idx < window.width) {
                    window.writeCell(@intCast(col + idx), @intCast(i), .{
                        .char = .{ .grapheme = num[idx .. idx + 1], .width = 1 },
                        .style = style,
                    });
                    idx += 1;
                }
            }
        }

        return .{ .width = @min(self.width, window.width), .height = @min(self.line_count, window.height) };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const LineNumber = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "line number renders gutter with signs" {
    const signs = &[_]?[]const u8{
        "+",
        "-",
        null,
    };
    const ln = LineNumber{
        .line_count = 3,
        .start_line = 10,
        .signs = signs,
        .current_line = 11,
    };

    var screen = try test_helpers.renderToScreen(ln.drawComponent(), 6, 3);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "+", .{});
    try test_helpers.expectCell(&screen, 0, 1, "-", .{});
    try test_helpers.expectCell(&screen, 1, 0, "1", .{ .fg = .{ .index = 8 } });
    try test_helpers.expectCell(&screen, 1, 1, "1", .{ .fg = .{ .index = 7 }, .bold = true });
}

test "line number with per-line colors" {
    const colors = &[_]vaxis.Cell.Style{
        .{ .fg = .{ .index = 82 } },
        .{ .fg = .{ .index = 196 } },
    };
    const ln = LineNumber{
        .line_count = 2,
        .line_colors = colors,
    };

    var screen = try test_helpers.renderToScreen(ln.drawComponent(), 5, 2);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 1, 0, "1", .{ .fg = .{ .index = 82 } });
    try test_helpers.expectCell(&screen, 1, 1, "2", .{ .fg = .{ .index = 196 } });
}
