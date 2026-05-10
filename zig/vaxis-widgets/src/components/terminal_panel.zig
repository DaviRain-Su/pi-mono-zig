const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const TerminalLine = struct {
    text: []const u8,
    style: vaxis.Cell.Style = .{},
};

pub const TerminalPanel = struct {
    lines: []const TerminalLine,
    scroll_offset: usize = 0,
    style: vaxis.Cell.Style = .{},
    line_number_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },
    show_line_numbers: bool = false,
    line_number_width: usize = 3,
    max_lines: usize = 0, // 0 = unlimited

    pub fn drawComponent(self: *const TerminalPanel) draw_mod.Component {
        return .{ .ptr = self, .drawFn = drawOpaque };
    }

    pub fn draw(
        self: *const TerminalPanel,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        const ln_width: u16 = if (self.show_line_numbers) @intCast(self.line_number_width + 1) else 0;
        const content_width = if (window.width > ln_width) window.width - ln_width else 0;
        const visible_count = @min(self.lines.len, window.height);
        const start = @min(self.scroll_offset, if (self.lines.len > window.height) self.lines.len - window.height else 0);

        for (0..visible_count) |i| {
            const line_idx = start + i;
            if (line_idx >= self.lines.len) break;
            const line = self.lines[line_idx];
            const row_window = window.child(.{ .y_off = @intCast(i), .height = 1 });

            // Line number
            if (self.show_line_numbers) {
                const num = try std.fmt.allocPrint(ctx.arena, "{d}", .{line_idx + 1});
                var idx: usize = 0;
                while (idx < num.len and idx < ln_width) {
                    row_window.writeCell(@intCast(idx), 0, .{
                        .char = .{ .grapheme = num[idx .. idx + 1], .width = 1 },
                        .style = self.line_number_style,
                    });
                    idx += 1;
                }
            }

            // Content with ANSI passthrough
            if (content_width > 0) {
                const content_window = row_window.child(.{ .x_off = ln_width, .width = content_width });
                var col: u16 = 0;
                var idx: usize = 0;
                while (idx < line.text.len and col < content_window.width) {
                    const cluster = ansi.nextDisplayCluster(line.text, idx);
                    if (cluster.end <= idx) break;
                    const width: u16 = @intCast(cluster.width);
                    if (width == 0) {
                        idx = cluster.end;
                        continue;
                    }
                    if (col + width > content_window.width) break;
                    content_window.writeCell(col, 0, .{
                        .char = .{ .grapheme = line.text[idx..cluster.end], .width = @intCast(width) },
                        .style = line.style,
                    });
                    col += width;
                    idx = cluster.end;
                }
            }
        }

        return .{ .width = window.width, .height = visible_count };
    }

    pub fn scrollDown(self: *TerminalPanel, lines: usize) void {
        self.scroll_offset = @min(self.scroll_offset + lines, if (self.lines.len > 0) self.lines.len - 1 else 0);
    }

    pub fn scrollUp(self: *TerminalPanel, lines: usize) void {
        self.scroll_offset = if (self.scroll_offset > lines) self.scroll_offset - lines else 0;
    }

    pub fn scrollToBottom(self: *TerminalPanel) void {
        self.scroll_offset = self.lines.len;
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const TerminalPanel = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "terminal panel renders lines with line numbers" {
    const lines = &[_]TerminalLine{
        .{ .text = "first", .style = .{ .fg = .{ .index = 82 } } },
        .{ .text = "second" },
    };

    const panel = TerminalPanel{
        .lines = lines,
        .show_line_numbers = true,
    };

    var screen = try test_helpers.renderToScreen(panel.drawComponent(), 12, 2);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "1", .{ .fg = .{ .index = 8 } });
    try test_helpers.expectCell(&screen, 4, 0, "f", .{ .fg = .{ .index = 82 } });
    try test_helpers.expectCell(&screen, 0, 1, "2", .{ .fg = .{ .index = 8 } });
}

test "terminal panel does not draw wide grapheme past narrow content" {
    const lines = &[_]TerminalLine{.{ .text = "你" }};
    const panel = TerminalPanel{ .lines = lines };

    var screen = try test_helpers.renderToScreen(panel.drawComponent(), 1, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, " ", .{});
    try test_helpers.expectNoWideCellOverflow(&screen);
}
