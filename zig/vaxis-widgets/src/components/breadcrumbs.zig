const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const BreadcrumbItem = struct {
    label: []const u8,
    id: []const u8 = "",
};

pub const Breadcrumbs = struct {
    items: []const BreadcrumbItem,
    separator: []const u8 = " › ",
    style: vaxis.Cell.Style = .{},
    separator_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },
    last_style: vaxis.Cell.Style = .{ .bold = true },

    pub fn drawComponent(self: *const Breadcrumbs) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn draw(
        self: *const Breadcrumbs,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        window.clear();

        var x: u16 = 0;
        for (self.items, 0..) |item, i| {
            if (x >= window.width) break;
            const is_last = i == self.items.len - 1;
            const style = if (is_last) self.last_style else self.style;

            // Label
            var idx: usize = 0;
            while (idx < item.label.len and x < window.width) {
                const cluster = ansi.nextDisplayCluster(item.label, idx);
                if (cluster.end <= idx) break;
                window.writeCell(x, 0, .{
                    .char = .{ .grapheme = item.label[idx..cluster.end], .width = @intCast(cluster.width) },
                    .style = style,
                });
                x += @intCast(cluster.width);
                idx = cluster.end;
            }

            // Separator (not after last item)
            if (!is_last and x < window.width) {
                var sidx: usize = 0;
                while (sidx < self.separator.len and x < window.width) {
                    const cluster = ansi.nextDisplayCluster(self.separator, sidx);
                    if (cluster.end <= sidx) break;
                    window.writeCell(x, 0, .{
                        .char = .{ .grapheme = self.separator[sidx..cluster.end], .width = @intCast(cluster.width) },
                        .style = self.separator_style,
                    });
                    x += @intCast(cluster.width);
                    sidx = cluster.end;
                }
            }
        }

        return .{ .width = x, .height = 1 };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Breadcrumbs = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "breadcrumbs renders items with separator and bold last" {
    const items = &[_]BreadcrumbItem{
        .{ .label = "Home" },
        .{ .label = "Settings" },
        .{ .label = "Profile" },
    };

    const breadcrumbs = Breadcrumbs{ .items = items };

    var screen = try test_helpers.renderToScreen(breadcrumbs.drawComponent(), 30, 1);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Home") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Settings") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Profile") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "›") != null);

    const last_cell = screen.readCell(22, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(last_cell.style.bold);
}
