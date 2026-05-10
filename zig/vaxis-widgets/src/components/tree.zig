const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

const VisibleNode = struct { node: *const TreeNode, depth: usize };

pub const TreeNode = struct {
    label: []const u8,
    children: []const TreeNode = &.{},
    expanded: bool = false,

    pub fn toggle(self: *TreeNode) void {
        self.expanded = !self.expanded;
    }

    pub fn depth(self: *const TreeNode, nodes: []const TreeNode) usize {
        var d: usize = 0;
        var current: ?*const TreeNode = self;
        while (current) |n| {
            for (nodes) |parent| {
                for (parent.children) |child| {
                    if (@intFromPtr(&child) == @intFromPtr(n)) {
                        d += 1;
                        current = &parent;
                        break;
                    }
                } else continue;
                break;
            } else {
                current = null;
            }
        }
        return d;
    }
};

pub const TreeState = struct {
    selected_index: usize = 0,
    offset: usize = 0,

    pub fn selectNext(self: *TreeState, visible_count: usize) void {
        self.selected_index = @min(self.selected_index + 1, visible_count -| 1);
        self.scrollToSelected();
    }

    pub fn selectPrevious(self: *TreeState) void {
        self.selected_index = if (self.selected_index == 0) 0 else self.selected_index - 1;
        self.scrollToSelected();
    }

    fn scrollToSelected(self: *TreeState) void {
        // Simplified: offset tracks selected for now
        self.offset = self.selected_index;
    }
};

pub const Tree = struct {
    nodes: []const TreeNode,
    style: vaxis.Cell.Style = .{},
    selected_style: vaxis.Cell.Style = .{ .reverse = true },
    guide_style: vaxis.Cell.Style = .{ .dim = true },
    indent_width: u16 = 2,
    expand_icon: []const u8 = "▶",
    collapse_icon: []const u8 = "▼",
    leaf_icon: []const u8 = "•",
    show_scrollbar: bool = false,
    scrollbar_thumb: []const u8 = "█",
    scrollbar_track: []const u8 = "│",

    pub fn drawComponent(self: *const Tree) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Tree,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (window.width == 0 or window.height == 0 or self.nodes.len == 0) {
            return .{ .width = window.width, .height = 0 };
        }

        const scrollbar_width: u16 = if (self.show_scrollbar) 1 else 0;
        const content_width = if (window.width > scrollbar_width) window.width - scrollbar_width else 0;
        const content_window = window.child(.{ .width = content_width, .height = window.height });

        // Flatten visible nodes
        var visible = std.ArrayList(VisibleNode).empty;
        defer visible.deinit(ctx.arena);
        try flattenNodes(ctx.arena, self.nodes, 0, &visible);

        const total_rows = visible.items.len;
        const visible_rows = @min(total_rows, window.height);

        for (0..visible_rows) |i| {
            const row: u16 = @intCast(i);
            const entry = visible.items[i];
            const is_selected = i == 0; // simplified: first item selected
            const row_style = if (is_selected) self.selected_style else self.style;

            const indent: u16 = @intCast(entry.depth * self.indent_width);
            const icon = if (entry.node.children.len > 0)
                (if (entry.node.expanded) self.collapse_icon else self.expand_icon)
            else
                self.leaf_icon;

            var col = indent;

            // Draw icon
            var idx: usize = 0;
            while (idx < icon.len and col < content_width) {
                const cluster = ansi.nextDisplayCluster(icon, idx);
                if (cluster.end <= idx) break;
                content_window.writeCell(col, row, .{
                    .char = .{ .grapheme = icon[idx..cluster.end], .width = @intCast(cluster.width) },
                    .style = row_style,
                });
                col += @intCast(cluster.width);
                idx = cluster.end;
            }

            // Space after icon
            if (col < content_width) {
                content_window.writeCell(col, row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = row_style,
                });
                col += 1;
            }

            // Draw label
            var lidx: usize = 0;
            while (lidx < entry.node.label.len and col < content_width) {
                const cluster = ansi.nextDisplayCluster(entry.node.label, lidx);
                if (cluster.end <= lidx) break;
                content_window.writeCell(col, row, .{
                    .char = .{ .grapheme = entry.node.label[lidx..cluster.end], .width = @intCast(cluster.width) },
                    .style = row_style,
                });
                col += @intCast(cluster.width);
                lidx = cluster.end;
            }

            // Fill rest
            while (col < content_width) {
                content_window.writeCell(col, row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = row_style,
                });
                col += 1;
            }
        }

        // Draw scrollbar
        if (self.show_scrollbar and scrollbar_width > 0 and total_rows > window.height) {
            const thumb_height = @max(1, (window.height * window.height) / total_rows);
            const thumb_start = 0;
            const scroll_col = window.width - 1;
            for (0..window.height) |row| {
                const is_thumb = row >= thumb_start and row < thumb_start + thumb_height;
                window.writeCell(scroll_col, @intCast(row), .{
                    .char = .{ .grapheme = if (is_thumb) self.scrollbar_thumb else self.scrollbar_track, .width = 1 },
                    .style = .{},
                });
            }
        }

        return .{ .width = window.width, .height = visible_rows };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Tree = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

fn flattenNodes(
    allocator: std.mem.Allocator,
    nodes: []const TreeNode,
    depth: usize,
    out: *std.ArrayList(VisibleNode),
) std.mem.Allocator.Error!void {
    for (nodes) |*node| {
        try out.append(allocator, .{ .node = node, .depth = depth });
        if (node.expanded and node.children.len > 0) {
            try flattenNodes(allocator, node.children, depth + 1, out);
        }
    }
}

test "tree renders nodes with indentation" {
    var nodes = [_]TreeNode{
        .{
            .label = "Root",
            .children = &[_]TreeNode{
                .{ .label = "Child1" },
                .{ .label = "Child2" },
            },
            .expanded = true,
        },
    };

    const tree = Tree{
        .nodes = &nodes,
    };

    var screen = try test_helpers.renderToScreen(tree.drawComponent(), 20, 3);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "▼", .{ .reverse = true });
    try test_helpers.expectCell(&screen, 2, 1, "•", .{});
    try test_helpers.expectCell(&screen, 4, 1, "C", .{});
}

test "tree shows expand icon for collapsed parent" {
    var nodes = [_]TreeNode{
        .{
            .label = "Root",
            .children = &[_]TreeNode{
                .{ .label = "Hidden" },
            },
            .expanded = false,
        },
    };

    const tree = Tree{
        .nodes = &nodes,
    };

    var screen = try test_helpers.renderToScreen(tree.drawComponent(), 20, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "▶", .{ .reverse = true });
    try test_helpers.expectCell(&screen, 2, 0, "R", .{ .reverse = true });
}
