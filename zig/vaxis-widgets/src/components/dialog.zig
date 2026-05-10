const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const layout = @import("../layout.zig");
const test_helpers = @import("../test_helpers.zig");

pub const DialogButton = struct {
    label: []const u8,
    id: []const u8 = "",
};

pub const DialogResult = union(enum) {
    confirmed: []const u8,
    dismissed,
    ignored,
};

pub const Dialog = struct {
    title: []const u8 = "",
    title_style: vaxis.Cell.Style = .{ .bold = true },
    content: ?draw_mod.Component = null,
    content_text: []const u8 = "",
    buttons: []const DialogButton = &.{},
    button_style: vaxis.Cell.Style = .{},
    button_highlight_style: vaxis.Cell.Style = .{ .reverse = true },
    border_style: vaxis.Cell.Style = .{},
    width: ?usize = null,
    padding_x: usize = 2,
    padding_y: usize = 1,
    selected_button: usize = 0,

    pub fn drawComponent(self: *const Dialog) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Dialog,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        const dialog_width = self.width orelse @min(60, @as(usize, window.width));
        const dialog_height = self.computeHeight(dialog_width);

        const x_off = if (window.width > dialog_width) (window.width - dialog_width) / 2 else 0;
        const y_off = if (window.height > dialog_height) (window.height - dialog_height) / 2 else 0;

        const dialog_window = window.child(.{
            .x_off = @intCast(x_off),
            .y_off = @intCast(y_off),
            .width = @intCast(dialog_width),
            .height = @intCast(dialog_height),
        });

        self.drawFrame(dialog_window);

        const inner = dialog_window.child(.{
            .x_off = 1,
            .y_off = 1,
            .width = dialog_window.width -| 2,
            .height = dialog_window.height -| 2,
        });

        var row: u16 = 0;

        // Title
        if (self.title.len > 0) {
            const title_window = inner.child(.{ .y_off = row, .height = 1 });
            title_window.fill(.{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = self.title_style,
            });
            _ = title_window.printSegment(.{ .text = self.title, .style = self.title_style }, .{ .wrap = .none });
            row += 1;
        }

        // Separator between title and content
        if (self.title.len > 0 and (self.content_text.len > 0 or self.content != null)) {
            row += 1;
        }

        // Content
        if (self.content) |content| {
            const content_height = inner.height - row - 2;
            if (content_height > 0) {
                const content_window = inner.child(.{
                    .y_off = row,
                    .height = content_height,
                });
                _ = try content.draw(content_window, ctx);
            }
        } else if (self.content_text.len > 0) {
            const content_height = inner.height - row - 2;
            if (content_height > 0) {
                const content_window = inner.child(.{
                    .y_off = row,
                    .height = content_height,
                });
                _ = content_window.printSegment(.{ .text = self.content_text }, .{ .wrap = .word });
            }
        }

        // Buttons at bottom
        if (self.buttons.len > 0) {
            const button_row = inner.height - 1;
            const button_window = inner.child(.{ .y_off = button_row, .height = 1 });
            self.drawButtons(button_window);
        }

        return .{
            .width = window.width,
            .height = window.height,
        };
    }

    fn drawFrame(self: *const Dialog, window: vaxis.Window) void {
        const style = self.border_style;

        // Top border
        for (0..window.width) |col| {
            window.writeCell(@intCast(col), 0, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = style,
            });
        }

        // Bottom border
        for (0..window.width) |col| {
            window.writeCell(@intCast(col), window.height - 1, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = style,
            });
        }

        // Left and right borders
        for (1..window.height - 1) |row| {
            window.writeCell(0, @intCast(row), .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = style,
            });
            window.writeCell(window.width - 1, @intCast(row), .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = style,
            });
        }

        // Corners
        window.writeCell(0, 0, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = style });
        window.writeCell(window.width - 1, 0, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = style });
        window.writeCell(0, window.height - 1, .{ .char = .{ .grapheme = "└", .width = 1 }, .style = style });
        window.writeCell(window.width - 1, window.height - 1, .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = style });
    }

    fn drawButtons(self: *const Dialog, window: vaxis.Window) void {
        var total_width: usize = 0;
        for (self.buttons) |btn| {
            total_width += ansi.visibleWidth(btn.label) + 4; // [ label ]
        }
        total_width += (self.buttons.len -| 1) * 2; // spacing

        var x: u16 = if (window.width > total_width) @intCast((window.width - total_width) / 2) else 0;

        for (self.buttons, 0..) |btn, i| {
            const is_selected = i == self.selected_button;
            const style = if (is_selected) self.button_highlight_style else self.button_style;

            if (x >= window.width) break;

            // Left bracket
            window.writeCell(x, 0, .{ .char = .{ .grapheme = "[", .width = 1 }, .style = style });
            x += 1;

            // Label
            var col = x;
            var idx: usize = 0;
            while (idx < btn.label.len and col < window.width) {
                const cluster = ansi.nextDisplayCluster(btn.label, idx);
                if (cluster.end <= idx) break;
                window.writeCell(col, 0, .{
                    .char = .{ .grapheme = btn.label[idx..cluster.end], .width = @intCast(cluster.width) },
                    .style = style,
                });
                col += @intCast(cluster.width);
                idx = cluster.end;
            }
            x = col;

            // Right bracket
            if (x < window.width) {
                window.writeCell(x, 0, .{ .char = .{ .grapheme = "]", .width = 1 }, .style = style });
                x += 1;
            }

            // Spacing between buttons
            if (i + 1 < self.buttons.len) {
                x += 2;
            }
        }
    }

    fn computeHeight(self: *const Dialog, width: usize) usize {
        var height: usize = 2; // borders
        height += self.padding_y * 2;

        if (self.title.len > 0) {
            height += 1;
            if (self.content_text.len > 0 or self.content != null) {
                height += 1; // separator
            }
        }

        // Content height estimation
        if (self.content_text.len > 0) {
            const content_width = width -| 2 -| self.padding_x * 2;
            const lines = (ansi.visibleWidth(self.content_text) + content_width - 1) / @max(content_width, 1);
            height += @max(lines, 1);
        } else if (self.content != null) {
            height += 3; // minimum content height
        }

        if (self.buttons.len > 0) {
            height += 2; // button row + padding
        }

        return @min(height, 24);
    }

    pub fn handleKey(self: *Dialog, key: @import("../keys.zig").Key) DialogResult {
        switch (key) {
            .left => {
                if (self.selected_button > 0) {
                    self.selected_button -= 1;
                }
                return .ignored;
            },
            .right => {
                if (self.buttons.len > 0 and self.selected_button + 1 < self.buttons.len) {
                    self.selected_button += 1;
                }
                return .ignored;
            },
            .enter => {
                if (self.buttons.len > 0 and self.selected_button < self.buttons.len) {
                    return .{ .confirmed = self.buttons[self.selected_button].id };
                }
                return .dismissed;
            },
            .escape => return .dismissed,
            else => return .ignored,
        }
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Dialog = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "dialog renders frame title content and buttons" {
    const dialog = Dialog{
        .title = "Confirm",
        .content_text = "Are you sure?",
        .buttons = &[_]DialogButton{
            .{ .label = "Cancel", .id = "cancel" },
            .{ .label = "OK", .id = "ok" },
        },
        .width = 30,
    };

    var screen = try test_helpers.renderToScreen(dialog.drawComponent(), 30, 8);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Confirm") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Are you sure?") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[Cancel]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[OK]") != null);
}

test "dialog handleKey navigates buttons and confirms" {
    var dialog = Dialog{
        .buttons = &[_]DialogButton{
            .{ .label = "No", .id = "no" },
            .{ .label = "Yes", .id = "yes" },
        },
    };

    try std.testing.expectEqual(@as(usize, 0), dialog.selected_button);

    const right = dialog.handleKey(.right);
    try std.testing.expectEqual(@as(usize, 1), dialog.selected_button);
    try std.testing.expectEqual(DialogResult.ignored, right);

    const enter = dialog.handleKey(.enter);
    try std.testing.expectEqualStrings("yes", enter.confirmed);

    const esc = dialog.handleKey(.escape);
    try std.testing.expectEqual(DialogResult.dismissed, esc);
}
