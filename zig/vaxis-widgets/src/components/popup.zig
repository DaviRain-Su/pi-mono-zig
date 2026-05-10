const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Popup = struct {
    child: draw_mod.Component,
    width: u16,
    height: u16,
    style: vaxis.Cell.Style = .{},
    border_style: vaxis.Cell.Style = .{},
    show_border: bool = true,
    fill_char: []const u8 = " ",

    pub fn drawComponent(self: *const Popup) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn draw(
        self: *const Popup,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (window.width == 0 or window.height == 0) {
            return .{ .width = window.width, .height = 0 };
        }

        // Center the popup
        const popup_width = @min(self.width, window.width);
        const popup_height = @min(self.height, window.height);
        const x_off: u16 = (window.width - popup_width) / 2;
        const y_off: u16 = (window.height - popup_height) / 2;

        const popup_window = window.child(.{
            .x_off = x_off,
            .y_off = y_off,
            .width = popup_width,
            .height = popup_height,
        });

        // Fill background
        for (0..popup_height) |row| {
            for (0..popup_width) |col| {
                popup_window.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = self.fill_char, .width = 1 },
                    .style = self.style,
                });
            }
        }

        // Draw border
        if (self.show_border) {
            const border_options = vaxis.Window.BorderOptions{
                .where = .all,
                .style = self.border_style,
                .glyphs = .single_square,
            };
            const bordered = popup_window.child(.{ .border = border_options });
            _ = try self.child.draw(bordered, ctx);
        } else {
            _ = try self.child.draw(popup_window, ctx);
        }

        return .{ .width = window.width, .height = window.height };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Popup = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "popup centers child with border" {
    const text = @import("text.zig");
    const inner = text.Text{ .text = "X", .padding_x = 0, .padding_y = 0 };

    const popup = Popup{
        .child = inner.drawComponent(),
        .width = 6,
        .height = 3,
        .show_border = true,
    };

    var screen = try test_helpers.renderToScreen(popup.drawComponent(), 10, 5);
    defer screen.deinit(std.testing.allocator);

    // Border at center
    try test_helpers.expectCell(&screen, 2, 1, "┌", .{});
    try test_helpers.expectCell(&screen, 7, 1, "┐", .{});
}

test "popup without border fills area" {
    const text = @import("text.zig");
    const inner = text.Text{ .text = "Y", .padding_x = 0, .padding_y = 0 };

    const popup = Popup{
        .child = inner.drawComponent(),
        .width = 4,
        .height = 1,
        .show_border = false,
    };

    var screen = try test_helpers.renderToScreen(popup.drawComponent(), 8, 3);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 2, 1, "Y", .{});
}
