const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

/// A text span with inline styling. Part of a RichText composition.
pub const Span = struct {
    text: []const u8,
    style: vaxis.Cell.Style = .{},
};

/// Rich text with multiple styled spans rendered inline.
pub const RichText = struct {
    spans: []const Span,
    style: vaxis.Cell.Style = .{},

    pub fn drawComponent(self: *const RichText) draw_mod.Component {
        return .{ .ptr = self, .drawFn = drawOpaque };
    }

    pub fn draw(
        self: *const RichText,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        window.clear();

        var col: u16 = 0;
        var total_width: usize = 0;

        for (self.spans) |span| {
            const style = if (!span.style.eql(.{}))
                span.style
            else
                self.style;

            var idx: usize = 0;
            while (idx < span.text.len and col < window.width) {
                const cluster = ansi.nextDisplayCluster(span.text, idx);
                if (cluster.end <= idx) break;
                window.writeCell(col, 0, .{
                    .char = .{ .grapheme = span.text[idx..cluster.end], .width = @intCast(cluster.width) },
                    .style = style,
                });
                col += @intCast(cluster.width);
                idx = cluster.end;
                total_width += cluster.width;
            }
        }

        return .{ .width = @min(total_width, window.width), .height = 1 };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const RichText = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "rich text renders mixed styles inline" {
    const spans = &[_]Span{
        .{ .text = "Hello ", .style = .{} },
        .{ .text = "world", .style = .{ .fg = .{ .index = 82 }, .bold = true } },
        .{ .text = "!", .style = .{ .fg = .{ .index = 196 } } },
    };

    const rich = RichText{ .spans = spans };
    var screen = try test_helpers.renderToScreen(rich.drawComponent(), 20, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "H", .{});
    try test_helpers.expectCell(&screen, 6, 0, "w", .{ .fg = .{ .index = 82 }, .bold = true });
    try test_helpers.expectCell(&screen, 11, 0, "!", .{ .fg = .{ .index = 196 } });
}

test "rich text falls back to default style" {
    const spans = &[_]Span{
        .{ .text = "plain", .style = .{} },
    };

    const rich = RichText{ .spans = spans, .style = .{ .dim = true } };
    var screen = try test_helpers.renderToScreen(rich.drawComponent(), 10, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "p", .{ .dim = true });
}
