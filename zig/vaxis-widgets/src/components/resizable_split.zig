const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const SplitDirection = enum {
    horizontal,
    vertical,
};

pub const ResizableSplit = struct {
    direction: SplitDirection = .horizontal,
    ratio: f32 = 0.5, // 0.0 to 1.0, first pane size ratio
    min_first: usize = 3,
    min_second: usize = 3,
    first: draw_mod.Component,
    second: draw_mod.Component,
    handle_width: u16 = 1,
    handle_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },

    pub fn drawComponent(self: *const ResizableSplit) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const ResizableSplit,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        const total = if (self.direction == .horizontal) window.width else window.height;
        if (total <= self.handle_width + self.min_first + self.min_second) {
            // Too small, just render first pane
            _ = try self.first.draw(window, ctx);
            return .{ .width = window.width, .height = window.height };
        }

        const available = total - self.handle_width;
        var first_size = @as(usize, @intFromFloat(@as(f32, @floatFromInt(total)) * self.ratio));
        first_size = @max(self.min_first, @min(available - self.min_second, first_size));
        const second_size = available - first_size;

        if (self.direction == .horizontal) {
            const first_window = window.child(.{
                .width = @intCast(first_size),
                .height = window.height,
            });
            _ = try self.first.draw(first_window, ctx);

            // Handle
            const handle_x: u16 = @intCast(first_size);
            for (0..window.height) |y| {
                window.writeCell(handle_x, @intCast(y), .{
                    .char = .{ .grapheme = "│", .width = 1 },
                    .style = self.handle_style,
                });
            }

            const second_window = window.child(.{
                .x_off = handle_x + self.handle_width,
                .width = @intCast(second_size),
                .height = window.height,
            });
            _ = try self.second.draw(second_window, ctx);
        } else {
            const first_window = window.child(.{
                .width = window.width,
                .height = @intCast(first_size),
            });
            _ = try self.first.draw(first_window, ctx);

            // Handle
            const handle_y: u16 = @intCast(first_size);
            for (0..window.width) |x| {
                window.writeCell(@intCast(x), handle_y, .{
                    .char = .{ .grapheme = "─", .width = 1 },
                    .style = self.handle_style,
                });
            }

            const second_window = window.child(.{
                .y_off = handle_y + self.handle_width,
                .width = window.width,
                .height = @intCast(second_size),
            });
            _ = try self.second.draw(second_window, ctx);
        }

        return .{ .width = window.width, .height = window.height };
    }

    pub fn moveHandle(self: *ResizableSplit, delta: f32) void {
        self.ratio = @max(0.0, @min(1.0, self.ratio + delta));
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const ResizableSplit = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "resizable split renders two panes with handle" {
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

    const left = StaticText{ .text = "LEFT" };
    const right = StaticText{ .text = "RIGHT" };

    const split = ResizableSplit{
        .direction = .horizontal,
        .ratio = 0.5,
        .first = left.drawComponent(),
        .second = right.drawComponent(),
    };

    var screen = try test_helpers.renderToScreen(split.drawComponent(), 20, 2);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "L", .{});
    try test_helpers.expectCell(&screen, 11, 0, "R", .{});
    try test_helpers.expectCell(&screen, 10, 0, "│", .{ .fg = .{ .index = 8 } });
}

test "resizable split vertical" {
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

    const top = StaticText{ .text = "TOP" };
    const bottom = StaticText{ .text = "BOT" };

    const split = ResizableSplit{
        .direction = .vertical,
        .ratio = 0.5,
        .min_first = 1,
        .min_second = 1,
        .first = top.drawComponent(),
        .second = bottom.drawComponent(),
    };

    var screen = try test_helpers.renderToScreen(split.drawComponent(), 10, 5);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "T", .{});
    try test_helpers.expectCell(&screen, 0, 3, "B", .{});
    try test_helpers.expectCell(&screen, 0, 2, "─", .{ .fg = .{ .index = 8 } });
}
