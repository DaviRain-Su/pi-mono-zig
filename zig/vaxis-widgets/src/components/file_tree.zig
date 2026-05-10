const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const FileType = enum {
    file,
    directory,
    symlink,
};

pub const FileTreeNode = struct {
    name: []const u8,
    file_type: FileType = .file,
    expanded: bool = false,
    children: ?[]FileTreeNode = null,
};

const VisibleFileNode = struct {
    node: *const FileTreeNode,
    depth: usize,
};

pub const FileTree = struct {
    nodes: []FileTreeNode,
    selected_index: usize = 0,
    offset: usize = 0,
    style: vaxis.Cell.Style = .{},
    selected_style: vaxis.Cell.Style = .{ .reverse = true },
    dir_style: vaxis.Cell.Style = .{ .bold = true, .fg = .{ .index = 39 } },
    file_style: vaxis.Cell.Style = .{},
    symlink_style: vaxis.Cell.Style = .{ .fg = .{ .index = 213 } },
    indent: usize = 2,
    expanded_symbol: []const u8 = "▼",
    collapsed_symbol: []const u8 = "▶",
    file_symbol: []const u8 = "  ",
    dir_symbol: []const u8 = "📁",
    file_icon: []const u8 = "  ",
    show_icons: bool = false,

    pub fn drawComponent(self: *const FileTree) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const FileTree,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        if (window.width == 0 or window.height == 0 or self.nodes.len == 0) {
            return .{ .width = window.width, .height = 0 };
        }

        var visible = std.ArrayList(VisibleFileNode).empty;
        defer visible.deinit(ctx.arena);
        try flattenFileNodes(ctx.arena, self.nodes, 0, &visible);

        const total_rows = visible.items.len;
        if (total_rows == 0) return .{ .width = window.width, .height = 0 };

        const visible_rows = @min(total_rows, window.height);
        const selected_index = @min(self.selected_index, total_rows - 1);
        const max_offset = total_rows - visible_rows;
        var offset = @min(self.offset, max_offset);
        if (selected_index < offset) {
            offset = selected_index;
        } else if (selected_index >= offset + visible_rows) {
            offset = selected_index - visible_rows + 1;
        }

        for (0..visible_rows) |row_idx| {
            const visible_index = offset + row_idx;
            const entry = visible.items[visible_index];
            try self.drawVisibleNode(entry.node, window, entry.depth, @intCast(row_idx), visible_index == selected_index);
        }

        return .{ .width = window.width, .height = visible_rows };
    }

    fn drawVisibleNode(
        self: *const FileTree,
        node: *const FileTreeNode,
        window: vaxis.Window,
        depth: usize,
        row: u16,
        is_selected: bool,
    ) std.mem.Allocator.Error!void {
        const style = if (is_selected) self.selected_style else switch (node.file_type) {
            .directory => self.dir_style,
            .symlink => self.symlink_style,
            .file => self.file_style,
        };

        const row_window = window.child(.{ .y_off = row, .height = 1 });
        row_window.fill(.{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = style,
        });

        var col: u16 = @intCast(depth * self.indent);
        const has_children = node.children != null and node.children.?.len > 0;
        const icon = if (node.file_type == .directory and has_children)
            if (node.expanded) self.expanded_symbol else self.collapsed_symbol
        else
            self.file_symbol;

        var idx: usize = 0;
        while (idx < icon.len and col < row_window.width) {
            const cluster = ansi.nextDisplayCluster(icon, idx);
            if (cluster.end <= idx) break;
            const width: u16 = @intCast(cluster.width);
            if (width == 0 or col + width > row_window.width) break;
            row_window.writeCell(col, 0, .{
                .char = .{ .grapheme = icon[idx..cluster.end], .width = @intCast(width) },
                .style = style,
            });
            col += width;
            idx = cluster.end;
        }

        if (col < row_window.width) {
            col += 1;
            var nidx: usize = 0;
            while (nidx < node.name.len and col < row_window.width) {
                const cluster = ansi.nextDisplayCluster(node.name, nidx);
                if (cluster.end <= nidx) break;
                const width: u16 = @intCast(cluster.width);
                if (width == 0) {
                    nidx = cluster.end;
                    continue;
                }
                if (col + width > row_window.width) break;
                row_window.writeCell(col, 0, .{
                    .char = .{ .grapheme = node.name[nidx..cluster.end], .width = @intCast(width) },
                    .style = style,
                });
                col += width;
                nidx = cluster.end;
            }
        }
    }

    fn drawNode(
        self: *const FileTree,
        node: *const FileTreeNode,
        window: vaxis.Window,
        depth: usize,
        row: *u16,
        flat_index: *usize,
    ) std.mem.Allocator.Error!u16 {
        if (row.* >= window.height) return row.*;

        const is_selected = flat_index.* == self.selected_index;
        const style = if (is_selected) self.selected_style else switch (node.file_type) {
            .directory => self.dir_style,
            .symlink => self.symlink_style,
            .file => self.file_style,
        };

        const row_window = window.child(.{ .y_off = row.*, .height = 1 });
        row_window.fill(.{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = style,
        });

        var col: u16 = @intCast(depth * self.indent);

        // Expand/collapse or file icon
        const has_children = node.children != null and node.children.?.len > 0;
        const icon = if (node.file_type == .directory and has_children)
            if (node.expanded) self.expanded_symbol else self.collapsed_symbol
        else
            self.file_symbol;

        var idx: usize = 0;
        while (idx < icon.len and col < row_window.width) {
            const cluster = ansi.nextDisplayCluster(icon, idx);
            if (cluster.end <= idx) break;
            row_window.writeCell(col, 0, .{
                .char = .{ .grapheme = icon[idx..cluster.end], .width = @intCast(cluster.width) },
                .style = style,
            });
            col += @intCast(cluster.width);
            idx = cluster.end;
        }

        // Name
        if (col < row_window.width) {
            col += 1;
            var nidx: usize = 0;
            while (nidx < node.name.len and col < row_window.width) {
                const cluster = ansi.nextDisplayCluster(node.name, nidx);
                if (cluster.end <= nidx) break;
                row_window.writeCell(col, 0, .{
                    .char = .{ .grapheme = node.name[nidx..cluster.end], .width = @intCast(cluster.width) },
                    .style = style,
                });
                col += @intCast(cluster.width);
                nidx = cluster.end;
            }
        }

        row.* += 1;
        flat_index.* += 1;

        // Children
        if (node.expanded and node.children != null) {
            for (node.children.?) |child| {
                if (row.* >= window.height) break;
                row.* = try self.drawNode(&child, window, depth + 1, row, flat_index);
            }
        }

        return row.*;
    }

    pub fn toggleNode(self: *FileTree, index: usize) void {
        const node = visibleFileNodeAtMutable(self.nodes, index) orelse return;
        if (node.file_type != .directory) return;
        if (node.children == null or node.children.?.len == 0) return;
        node.expanded = !node.expanded;
        const visible_count = self.visibleCount();
        if (visible_count == 0) {
            self.selected_index = 0;
            self.offset = 0;
        } else {
            self.selected_index = @min(self.selected_index, visible_count - 1);
            self.offset = @min(self.offset, visible_count - 1);
        }
    }

    pub fn handleKey(self: *FileTree, key: @import("../keys.zig").Key) void {
        switch (key) {
            .up => {
                if (self.selected_index > 0) self.selected_index -= 1;
            },
            .down => {
                const visible_count = self.visibleCount();
                if (visible_count > 0 and self.selected_index + 1 < visible_count) {
                    self.selected_index += 1;
                }
            },
            .enter => {
                self.toggleNode(self.selected_index);
            },
            else => {},
        }
    }

    pub fn visibleCount(self: *const FileTree) usize {
        var count: usize = 0;
        for (self.nodes) |node| {
            count += countVisibleNode(&node);
        }
        return count;
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const FileTree = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

fn countVisibleNode(node: *const FileTreeNode) usize {
    var count: usize = 1;
    if (node.expanded and node.children != null) {
        for (node.children.?) |child| {
            count += countVisibleNode(&child);
        }
    }
    return count;
}

fn flattenFileNodes(
    allocator: std.mem.Allocator,
    nodes: []const FileTreeNode,
    depth: usize,
    out: *std.ArrayList(VisibleFileNode),
) std.mem.Allocator.Error!void {
    for (nodes) |*node| {
        try out.append(allocator, .{ .node = node, .depth = depth });
        if (node.expanded and node.children != null) {
            try flattenFileNodes(allocator, node.children.?, depth + 1, out);
        }
    }
}

fn visibleFileNodeAtMutable(nodes: []FileTreeNode, target_index: usize) ?*FileTreeNode {
    var current_index: usize = 0;
    return visibleFileNodeAtMutableInner(nodes, target_index, &current_index);
}

fn visibleFileNodeAtMutableInner(
    nodes: []FileTreeNode,
    target_index: usize,
    current_index: *usize,
) ?*FileTreeNode {
    for (nodes) |*node| {
        if (current_index.* == target_index) return node;
        current_index.* += 1;
        if (node.expanded and node.children != null) {
            if (visibleFileNodeAtMutableInner(node.children.?, target_index, current_index)) |found| {
                return found;
            }
        }
    }
    return null;
}

test "file tree renders directories and files" {
    var children = [_]FileTreeNode{
        .{ .name = "main.zig", .file_type = .file },
        .{ .name = "utils.zig", .file_type = .file },
    };

    var nodes = [_]FileTreeNode{
        .{ .name = "src", .file_type = .directory, .expanded = true, .children = &children },
        .{ .name = "README.md", .file_type = .file },
    };

    var tree = FileTree{ .nodes = &nodes, .selected_index = 1 };

    var screen = try test_helpers.renderToScreen(tree.drawComponent(), 20, 4);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "▼") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "src") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "README.md") != null);
}

