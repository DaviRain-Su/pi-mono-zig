const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const IndeterminateProgress = struct {
    width: usize = 20,
    head_style: vaxis.Cell.Style = .{ .fg = .{ .index = 39 } },
    tail_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },
    track_char: []const u8 = "─",
    head_chars: []const u8 = "▶",
    tail_chars: []const u8 = "◀",

    pub fn drawComponent(self: *const IndeterminateProgress) draw_mod.Component {
        return .{ .ptr = self, .drawFn = drawOpaque };
    }

    pub fn draw(
        self: *const IndeterminateProgress,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        const w = @min(self.width, @as(usize, window.width));
        const head_pos = if (self.width > 0)
            @as(usize, @intCast(ctx.frame_count % @as(u64, @intCast(w))))
        else
            0;

        for (0..w) |i| {
            const is_head = i == head_pos;
            const is_tail = i == head_pos -| 1 and head_pos > 0;
            const char, const style = if (is_head)
                .{ self.head_chars, self.head_style }
            else if (is_tail)
                .{ self.tail_chars, self.tail_style }
            else
                .{ self.track_char, self.tail_style };
            window.writeCell(@intCast(i), 0, .{
                .char = .{ .grapheme = char, .width = 1 },
                .style = style,
            });
        }

        return .{ .width = @intCast(w), .height = 1 };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const IndeterminateProgress = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

pub const Spinner = struct {
    frames: []const u8 = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏",
    style: vaxis.Cell.Style = .{ .fg = .{ .index = 39 } },

    pub fn drawComponent(self: *const Spinner) draw_mod.Component {
        return .{ .ptr = self, .drawFn = drawOpaque };
    }

    pub fn draw(
        self: *const Spinner,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();
        const frame_idx = if (self.frames.len > 0)
            ctx.frame_count % @as(u64, @intCast(self.frames.len))
        else
            0;
        const cluster = @import("../ansi.zig").nextDisplayCluster(self.frames, @intCast(frame_idx * 3));
        window.writeCell(0, 0, .{
            .char = .{ .grapheme = self.frames[@intCast(frame_idx * 3)..cluster.end], .width = @intCast(cluster.width) },
            .style = self.style,
        });
        return .{ .width = 1, .height = 1 };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Spinner = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "indeterminate progress renders track with head" {
    const progress = IndeterminateProgress{ .width = 10 };
    var screen = try test_helpers.renderToScreen(progress.drawComponent(), 12, 1);
    defer screen.deinit(std.testing.allocator);
    try test_helpers.expectCell(&screen, 0, 0, "▶", .{ .fg = .{ .index = 39 } });
}
