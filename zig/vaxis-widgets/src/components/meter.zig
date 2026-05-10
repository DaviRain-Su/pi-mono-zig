const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Meter = struct {
    value: f32 = 0, // -1.0 to 1.0, 0 is center
    label: []const u8 = "",
    show_value: bool = true,
    width: usize = 20,
    left_style: vaxis.Cell.Style = .{ .fg = .{ .index = 196 } },
    right_style: vaxis.Cell.Style = .{ .fg = .{ .index = 82 } },
    center_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },
    label_style: vaxis.Cell.Style = .{},
    track_char: []const u8 = "─",
    filled_char: []const u8 = "█",
    center_char: []const u8 = "│",

    pub fn drawComponent(self: *const Meter) draw_mod.Component {
        return .{ .ptr = self, .drawFn = drawOpaque };
    }

    pub fn draw(
        self: *const Meter,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        window.clear();

        const clamped = @max(-1.0, @min(1.0, self.value));
        const track_width = @min(self.width, @as(usize, window.width));
        const center: i32 = @intCast(track_width / 2);
        const fill_amount = @as(i32, @intFromFloat(@abs(clamped) * @as(f32, @floatFromInt(center))));

        var col: u16 = 0;

        // Label
        if (self.label.len > 0) {
            var idx: usize = 0;
            while (idx < self.label.len and col < window.width) {
                window.writeCell(col, 0, .{
                    .char = .{ .grapheme = self.label[idx .. idx + 1], .width = 1 },
                    .style = self.label_style,
                });
                col += 1;
                idx += 1;
            }
            col += 1;
        }

        const meter_start = col;
        for (0..track_width) |i| {
            const pos: i32 = @intCast(i);
            const char, const style = if (pos == center)
                .{ self.center_char, self.center_style }
            else if (clamped < 0 and pos < center and center - pos <= fill_amount)
                .{ self.filled_char, self.left_style }
            else if (clamped > 0 and pos > center and pos - center <= fill_amount)
                .{ self.filled_char, self.right_style }
            else
                .{ self.track_char, self.center_style };

            if (meter_start + i < window.width) {
                window.writeCell(@intCast(meter_start + i), 0, .{
                    .char = .{ .grapheme = char, .width = 1 },
                    .style = style,
                });
            }
        }

        // Value label
        if (self.show_value) {
            const value_text = try std.fmt.allocPrint(std.heap.page_allocator, " {d:.1}", .{clamped});
            defer std.heap.page_allocator.free(value_text);
            var vcol: u16 = @intCast(meter_start + track_width + 1);
            var vidx: usize = 0;
            while (vidx < value_text.len and vcol < window.width) {
                window.writeCell(vcol, 0, .{
                    .char = .{ .grapheme = value_text[vidx .. vidx + 1], .width = 1 },
                    .style = self.label_style,
                });
                vcol += 1;
                vidx += 1;
            }
        }

        return .{ .width = window.width, .height = 1 };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Meter = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "meter renders centered track with fill direction" {
    const m1 = Meter{ .value = -0.5, .width = 10 };
    var screen1 = try test_helpers.renderToScreen(m1.drawComponent(), 16, 1);
    defer screen1.deinit(std.testing.allocator);
    try test_helpers.expectCell(&screen1, 5, 0, "│", .{ .fg = .{ .index = 8 } });

    const m2 = Meter{ .value = 0.5, .width = 10 };
    var screen2 = try test_helpers.renderToScreen(m2.drawComponent(), 16, 1);
    defer screen2.deinit(std.testing.allocator);
}