test "file tree down navigation clamps to visible nodes" {
    var children = [_]FileTreeNode{
        .{ .name = "main.zig", .file_type = .file },
    };
    var nodes = [_]FileTreeNode{
        .{ .name = "src", .file_type = .directory, .expanded = true, .children = &children },
        .{ .name = "README.md", .file_type = .file },
    };

    var tree = FileTree{ .nodes = &nodes };
    tree.handleKey(.down);
    tree.handleKey(.down);
    tree.handleKey(.down);
    tree.handleKey(.down);

    try std.testing.expectEqual(@as(usize, 2), tree.selected_index);
    try std.testing.expectEqual(@as(usize, 3), tree.visibleCount());
}

test "file tree draw scrolls selected node into view" {
    var nodes = [_]FileTreeNode{
        .{ .name = "one", .file_type = .file },
        .{ .name = "two", .file_type = .file },
        .{ .name = "three", .file_type = .file },
        .{ .name = "four", .file_type = .file },
    };

    var tree = FileTree{ .nodes = &nodes, .selected_index = 3 };

    var screen = try test_helpers.renderToScreen(tree.drawComponent(), 16, 2);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 3, 1, "f", .{ .reverse = true });
}

test "file tree enter toggles selected directory" {
    var children = [_]FileTreeNode{
        .{ .name = "main.zig", .file_type = .file },
    };
    var nodes = [_]FileTreeNode{
        .{ .name = "src", .file_type = .directory, .expanded = false, .children = &children },
        .{ .name = "README.md", .file_type = .file },
    };

    var tree = FileTree{ .nodes = &nodes };
    try std.testing.expectEqual(@as(usize, 2), tree.visibleCount());

    tree.handleKey(.enter);

    try std.testing.expect(nodes[0].expanded);
    try std.testing.expectEqual(@as(usize, 3), tree.visibleCount());
}

test "file tree collapse clamps hidden selected child" {
    var children = [_]FileTreeNode{
        .{ .name = "main.zig", .file_type = .file },
        .{ .name = "utils.zig", .file_type = .file },
    };
    var nodes = [_]FileTreeNode{
        .{ .name = "src", .file_type = .directory, .expanded = true, .children = &children },
    };

    var tree = FileTree{ .nodes = &nodes, .selected_index = 2, .offset = 2 };
    tree.toggleNode(0);

    try std.testing.expect(!nodes[0].expanded);
    try std.testing.expectEqual(@as(usize, 0), tree.selected_index);
    try std.testing.expectEqual(@as(usize, 0), tree.offset);
}
