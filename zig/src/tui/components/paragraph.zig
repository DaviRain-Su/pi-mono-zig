const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const style_mod = @import("../style.zig");
const layout = @import("../layout.zig");
const test_helpers = @import("../test_helpers.zig");
const resources_mod = @import("../theme.zig");

pub const Paragraph = struct {
    text: []const u8 = "",
    style: vaxis.Cell.Style = .{},
    alignment: layout.AlignItems = .start,
    scroll: u16 = 0,
    show_scrollbar: bool = false,
    scrollbar_thumb: []const u8 = "█",
    scrollbar_track: []const u8 = "│",

    pub fn drawComponent(self: *const Paragraph) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Paragraph,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (window.width == 0 or window.height == 0) {
            return .{ .width = window.width, .height = 0 };
        }

        const scrollbar_width: u16 = if (self.show_scrollbar) 1 else 0;
        const content_width = if (window.width > scrollbar_width) window.width - scrollbar_width else 0;

        const content_window = window.child(.{
            .width = content_width,
            .height = window.height,
        });

        const lines = try wrapTextToLines(ctx.arena, self.text, content_width);
        const total_lines = lines.len;
        const visible_lines = @min(total_lines, window.height);
        const max_scroll = if (total_lines > window.height) total_lines - window.height else 0;
        const scroll = @min(self.scroll, max_scroll);

        for (0..visible_lines) |i| {
            const line_idx = scroll + i;
            if (line_idx >= lines.len) break;
            const line = lines[line_idx];
            const line_width = ansi.visibleWidth(line);
            const col_offset: u16 = if (line_width < content_width) switch (self.alignment) {
                .start, .stretch => 0,
                .center => @intCast((content_width - line_width) / 2),
                .end => @intCast(content_width - line_width),
            } else 0;

            var col = col_offset;
            var byte_idx: usize = 0;
            while (byte_idx < line.len and col < content_width) {
                const cluster = ansi.nextDisplayCluster(line, byte_idx);
                if (cluster.end <= byte_idx) break;
                if (cluster.width == 0) {
                    byte_idx = cluster.end;
                    continue;
                }
                if (@as(usize, col) + cluster.width > content_width) break;
                content_window.writeCell(col, @intCast(i), .{
                    .char = .{
                        .grapheme = line[byte_idx..cluster.end],
                        .width = @intCast(cluster.width),
                    },
                    .style = self.style,
                });
                col += @intCast(cluster.width);
                byte_idx = cluster.end;
            }
        }

        // Draw scrollbar
        if (self.show_scrollbar and scrollbar_width > 0 and total_lines > window.height) {
            const thumb_height = @max(1, (window.height * window.height) / total_lines);
            const max_offset = total_lines - window.height;
            const thumb_start = if (max_offset == 0) 0 else (scroll * (window.height - thumb_height)) / max_offset;
            const scroll_col = window.width - 1;
            for (0..window.height) |row| {
                const is_thumb = row >= thumb_start and row < thumb_start + thumb_height;
                window.writeCell(scroll_col, @intCast(row), .{
                    .char = .{
                        .grapheme = if (is_thumb) self.scrollbar_thumb else self.scrollbar_track,
                        .width = 1,
                    },
                    .style = .{},
                });
            }
        }

        return .{ .width = window.width, .height = @max(visible_lines, 1) };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Paragraph = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

fn wrapTextToLines(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_width: u16,
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

test "paragraph renders wrapped text" {
    const para = Paragraph{
        .text = "Hello world this is a test",
    };

    var screen = try test_helpers.renderToScreen(para.drawComponent(), 10, 3);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "H", .{});
    try test_helpers.expectCell(&screen, 0, 1, "d", .{});
}

test "paragraph scrolls content vertically" {
    const para = Paragraph{
        .text = "Line1\nLine2\nLine3",
        .scroll = 1,
    };

    var screen = try test_helpers.renderToScreen(para.drawComponent(), 10, 2);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "L", .{});
    try test_helpers.expectCell(&screen, 0, 1, "L", .{});
}

test "paragraph scrollbar indicates scroll position" {
    const para = Paragraph{
        .text = "a b c d e f g h i j",
        .show_scrollbar = true,
        .scroll = 0,
    };

    var screen = try test_helpers.renderToScreen(para.drawComponent(), 6, 3);
    defer screen.deinit(std.testing.allocator);

    const thumb = screen.readCell(5, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("█", thumb.char.grapheme);

    const track = screen.readCell(5, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("│", track.char.grapheme);
}

test "paragraph center alignment offsets text" {
    const para = Paragraph{
        .text = "Hi",
        .alignment = .center,
    };

    var screen = try test_helpers.renderToScreen(para.drawComponent(), 8, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 3, 0, "H", .{});
    try test_helpers.expectCell(&screen, 4, 0, "i", .{});
}
