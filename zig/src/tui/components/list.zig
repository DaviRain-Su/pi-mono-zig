const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const style_mod = @import("../style.zig");
const test_helpers = @import("../test_helpers.zig");
const resources_mod = @import("../theme.zig");

pub const ListItem = struct {
    text: []const u8,
    style: ?vaxis.Cell.Style = null,
};

pub const List = struct {
    items: []const ListItem,
    start_corner: Corner = .top_left,
    style: vaxis.Cell.Style = .{},
    highlight_style: ?vaxis.Cell.Style = null,
    highlight_symbol: []const u8 = "",
    repeat_highlight_symbol: bool = false,
    show_scrollbar: bool = false,
    scrollbar_thumb: []const u8 = "█",
    scrollbar_track: []const u8 = "│",

    pub const Corner = enum {
        top_left,
        bottom_left,
    };

    pub fn drawComponent(self: *const List) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const List,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        if (window.width == 0 or window.height == 0 or self.items.len == 0) {
            return .{ .width = window.width, .height = 0 };
        }

        const scrollbar_width: u16 = if (self.show_scrollbar and self.items.len > window.height) 1 else 0;
        const content_width = if (window.width > scrollbar_width) window.width - scrollbar_width else 0;

        const content_window = window.child(.{
            .width = content_width,
            .height = window.height,
        });

        const max_items = @min(self.items.len, window.height);
        const start_index: usize = switch (self.start_corner) {
            .top_left => 0,
            .bottom_left => if (self.items.len > window.height) self.items.len - window.height else 0,
        };

        for (0..max_items) |i| {
            const item_index = start_index + i;
            const item = self.items[item_index];
            const row: u16 = switch (self.start_corner) {
                .top_left => @intCast(i),
                .bottom_left => @intCast(window.height - max_items + i),
            };

            const item_style = item.style orelse self.style;
            const row_window = content_window.child(.{
                .y_off = row,
                .height = 1,
            });
            row_window.fill(.{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = item_style,
            });

            var col: u16 = 0;

            // Draw highlight symbol
            if (self.highlight_symbol.len > 0) {
                const sym_width = ansi.visibleWidth(self.highlight_symbol);
                if (sym_width <= content_width) {
                    const sym_style = self.highlight_style orelse item_style;
                    var sym_col: u16 = 0;
                    var sym_idx: usize = 0;
                    while (sym_idx < self.highlight_symbol.len and sym_col < content_width) {
                        const cluster = ansi.nextDisplayCluster(self.highlight_symbol, sym_idx);
                        if (cluster.end <= sym_idx) break;
                        row_window.writeCell(sym_col, 0, .{
                            .char = .{
                                .grapheme = self.highlight_symbol[sym_idx..cluster.end],
                                .width = @intCast(cluster.width),
                            },
                            .style = sym_style,
                        });
                        sym_col += @intCast(cluster.width);
                        sym_idx = cluster.end;
                    }
                    if (!self.repeat_highlight_symbol) {
                        col = sym_col;
                    }
                }
            }

            // Draw item text
            var index: usize = 0;
            while (index < item.text.len and col < content_width) {
                const cluster = ansi.nextDisplayCluster(item.text, index);
                if (cluster.end <= index) break;
                if (cluster.width == 0) {
                    index = cluster.end;
                    continue;
                }
                if (@as(usize, col) + cluster.width > content_width) break;
                row_window.writeCell(col, 0, .{
                    .char = .{
                        .grapheme = item.text[index..cluster.end],
                        .width = @intCast(cluster.width),
                    },
                    .style = item_style,
                });
                col += @intCast(cluster.width);
                index = cluster.end;
            }
        }

        // Draw scrollbar
        if (self.show_scrollbar and scrollbar_width > 0 and self.items.len > window.height) {
            const thumb_height = @max(1, (window.height * window.height) / self.items.len);
            const max_offset = self.items.len - window.height;
            const thumb_start = if (max_offset == 0) 0 else (start_index * (window.height - thumb_height)) / max_offset;
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

        return .{ .width = window.width, .height = @intCast(max_items) };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const List = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "list renders items vertically" {
    const list = List{
        .items = &[_]ListItem{
            .{ .text = "First" },
            .{ .text = "Second" },
            .{ .text = "Third" },
        },
    };

    var screen = try test_helpers.renderToScreen(list.drawComponent(), 10, 3);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "F", .{});
    try test_helpers.expectCell(&screen, 0, 1, "S", .{});
    try test_helpers.expectCell(&screen, 0, 2, "T", .{});
}

test "list bottom corner starts from the bottom" {
    const list = List{
        .items = &[_]ListItem{
            .{ .text = "A" },
            .{ .text = "B" },
            .{ .text = "C" },
        },
        .start_corner = .bottom_left,
    };

    var screen = try test_helpers.renderToScreen(list.drawComponent(), 10, 3);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "A", .{});
    try test_helpers.expectCell(&screen, 0, 1, "B", .{});
    try test_helpers.expectCell(&screen, 0, 2, "C", .{});
}

test "list scrollbar indicates overflow" {
    const list = List{
        .items = &[_]ListItem{
            .{ .text = "One" },
            .{ .text = "Two" },
            .{ .text = "Three" },
        },
        .show_scrollbar = true,
    };

    var screen = try test_helpers.renderToScreen(list.drawComponent(), 6, 2);
    defer screen.deinit(std.testing.allocator);

    const thumb = screen.readCell(5, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("█", thumb.char.grapheme);
}

test "list highlight symbol prefixes items" {
    const list = List{
        .items = &[_]ListItem{
            .{ .text = "Item" },
        },
        .highlight_symbol = "> ",
    };

    var screen = try test_helpers.renderToScreen(list.drawComponent(), 10, 2);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, ">", .{});
    try test_helpers.expectCell(&screen, 2, 0, "I", .{});
}
