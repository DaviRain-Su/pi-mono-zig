const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Toggle = struct {
    label: []const u8 = "",
    on: bool = false,
    disabled: bool = false,
    width: usize = 8,
    style: vaxis.Cell.Style = .{},
    on_style: vaxis.Cell.Style = .{ .fg = .{ .index = 82 } },
    off_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },
    disabled_style: vaxis.Cell.Style = .{ .dim = true },
    thumb_on: []const u8 = "●",
    thumb_off: []const u8 = "○",
    track_on: []const u8 = "━━━",
    track_off: []const u8 = "━━━",

    pub fn drawComponent(self: *const Toggle) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Toggle,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        window.clear();

        const style = if (self.disabled) self.disabled_style else if (self.on) self.on_style else self.off_style;
        const thumb = if (self.on) self.thumb_on else self.thumb_off;
        const track = if (self.on) self.track_on else self.track_off;

        // Draw track
        var col: u16 = 0;
        var idx: usize = 0;
        while (idx < track.len and col < window.width) {
            const cluster = @import("../ansi.zig").nextDisplayCluster(track, idx);
            if (cluster.end <= idx) break;
            window.writeCell(col, 0, .{
                .char = .{ .grapheme = track[idx..cluster.end], .width = @intCast(cluster.width) },
                .style = style,
            });
            col += @intCast(cluster.width);
            idx = cluster.end;
        }

        // Draw thumb at end (on) or start (off)
        const thumb_col: u16 = if (self.on) col -| @as(u16, @intCast(@import("../ansi.zig").visibleWidth(thumb))) else 0;
        if (thumb_col < window.width) {
            var tcol = thumb_col;
            var tidx: usize = 0;
            while (tidx < thumb.len and tcol < window.width) {
                const cluster = @import("../ansi.zig").nextDisplayCluster(thumb, tidx);
                if (cluster.end <= tidx) break;
                window.writeCell(tcol, 0, .{
                    .char = .{ .grapheme = thumb[tidx..cluster.end], .width = @intCast(cluster.width) },
                    .style = style,
                });
                tcol += @intCast(cluster.width);
                tidx = cluster.end;
            }
        }

        // Label
        if (self.label.len > 0 and col + 2 < window.width) {
            const label_window = window.child(.{ .x_off = col + 2 });
            _ = label_window.printSegment(.{ .text = self.label, .style = style }, .{ .wrap = .none });
        }

        const total_width = self.width + if (self.label.len > 0) 2 + @import("../ansi.zig").visibleWidth(self.label) else 0;
        return .{ .width = @min(total_width, window.width), .height = 1 };
    }

    pub fn toggle(self: *Toggle) void {
        if (!self.disabled) {
            self.on = !self.on;
        }
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Toggle = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "toggle renders on and off states" {
    var t = Toggle{ .label = "Auto" };

    {
        var screen = try test_helpers.renderToScreen(t.drawComponent(), 12, 1);
        defer screen.deinit(std.testing.allocator);
        // thumb at start (off)
        try test_helpers.expectCell(&screen, 0, 0, "○", .{ .fg = .{ .index = 8 } });
    }

    t.toggle();

    {
        var screen = try test_helpers.renderToScreen(t.drawComponent(), 12, 1);
        defer screen.deinit(std.testing.allocator);
        // thumb at end (on)
        try test_helpers.expectCell(&screen, 2, 0, "●", .{ .fg = .{ .index = 82 } });
    }
}
