const std = @import("std");
const vaxis = @import("vaxis");
const component_mod = @import("../component.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Spacer = struct {
    lines: usize = 1,

    pub fn component(self: *const Spacer) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn drawComponent(self: *const Spacer) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
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

    pub fn renderInto(
        self: *const Spacer,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const effective_width = @max(width, 1);
        const blank_line = try allocator.alloc(u8, effective_width);
        defer allocator.free(blank_line);
        @memset(blank_line, ' ');

        for (0..self.lines) |_| {
            try component_mod.appendOwnedLine(lines, allocator, blank_line);
        }
    }

    fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const Spacer = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
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
