const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Placeholder = struct {
    text: []const u8 = "",
    icon: []const u8 = "",
    style: vaxis.Cell.Style = .{ .dim = true },

    pub fn drawComponent(self: *const Placeholder) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Placeholder,
        window: vaxis.Window,
        _: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (window.width == 0 or window.height == 0) {
            return .{ .width = window.width, .height = 0 };
        }

        const text_width = ansi.visibleWidth(self.text);
        const icon_width = ansi.visibleWidth(self.icon);
        const total_width = text_width + icon_width + if (self.icon.len > 0 and self.text.len > 0) @as(usize, 1) else @as(usize, 0);

        const row: u16 = @min(window.height / 2, window.height - 1);
        const start_col: u16 = if (total_width < window.width)
            @intCast((window.width - total_width) / 2)
        else
            0;

        var col = start_col;

        if (self.icon.len > 0) {
            var index: usize = 0;
            while (index < self.icon.len and col < window.width) {
                const cluster = ansi.nextDisplayCluster(self.icon, index);
                if (cluster.end <= index) break;
                window.writeCell(col, row, .{
                    .char = .{
                        .grapheme = self.icon[index..cluster.end],
                        .width = @intCast(cluster.width),
                    },
                    .style = self.style,
                });
                col += @intCast(cluster.width);
                index = cluster.end;
            }
            if (self.text.len > 0 and col < window.width) {
                window.writeCell(col, row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = self.style,
                });
                col += 1;
            }
        }

        var index: usize = 0;
        while (index < self.text.len and col < window.width) {
            const cluster = ansi.nextDisplayCluster(self.text, index);
            if (cluster.end <= index) break;
            window.writeCell(col, row, .{
                .char = .{
                    .grapheme = self.text[index..cluster.end],
                    .width = @intCast(cluster.width),
                },
                .style = self.style,
            });
            col += @intCast(cluster.width);
            index = cluster.end;
        }

        return .{ .width = window.width, .height = @max(1, window.height) };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Placeholder = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "placeholder renders centered text" {
    const placeholder = Placeholder{
        .text = "Empty",
    };

    var screen = try test_helpers.renderToScreen(placeholder.drawComponent(), 10, 3);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 2, 1, "E", .{ .dim = true });
}

test "placeholder renders icon and text" {
    const placeholder = Placeholder{
        .icon = "○",
        .text = "None",
    };

    var screen = try test_helpers.renderToScreen(placeholder.drawComponent(), 10, 3);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 2, 1, "○", .{ .dim = true });
    try test_helpers.expectCell(&screen, 4, 1, "N", .{ .dim = true });
}
