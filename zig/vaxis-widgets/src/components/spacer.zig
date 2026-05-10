const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Spacer = struct {
    lines: usize = 1,

    pub fn drawComponent(self: *const Spacer) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn setLines(self: *Spacer, lines: usize) void {
        self.lines = lines;
    }

    pub fn draw(
        self: *const Spacer,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        const rendered_height: u16 = @intCast(@min(self.lines, window.height));
        if (rendered_height > 0) {
            const fill_window = window.child(.{ .height = rendered_height });
            fill_window.clear();
        }
        return .{
            .width = window.width,
            .height = rendered_height,
        };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Spacer = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "spacer renders the requested number of blank rows" {
    const spacer = Spacer{ .lines = 3 };
    var screen = try test_helpers.renderToScreen(spacer.drawComponent(), 5, 3);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("     \n     \n     ", rendered);
    try test_helpers.expectCell(&screen, 0, 0, " ", .{});
    try test_helpers.expectCell(&screen, 4, 2, " ", .{});
}

test "spacer can render zero rows without mutating the screen" {
    const spacer = Spacer{ .lines = 0 };
    var screen = try test_helpers.renderToScreen(spacer.drawComponent(), 4, 2);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("    \n    ", rendered);
    try test_helpers.expectCell(&screen, 0, 0, " ", .{});
    try test_helpers.expectCell(&screen, 3, 1, " ", .{});
}
