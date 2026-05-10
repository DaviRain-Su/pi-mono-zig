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
    children: ?[]const FileTreeNode = null,
};

pub const FileTree = struct {
    nodes: []const FileTreeNode,
    selected_index: usize = 0,
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
        _ = ctx;
        window.clear();

        var row: u16 = 0;
        var flat_index: usize = 0;

        for (self.nodes) |node| {
            if (row >= window.height) break;
            row = try self.drawNode(&node, window, 0, &row, &flat_index);
        }

        return .{ .width = window.width, .height = row };
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
        // Flat index lookup would require tracking state
        _ = self;
        _ = index;
    }

    pub fn handleKey(self: *FileTree, key: @import("../keys.zig").Key) void {
        switch (key) {
            .up => {
                if (self.selected_index > 0) self.selected_index -= 1;
            },
            .down => {
                self.selected_index += 1;
            },
            .enter, .space => {
                // toggle expansion on selected
            },
            else => {},
        }
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

test "file tree renders directories and files" {
    const children = &[_]FileTreeNode{
        .{ .name = "main.zig", .file_type = .file },
        .{ .name = "utils.zig", .file_type = .file },
    };

    const nodes = &[_]FileTreeNode{
        .{ .name = "src", .file_type = .directory, .expanded = true, .children = children },
        .{ .name = "README.md", .file_type = .file },
    };

    var tree = FileTree{ .nodes = nodes, .selected_index = 1 };

    var screen = try test_helpers.renderToScreen(tree.drawComponent(), 20, 4);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "▼") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "src") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "README.md") != null);
}
