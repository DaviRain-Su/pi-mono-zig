const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const RadioOption = struct {
    label: []const u8,
    id: []const u8 = "",
    disabled: bool = false,
};

pub const Radio = struct {
    options: []const RadioOption,
    selected_index: usize = 0,
    style: vaxis.Cell.Style = .{},
    selected_style: vaxis.Cell.Style = .{ .bold = true },
    disabled_style: vaxis.Cell.Style = .{ .dim = true },
    selected_symbol: []const u8 = "(●)",
    unselected_symbol: []const u8 = "( )",

    pub fn drawComponent(self: *const Radio) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn draw(
        self: *const Radio,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        window.clear();

        var max_width: usize = 0;

        for (self.options, 0..) |option, i| {
            if (i >= window.height) break;
            const row_window = window.child(.{ .y_off = @intCast(i), .height = 1 });
            const is_selected = i == self.selected_index;
            const style = if (option.disabled) self.disabled_style else if (is_selected) self.selected_style else self.style;
            const symbol = if (is_selected) self.selected_symbol else self.unselected_symbol;
            const symbol_width = ansi.visibleWidth(symbol);

            var col: u16 = 0;
            var idx: usize = 0;
            while (idx < symbol.len and col < row_window.width) {
                const cluster = ansi.nextDisplayCluster(symbol, idx);
                if (cluster.end <= idx) break;
                row_window.writeCell(col, 0, .{
                    .char = .{ .grapheme = symbol[idx..cluster.end], .width = @intCast(cluster.width) },
                    .style = style,
                });
                col += @intCast(cluster.width);
                idx = cluster.end;
            }

            if (option.label.len > 0 and col + 1 < row_window.width) {
                col += 1;
                const label_window = row_window.child(.{ .x_off = col });
                _ = label_window.printSegment(.{ .text = option.label, .style = style }, .{ .wrap = .none });
            }

            const total_width = symbol_width + if (option.label.len > 0) 1 + ansi.visibleWidth(option.label) else 0;
            max_width = @max(max_width, total_width);
        }

        return .{ .width = @min(max_width, window.width), .height = @min(self.options.len, window.height) };
    }

    pub fn select(self: *Radio, index: usize) void {
        if (index < self.options.len and !self.options[index].disabled) {
            self.selected_index = index;
        }
    }

    pub fn selectedOption(self: *const Radio) ?RadioOption {
        if (self.options.len == 0) return null;
        return self.options[@min(self.selected_index, self.options.len - 1)];
    }

    pub fn handleKey(self: *Radio, key: @import("../keys.zig").Key) void {
        switch (key) {
            .up => self.moveSelection(-1),
            .down => self.moveSelection(1),
            else => {},
        }
    }

    fn moveSelection(self: *Radio, direction: i2) void {
        if (self.options.len == 0) return;
        const count: i32 = @intCast(self.options.len);
        const next = @as(i32, @intCast(self.selected_index)) + direction;
        if (next < 0 or next >= count) return;
        const new_idx: usize = @intCast(next);
        if (!self.options[new_idx].disabled) self.selected_index = new_idx;
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Radio = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "radio renders options and selection" {
    const options = &[_]RadioOption{
        .{ .label = "Red" },
        .{ .label = "Green" },
        .{ .label = "Blue", .disabled = true },
    };

    var radio = Radio{ .options = options, .selected_index = 1 };

    var screen = try test_helpers.renderToScreen(radio.drawComponent(), 10, 3);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 1, 0, " ", .{});
    try test_helpers.expectCell(&screen, 1, 1, "●", .{ .bold = true });

    radio.handleKey(.down);
    try std.testing.expectEqual(@as(usize, 1), radio.selected_index); // skipped disabled

    radio.handleKey(.up);
    try std.testing.expectEqual(@as(usize, 0), radio.selected_index);
}
