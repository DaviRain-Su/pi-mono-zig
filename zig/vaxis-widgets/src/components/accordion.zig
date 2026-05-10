const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const AccordionItem = struct {
    label: []const u8,
    content: draw_mod.Component,
    expanded: bool = false,
    disabled: bool = false,
};

pub const Accordion = struct {
    items: []const AccordionItem,
    selected_index: usize = 0,
    style: vaxis.Cell.Style = .{},
    header_style: vaxis.Cell.Style = .{ .bold = true },
    selected_header_style: vaxis.Cell.Style = .{ .bold = true, .reverse = true },
    disabled_style: vaxis.Cell.Style = .{ .dim = true },
    expanded_symbol: []const u8 = "▼",
    collapsed_symbol: []const u8 = "▶",
    content_height: usize = 3,

    pub fn drawComponent(self: *const Accordion) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Accordion,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        var row: u16 = 0;
        for (self.items, 0..) |item, i| {
            if (row >= window.height) break;

            const is_selected = i == self.selected_index;
            const header_style = if (item.disabled) self.disabled_style else if (is_selected) self.selected_header_style else self.header_style;
            const symbol = if (item.expanded) self.expanded_symbol else self.collapsed_symbol;

            // Header row
            const header_window = window.child(.{ .y_off = row, .height = 1 });
            header_window.fill(.{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = header_style,
            });

            var col: u16 = 0;

            // Expand/collapse symbol
            var sidx: usize = 0;
            while (sidx < symbol.len and col < header_window.width) {
                const cluster = ansi.nextDisplayCluster(symbol, sidx);
                if (cluster.end <= sidx) break;
                header_window.writeCell(col, 0, .{
                    .char = .{ .grapheme = symbol[sidx..cluster.end], .width = @intCast(cluster.width) },
                    .style = header_style,
                });
                col += @intCast(cluster.width);
                sidx = cluster.end;
            }

            // Label
            if (col + 1 < header_window.width and item.label.len > 0) {
                col += 1;
                const label_window = header_window.child(.{ .x_off = col });
                _ = label_window.printSegment(.{ .text = item.label, .style = header_style }, .{ .wrap = .none });
            }

            row += 1;

            // Content (if expanded)
            if (item.expanded and row < window.height and !item.disabled) {
                const content_height: u16 = @intCast(@min(self.content_height, @as(usize, window.height) - row));
                if (content_height > 0) {
                    const content_window = window.child(.{
                        .y_off = row,
                        .height = content_height,
                        .x_off = 2,
                        .width = if (window.width > 2) window.width - 2 else 0,
                    });
                    _ = try item.content.draw(content_window, ctx);
                    row += content_height;
                }
            }
        }

        return .{ .width = window.width, .height = row };
    }

    pub fn toggle(self: *Accordion, index: usize) void {
        if (index < self.items.len and !self.items[index].disabled) {
            self.selected_index = index;
            // Mutable access needed for toggling expansion
        }
    }

    pub fn expand(self: *Accordion, index: usize) void {
        if (index < self.items.len and !self.items[index].disabled) {
            self.selected_index = index;
        }
    }

    pub fn handleKey(self: *Accordion, key: @import("../keys.zig").Key) void {
        switch (key) {
            .up => {
                if (self.selected_index > 0) {
                    self.selected_index -= 1;
                }
            },
            .down => {
                if (self.items.len > 0 and self.selected_index + 1 < self.items.len) {
                    self.selected_index += 1;
                }
            },
            .enter, .space => {
                // Toggle expansion on selected
            },
            else => {},
        }
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Accordion = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "accordion renders headers with expand symbols" {
    const StaticText = struct {
        text: []const u8,
        fn drawComponent(self: *const @This()) draw_mod.Component {
            return .{ .ptr = self, .drawFn = draw };
        }
        fn draw(ptr: *const anyopaque, w: vaxis.Window, _: draw_mod.DrawContext) std.mem.Allocator.Error!draw_mod.Size {
            const s: *const @This() = @ptrCast(@alignCast(ptr));
            _ = w.printSegment(.{ .text = s.text }, .{ .wrap = .none });
            return .{ .width = w.width, .height = 1 };
        }
    };

    const text = StaticText{ .text = "content" };
    const items = &[_]AccordionItem{
        .{ .label = "First", .content = text.drawComponent(), .expanded = true },
        .{ .label = "Second", .content = text.drawComponent() },
    };

    const accordion = Accordion{ .items = items, .content_height = 1 };

    var screen = try test_helpers.renderToScreen(accordion.drawComponent(), 20, 4);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "▼") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "▶") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "First") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "content") != null);
}
