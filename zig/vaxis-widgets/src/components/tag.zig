const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Tag = struct {
    label: []const u8,
    style: vaxis.Cell.Style = .{ .fg = .{ .index = 7 }, .bg = .{ .index = 240 } },
    left_delim: []const u8 = "[",
    right_delim: []const u8 = "]",

    pub fn drawComponent(self: *const Tag) draw_mod.Component {
        return .{ .ptr = self, .drawFn = drawOpaque };
    }

    pub fn draw(
        self: *const Tag,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        window.clear();

        const label_width = ansi.visibleWidth(self.label);
        const lw = ansi.visibleWidth(self.left_delim);
        const rw = ansi.visibleWidth(self.right_delim);
        const total_width = lw + label_width + rw;

        var col: u16 = 0;

        // Left delimiter
        var idx: usize = 0;
        while (idx < self.left_delim.len and col < window.width) {
            const cluster = ansi.nextDisplayCluster(self.left_delim, idx);
            if (cluster.end <= idx) break;
            window.writeCell(col, 0, .{
                .char = .{ .grapheme = self.left_delim[idx..cluster.end], .width = @intCast(cluster.width) },
                .style = self.style,
            });
            col += @intCast(cluster.width);
            idx = cluster.end;
        }

        // Label
        idx = 0;
        while (idx < self.label.len and col < window.width) {
            const cluster = ansi.nextDisplayCluster(self.label, idx);
            if (cluster.end <= idx) break;
            window.writeCell(col, 0, .{
                .char = .{ .grapheme = self.label[idx..cluster.end], .width = @intCast(cluster.width) },
                .style = self.style,
            });
            col += @intCast(cluster.width);
            idx = cluster.end;
        }

        // Right delimiter
        idx = 0;
        while (idx < self.right_delim.len and col < window.width) {
            const cluster = ansi.nextDisplayCluster(self.right_delim, idx);
            if (cluster.end <= idx) break;
            window.writeCell(col, 0, .{
                .char = .{ .grapheme = self.right_delim[idx..cluster.end], .width = @intCast(cluster.width) },
                .style = self.style,
            });
            col += @intCast(cluster.width);
            idx = cluster.end;
        }

        return .{ .width = @min(total_width, window.width), .height = 1 };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Tag = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

pub const TagGroup = struct {
    tags: []const Tag,
    separator: []const u8 = " ",
    style: vaxis.Cell.Style = .{},

    pub fn drawComponent(self: *const TagGroup) draw_mod.Component {
        return .{ .ptr = self, .drawFn = drawOpaque };
    }

    pub fn draw(
        self: *const TagGroup,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        var col: u16 = 0;
        for (self.tags, 0..) |tag, i| {
            if (col >= window.width) break;
            if (i > 0) {
                var sidx: usize = 0;
                while (sidx < self.separator.len and col < window.width) {
                    const cluster = ansi.nextDisplayCluster(self.separator, sidx);
                    if (cluster.end <= sidx) break;
                    window.writeCell(col, 0, .{
                        .char = .{ .grapheme = self.separator[sidx..cluster.end], .width = @intCast(cluster.width) },
                        .style = self.style,
                    });
                    col += @intCast(cluster.width);
                    sidx = cluster.end;
                }
            }
            if (col >= window.width) break;
            const tag_window = window.child(.{ .x_off = col, .height = 1 });
            const size = try tag.draw(tag_window, ctx);
            col += @intCast(size.width);
        }

        return .{ .width = col, .height = 1 };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const TagGroup = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "tag renders with delimiters and label" {
    const tag = Tag{ .label = "beta", .style = .{ .fg = .{ .index = 82 } } };
    var screen = try test_helpers.renderToScreen(tag.drawComponent(), 10, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "[", .{ .fg = .{ .index = 82 } });
    try test_helpers.expectCell(&screen, 1, 0, "b", .{ .fg = .{ .index = 82 } });
    try test_helpers.expectCell(&screen, 5, 0, "]", .{ .fg = .{ .index = 82 } });
}

test "tag group renders multiple tags with separator" {
    const tags = &[_]Tag{
        .{ .label = "a" },
        .{ .label = "b" },
    };
    const group = TagGroup{ .tags = tags };

    var screen = try test_helpers.renderToScreen(group.drawComponent(), 12, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "[", .{ .fg = .{ .index = 7 }, .bg = .{ .index = 240 } });
    try test_helpers.expectCell(&screen, 3, 0, " ", .{});
    try test_helpers.expectCell(&screen, 4, 0, "[", .{ .fg = .{ .index = 7 }, .bg = .{ .index = 240 } });
}
