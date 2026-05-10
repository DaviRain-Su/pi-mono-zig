const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Slider = struct {
    value: f32 = 0.5,
    min: f32 = 0,
    max: f32 = 1,
    step: f32 = 0.1,
    label: []const u8 = "",
    show_value: bool = true,
    width: usize = 20,
    track_char: []const u8 = "─",
    filled_char: []const u8 = "█",
    thumb_char: []const u8 = "●",
    style: vaxis.Cell.Style = .{},
    filled_style: vaxis.Cell.Style = .{ .fg = .{ .index = 39 } },
    thumb_style: vaxis.Cell.Style = .{ .fg = .{ .index = 39 } },

    pub fn drawComponent(self: *const Slider) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Slider,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        const clamped = @max(self.min, @min(self.max, self.value));
        const val_ratio = if (self.max > self.min)
            (clamped - self.min) / (self.max - self.min)
        else
            0;

        const track_width = @min(self.width, @as(usize, window.width));
        const thumb_pos = @min(track_width - 1, @as(usize, @intFromFloat(val_ratio * @as(f32, @floatFromInt(track_width - 1)))));

        // Label
        var col: u16 = 0;
        if (self.label.len > 0) {
            const label_window = window.child(.{ .height = 1 });
            _ = label_window.printSegment(.{ .text = self.label, .style = self.style }, .{ .wrap = .none });
            col += @intCast(@min(ansi.visibleWidth(self.label) + 1, window.width));
        }

        const track_window = window.child(.{ .x_off = col, .width = @intCast(track_width) });

        // Draw track
        for (0..track_width) |i| {
            const is_filled = i <= thumb_pos;
            const style = if (is_filled) self.filled_style else self.style;
            const char = if (is_filled) self.filled_char else self.track_char;
            track_window.writeCell(@intCast(i), 0, .{
                .char = .{ .grapheme = char, .width = 1 },
                .style = style,
            });
        }

        // Draw thumb over track
        if (thumb_pos < track_width) {
            track_window.writeCell(@intCast(thumb_pos), 0, .{
                .char = .{ .grapheme = self.thumb_char, .width = 1 },
                .style = self.thumb_style,
            });
        }

        // Value label
        if (self.show_value) {
            const value_text = try std.fmt.allocPrint(ctx.arena, " {d:.1}", .{clamped});
            const value_width = ansi.visibleWidth(value_text);
            if (col + track_width + value_width <= window.width) {
                const value_window = window.child(.{
                    .x_off = @intCast(col + track_width),
                    .height = 1,
                });
                _ = value_window.printSegment(.{ .text = value_text, .style = self.style }, .{ .wrap = .none });
            }
        }

        return .{ .width = window.width, .height = 1 };
    }

    pub fn increment(self: *Slider) void {
        self.value = @min(self.max, self.value + self.step);
    }

    pub fn decrement(self: *Slider) void {
        self.value = @max(self.min, self.value - self.step);
    }

    pub fn setRatio(self: *Slider, r: f32) void {
        self.value = self.min + @max(0, @min(1, r)) * (self.max - self.min);
    }

    pub fn ratio(self: *const Slider) f32 {
        if (self.max <= self.min) return 0;
        return @max(0, @min(1, (self.value - self.min) / (self.max - self.min)));
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Slider = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "slider renders track thumb and value" {
    var slider = Slider{
        .label = "Volume",
        .value = 0.7,
        .width = 10,
    };

    var screen = try test_helpers.renderToScreen(slider.drawComponent(), 24, 1);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Volume") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "0.7") != null);

    // thumb should be past midpoint
    try std.testing.expect(slider.ratio() > 0.5);
}

test "slider increment and decrement" {
    var slider = Slider{ .value = 0.5, .step = 0.1 };
    slider.increment();
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), slider.value, 0.001);
    slider.decrement();
    slider.decrement();
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), slider.value, 0.001);
}
