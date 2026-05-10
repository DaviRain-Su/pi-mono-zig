const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");
const constraints_mod = @import("../constraints.zig");

pub const SplitDirection = enum {
    horizontal,
    vertical,
};

pub const Split = struct {
    direction: SplitDirection = .horizontal,
    ratio: f64 = 0.5,
    first: draw_mod.Component,
    second: draw_mod.Component,

    pub fn drawComponent(self: *const Split) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn draw(
        self: *const Split,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (window.width == 0 or window.height == 0) {
            return .{ .width = window.width, .height = 0 };
        }

        const clamped_ratio = std.math.clamp(self.ratio, 0.0, 1.0);

        switch (self.direction) {
            .horizontal => {
                const first_width = @as(u16, @intFromFloat(@round(@as(f64, @floatFromInt(window.width)) * clamped_ratio)));
                const second_width = window.width - first_width;

                const first_window = window.child(.{
                    .width = first_width,
                    .height = window.height,
                });
                const second_window = window.child(.{
                    .x_off = first_width,
                    .width = second_width,
                    .height = window.height,
                });

                _ = try self.first.draw(first_window, ctx);
                _ = try self.second.draw(second_window, ctx);
            },
            .vertical => {
                const first_height = @as(u16, @intFromFloat(@round(@as(f64, @floatFromInt(window.height)) * clamped_ratio)));
                const second_height = window.height - first_height;

                const first_window = window.child(.{
                    .width = window.width,
                    .height = first_height,
                });
                const second_window = window.child(.{
                    .y_off = first_height,
                    .width = window.width,
                    .height = second_height,
                });

                _ = try self.first.draw(first_window, ctx);
                _ = try self.second.draw(second_window, ctx);
            },
        }

        return .{ .width = window.width, .height = window.height };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Split = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "split divides window horizontally" {
    const text = @import("text.zig");
    const left_text = text.Text{ .text = "L", .padding_x = 0, .padding_y = 0 };
    const right_text = text.Text{ .text = "R", .padding_x = 0, .padding_y = 0 };

    const split = Split{
        .direction = .horizontal,
        .ratio = 0.5,
        .first = left_text.drawComponent(),
        .second = right_text.drawComponent(),
    };

    var screen = try test_helpers.renderToScreen(split.drawComponent(), 10, 3);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "L", .{});
    try test_helpers.expectCell(&screen, 5, 0, "R", .{});
}

test "split divides window vertically" {
    const text = @import("text.zig");
    const top_text = text.Text{ .text = "T", .padding_x = 0, .padding_y = 0 };
    const bottom_text = text.Text{ .text = "B", .padding_x = 0, .padding_y = 0 };

    const split = Split{
        .direction = .vertical,
        .ratio = 0.5,
        .first = top_text.drawComponent(),
        .second = bottom_text.drawComponent(),
    };

    var screen = try test_helpers.renderToScreen(split.drawComponent(), 6, 4);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "T", .{});
    try test_helpers.expectCell(&screen, 0, 2, "B", .{});
}
