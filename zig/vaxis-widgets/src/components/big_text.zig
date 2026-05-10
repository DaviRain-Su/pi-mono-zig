const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

/// A widget that renders text using large block characters.
/// Each glyph is 4 columns wide × 5 rows tall.
pub const BigText = struct {
    text: []const u8,
    style: vaxis.Cell.Style = .{},
    glyph_width: usize = 4,
    glyph_height: usize = 5,
    spacing: usize = 1,
    pixel_char: []const u8 = "█",

    pub fn drawComponent(self: *const BigText) draw_mod.Component {
        return .{ .ptr = self, .drawFn = drawOpaque };
    }

    pub fn draw(
        self: *const BigText,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        window.clear();

        var col: u16 = 0;
        for (self.text) |ch| {
            const glyph = lookupGlyph(ch);
            const gwidth: u16 = @intCast(self.glyph_width);
            const gheight: u16 = @intCast(self.glyph_height);

            if (col + gwidth > window.width) break;

            for (0..gheight) |row| {
                if (row >= window.height) break;
                const row_bits = glyph[row];
                for (0..gwidth) |c| {
                    if (c >= 4) continue;
                    const bit: u2 = @intCast(3 - c);
                    const is_pixel = (row_bits & (@as(u4, 1) << bit)) != 0;
                    if (is_pixel) {
                        window.writeCell(col + @as(u16, @intCast(c)), @intCast(row), .{
                            .char = .{ .grapheme = self.pixel_char, .width = 1 },
                            .style = self.style,
                        });
                    }
                }
            }

            col += gwidth + @as(u16, @intCast(self.spacing));
        }

        const total_width = if (self.text.len == 0) 0 else self.text.len * self.glyph_width + (self.text.len - 1) * self.spacing;
        return .{
            .width = @min(total_width, window.width),
            .height = @min(self.glyph_height, window.height),
        };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const BigText = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

/// 4×5 bitmap font. Each row is a u4 bitmask (MSB = leftmost column).
fn lookupGlyph(ch: u8) [5]u4 {
    return switch (ch) {
        'A' => .{ 0b0110, 0b1001, 0b1111, 0b1001, 0b1001 },
        'B' => .{ 0b1110, 0b1001, 0b1110, 0b1001, 0b1110 },
        'C' => .{ 0b0110, 0b1001, 0b1000, 0b1001, 0b0110 },
        'D' => .{ 0b1110, 0b1001, 0b1001, 0b1001, 0b1110 },
        'E' => .{ 0b1111, 0b1000, 0b1110, 0b1000, 0b1111 },
        'F' => .{ 0b1111, 0b1000, 0b1110, 0b1000, 0b1000 },
        'G' => .{ 0b0110, 0b1001, 0b1011, 0b1001, 0b0110 },
        'H' => .{ 0b1001, 0b1001, 0b1111, 0b1001, 0b1001 },
        'I' => .{ 0b1110, 0b0100, 0b0100, 0b0100, 0b1110 },
        'J' => .{ 0b0001, 0b0001, 0b0001, 0b1001, 0b0110 },
        'K' => .{ 0b1001, 0b1010, 0b1100, 0b1010, 0b1001 },
        'L' => .{ 0b1000, 0b1000, 0b1000, 0b1000, 0b1111 },
        'M' => .{ 0b1001, 0b1111, 0b1011, 0b1001, 0b1001 },
        'N' => .{ 0b1001, 0b1101, 0b1011, 0b1001, 0b1001 },
        'O' => .{ 0b0110, 0b1001, 0b1001, 0b1001, 0b0110 },
        'P' => .{ 0b1110, 0b1001, 0b1110, 0b1000, 0b1000 },
        'Q' => .{ 0b0110, 0b1001, 0b1001, 0b1010, 0b0101 },
        'R' => .{ 0b1110, 0b1001, 0b1110, 0b1010, 0b1001 },
        'S' => .{ 0b0111, 0b1000, 0b0110, 0b0001, 0b1110 },
        'T' => .{ 0b1111, 0b0100, 0b0100, 0b0100, 0b0100 },
        'U' => .{ 0b1001, 0b1001, 0b1001, 0b1001, 0b0110 },
        'V' => .{ 0b1001, 0b1001, 0b1001, 0b1010, 0b0100 },
        'W' => .{ 0b1001, 0b1001, 0b1011, 0b1111, 0b1001 },
        'X' => .{ 0b1001, 0b1001, 0b0110, 0b1001, 0b1001 },
        'Y' => .{ 0b1001, 0b1001, 0b0110, 0b0100, 0b0100 },
        'Z' => .{ 0b1111, 0b0001, 0b0110, 0b1000, 0b1111 },
        '0' => .{ 0b0110, 0b1001, 0b1001, 0b1001, 0b0110 },
        '1' => .{ 0b0100, 0b1100, 0b0100, 0b0100, 0b1110 },
        '2' => .{ 0b0110, 0b1001, 0b0010, 0b0100, 0b1111 },
        '3' => .{ 0b1110, 0b0001, 0b0110, 0b0001, 0b1110 },
        '4' => .{ 0b1001, 0b1001, 0b1111, 0b0001, 0b0001 },
        '5' => .{ 0b1111, 0b1000, 0b1110, 0b0001, 0b1110 },
        '6' => .{ 0b0110, 0b1000, 0b1110, 0b1001, 0b0110 },
        '7' => .{ 0b1111, 0b0001, 0b0010, 0b0100, 0b0100 },
        '8' => .{ 0b0110, 0b1001, 0b0110, 0b1001, 0b0110 },
        '9' => .{ 0b0110, 0b1001, 0b0111, 0b0001, 0b0110 },
        ' ' => .{ 0b0000, 0b0000, 0b0000, 0b0000, 0b0000 },
        '!' => .{ 0b0100, 0b0100, 0b0100, 0b0000, 0b0100 },
        '?' => .{ 0b0110, 0b1001, 0b0010, 0b0000, 0b0100 },
        '-' => .{ 0b0000, 0b0000, 0b1110, 0b0000, 0b0000 },
        '_' => .{ 0b0000, 0b0000, 0b0000, 0b0000, 0b1111 },
        ':' => .{ 0b0000, 0b0100, 0b0000, 0b0100, 0b0000 },
        '.' => .{ 0b0000, 0b0000, 0b0000, 0b0000, 0b0100 },
        else => .{ 0b0000, 0b0000, 0b0000, 0b0000, 0b0000 },
    };
}

test "big text renders block letters" {
    const big = BigText{ .text = "HI" };
    var screen = try test_helpers.renderToScreen(big.drawComponent(), 10, 5);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "█") != null);
}

test "big text renders digits" {
    const big = BigText{ .text = "42" };
    var screen = try test_helpers.renderToScreen(big.drawComponent(), 10, 5);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "█") != null);
}
