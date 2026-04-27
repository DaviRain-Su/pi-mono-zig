const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme.zig");

pub const Size = vaxis.vxfw.Size;

pub const DrawContext = struct {
    window: vaxis.Window,
    arena: std.mem.Allocator,
    theme: ?*const theme_mod.Theme = null,
};

pub const Component = struct {
    ptr: *const anyopaque,
    drawFn: *const fn (ptr: *const anyopaque, window: vaxis.Window, ctx: DrawContext) std.mem.Allocator.Error!Size,

    pub fn draw(self: Component, window: vaxis.Window, ctx: DrawContext) std.mem.Allocator.Error!Size {
        return self.drawFn(self.ptr, window, ctx);
    }
};

pub fn rootWindow(screen: *vaxis.Screen) vaxis.Window {
    return .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = screen,
    };
}

test "draw component can paint into a vaxis window and report its size" {
    const PaintDot = struct {
        const sentinel: u8 = 0;

        fn component() Component {
            return .{
                .ptr = &sentinel,
                .drawFn = draw,
            };
        }

        fn draw(_: *const anyopaque, window: vaxis.Window, ctx: DrawContext) std.mem.Allocator.Error!Size {
            _ = ctx;
            window.writeCell(0, 0, .{
                .char = .{
                    .grapheme = "•",
                    .width = 1,
                },
            });
            return .{
                .width = window.width,
                .height = 1,
            };
        }
    };

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3,
        .cols = 4,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);

    const window = rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const size = try PaintDot.component().draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    });

    try std.testing.expectEqual(Size{ .width = 4, .height = 1 }, size);
    const cell = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("•", cell.char.grapheme);
}
