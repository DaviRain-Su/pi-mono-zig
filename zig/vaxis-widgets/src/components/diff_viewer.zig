const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const DiffLineType = enum {
    context,
    added,
    removed,
    header,
};

pub const DiffLine = struct {
    text: []const u8,
    line_type: DiffLineType = .context,
    old_line_no: ?usize = null,
    new_line_no: ?usize = null,
};

pub const DiffViewer = struct {
    lines: []const DiffLine,
    show_line_numbers: bool = true,
    line_number_width: usize = 4,
    style: vaxis.Cell.Style = .{},
    header_style: vaxis.Cell.Style = .{ .bold = true, .fg = .{ .index = 7 } },
    added_style: vaxis.Cell.Style = .{ .fg = .{ .index = 82 } },
    removed_style: vaxis.Cell.Style = .{ .fg = .{ .index = 196 } },
    added_bg: vaxis.Cell.Style = .{ .bg = .{ .index = 22 } },
    removed_bg: vaxis.Cell.Style = .{ .bg = .{ .index = 52 } },
    context_style: vaxis.Cell.Style = .{},
    line_number_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },
    gutter_width: usize = 1,

    pub fn drawComponent(self: *const DiffViewer) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const DiffViewer,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        const ln_width = if (self.show_line_numbers) self.line_number_width else 0;
        const content_x = self.gutter_width + ln_width + 1;

        for (self.lines, 0..) |line, i| {
            if (i >= window.height) break;
            const row_window = window.child(.{ .y_off = @intCast(i), .height = 1 });

            const style, const marker = switch (line.line_type) {
                .added => .{ self.added_style, "+" },
                .removed => .{ self.removed_style, "-" },
                .header => .{ self.header_style, "@" },
                .context => .{ self.context_style, " " },
            };

            const bg_style: vaxis.Cell.Style = switch (line.line_type) {
                .added => self.added_bg,
                .removed => self.removed_bg,
                else => .{},
            };

            // Gutter marker
            if (self.gutter_width > 0) {
                row_window.writeCell(0, 0, .{
                    .char = .{ .grapheme = marker, .width = 1 },
                    .style = style,
                });
            }

            // Line numbers
            if (self.show_line_numbers and ln_width > 0) {
                const old = if (line.old_line_no) |n|
                    try std.fmt.allocPrint(ctx.arena, "{d: >4}", .{n})
                else
                    "    ";
                const new = if (line.new_line_no) |n|
                    try std.fmt.allocPrint(ctx.arena, "{d: >4}", .{n})
                else
                    "    ";
                const nums = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ old, new });
                var col: u16 = @intCast(self.gutter_width);
                var idx: usize = 0;
                while (idx < nums.len and col < content_x) {
                    row_window.writeCell(col, 0, .{
                        .char = .{ .grapheme = nums[idx .. idx + 1], .width = 1 },
                        .style = self.line_number_style,
                    });
                    col += 1;
                    idx += 1;
                }
            }

            // Content
            if (content_x < row_window.width) {
                const content_window = row_window.child(.{ .x_off = @intCast(content_x) });
                var col: u16 = 0;
                var idx: usize = 0;
                while (idx < line.text.len and col < content_window.width) {
                    const cluster = ansi.nextDisplayCluster(line.text, idx);
                    if (cluster.end <= idx) break;
                    content_window.writeCell(col, 0, .{
                        .char = .{ .grapheme = line.text[idx..cluster.end], .width = @intCast(cluster.width) },
                        .style = .{
                            .fg = style.fg,
                            .bg = bg_style.bg,
                        },
                    });
                    col += @intCast(cluster.width);
                    idx = cluster.end;
                }
            }
        }

        return .{ .width = window.width, .height = @min(self.lines.len, window.height) };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const DiffViewer = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "diff viewer renders added removed and context lines" {
    const lines = &[_]DiffLine{
        .{ .text = "@@ -1,3 +1,3 @@", .line_type = .header, .old_line_no = 1, .new_line_no = 1 },
        .{ .text = " const x = 1;", .line_type = .removed, .old_line_no = 1 },
        .{ .text = " const x = 2;", .line_type = .added, .new_line_no = 1 },
        .{ .text = " const y = 3;", .line_type = .context, .old_line_no = 2, .new_line_no = 2 },
    };

    const viewer = DiffViewer{ .lines = lines, .line_number_width = 0, .gutter_width = 1 };

    var screen = try test_helpers.renderToScreen(viewer.drawComponent(), 40, 4);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "@", .{ .bold = true, .fg = .{ .index = 7 } });
    try test_helpers.expectCell(&screen, 0, 1, "-", .{ .fg = .{ .index = 196 } });
    try test_helpers.expectCell(&screen, 0, 2, "+", .{ .fg = .{ .index = 82 } });
    try test_helpers.expectCell(&screen, 0, 3, " ", .{});
}
