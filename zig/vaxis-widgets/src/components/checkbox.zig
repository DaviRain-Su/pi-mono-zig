const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Checkbox = struct {
    label: []const u8 = "",
    checked: bool = false,
    disabled: bool = false,
    style: vaxis.Cell.Style = .{},
    checked_style: vaxis.Cell.Style = .{ .bold = true },
    disabled_style: vaxis.Cell.Style = .{ .dim = true },
    checked_symbol: []const u8 = "[✓]",
    unchecked_symbol: []const u8 = "[ ]",

    pub fn drawComponent(self: *const Checkbox) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn draw(
        self: *const Checkbox,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        window.clear();

        const style = if (self.disabled) self.disabled_style else if (self.checked) self.checked_style else self.style;
        const symbol = if (self.checked) self.checked_symbol else self.unchecked_symbol;
        const symbol_width = ansi.visibleWidth(symbol);

        // Symbol
        var col: u16 = 0;
        var idx: usize = 0;
        while (idx < symbol.len and col < window.width) {
            const cluster = ansi.nextDisplayCluster(symbol, idx);
            if (cluster.end <= idx) break;
            window.writeCell(col, 0, .{
                .char = .{ .grapheme = symbol[idx..cluster.end], .width = @intCast(cluster.width) },
                .style = style,
            });
            col += @intCast(cluster.width);
            idx = cluster.end;
        }

        // Label
        if (self.label.len > 0 and col + 1 < window.width) {
            col += 1;
            const label_window = window.child(.{ .x_off = col });
            _ = label_window.printSegment(.{ .text = self.label, .style = style }, .{ .wrap = .none });
        }

        const total_width = symbol_width + if (self.label.len > 0) 1 + ansi.visibleWidth(self.label) else 0;
        return .{ .width = @min(total_width, window.width), .height = 1 };
    }

    pub fn toggle(self: *Checkbox) void {
        if (!self.disabled) {
            self.checked = !self.checked;
        }
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Checkbox = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "checkbox renders checked and unchecked states" {
    var cb = Checkbox{ .label = "Enable" };

    {
        var screen = try test_helpers.renderToScreen(cb.drawComponent(), 12, 1);
        defer screen.deinit(std.testing.allocator);
        try test_helpers.expectCell(&screen, 0, 0, "[", .{});
        try test_helpers.expectCell(&screen, 1, 0, " ", .{});
        try test_helpers.expectCell(&screen, 2, 0, "]", .{});
        try test_helpers.expectCell(&screen, 4, 0, "E", .{});
    }

    cb.toggle();
    try std.testing.expect(cb.checked);

    {
        var screen = try test_helpers.renderToScreen(cb.drawComponent(), 12, 1);
        defer screen.deinit(std.testing.allocator);
        try test_helpers.expectCell(&screen, 1, 0, "✓", .{ .bold = true });
    }
}

test "checkbox disabled prevents toggle" {
    var cb = Checkbox{ .checked = true, .disabled = true };
    cb.toggle();
    try std.testing.expect(cb.checked);
}
