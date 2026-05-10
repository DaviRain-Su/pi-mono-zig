const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const ToastLevel = enum {
    info,
    success,
    warning,
    err,

    pub fn icon(self: ToastLevel) []const u8 {
        return switch (self) {
            .info => "ℹ",
            .success => "✓",
            .warning => "⚠",
            .err => "✗",
        };
    }

    pub fn defaultStyle(self: ToastLevel) vaxis.Cell.Style {
        return switch (self) {
            .info => .{ .fg = .{ .index = 39 } },
            .success => .{ .fg = .{ .index = 82 } },
            .warning => .{ .fg = .{ .index = 214 } },
            .err => .{ .fg = .{ .index = 196 } },
        };
    }
};

pub const Toast = struct {
    message: []const u8,
    level: ToastLevel = .info,
    duration_ms: u32 = 3000,
    elapsed_ms: u32 = 0,
    style: ?vaxis.Cell.Style = null,

    pub fn isExpired(self: *const Toast) bool {
        return self.elapsed_ms >= self.duration_ms;
    }

    pub fn remainingMs(self: *const Toast) u32 {
        return if (self.duration_ms > self.elapsed_ms)
            self.duration_ms - self.elapsed_ms
        else
            0;
    }
};

pub const ToastStack = struct {
    toasts: std.ArrayList(Toast) = .empty,
    max_visible: usize = 3,
    position: Position = .top_right,
    width: usize = 32,
    border_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },

    pub const Position = enum {
        top_left,
        top_right,
        bottom_left,
        bottom_right,
    };

    pub fn init(allocator: std.mem.Allocator) ToastStack {
        _ = allocator;
        return .{
            .toasts = .empty,
        };
    }

    pub fn deinit(self: *ToastStack, allocator: std.mem.Allocator) void {
        self.toasts.deinit(allocator);
        self.* = undefined;
    }

    pub fn push(self: *ToastStack, allocator: std.mem.Allocator, toast: Toast) std.mem.Allocator.Error!void {
        try self.toasts.append(allocator, toast);
    }

    pub fn tick(self: *ToastStack, delta_ms: u32) void {
        for (self.toasts.items) |*toast| {
            toast.elapsed_ms += delta_ms;
        }

        // Remove expired toasts
        var i: usize = 0;
        while (i < self.toasts.items.len) {
            if (self.toasts.items[i].isExpired()) {
                _ = self.toasts.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn clear(self: *ToastStack) void {
        self.toasts.clearRetainingCapacity();
    }

    pub fn drawComponent(self: *const ToastStack) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn draw(
        self: *const ToastStack,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;

        const visible_count = @min(self.toasts.items.len, self.max_visible);
        if (visible_count == 0) return .{ .width = 0, .height = 0 };

        const toast_height: u16 = 3; // border + content
        const total_height = visible_count * @as(usize, toast_height) + (visible_count -| 1);

        const stack_x: u16 = switch (self.position) {
            .top_left, .bottom_left => 0,
            .top_right, .bottom_right => if (window.width > self.width) window.width - @as(u16, @intCast(self.width)) else 0,
        };
        const stack_y: u16 = switch (self.position) {
            .top_left, .top_right => 0,
            .bottom_left, .bottom_right => if (window.height > total_height) window.height - @as(u16, @intCast(total_height)) else 0,
        };

        const stack_window = window.child(.{
            .x_off = stack_x,
            .y_off = stack_y,
            .width = @min(@as(u16, @intCast(self.width)), window.width - stack_x),
            .height = @min(@as(u16, @intCast(total_height)), window.height - stack_y),
        });

        for (0..visible_count) |i| {
            const toast = self.toasts.items[i];
            const y_off: u16 = @intCast(i * 4); // 3 height + 1 spacing
            if (y_off + toast_height > stack_window.height) break;

            const toast_window = stack_window.child(.{
                .y_off = y_off,
                .height = toast_height,
            });
            self.drawToast(toast_window, toast);
        }

        return .{ .width = stack_window.width, .height = @intCast(total_height) };
    }

    fn drawToast(self: *const ToastStack, window: vaxis.Window, toast: Toast) void {
        const style = toast.style orelse toast.level.defaultStyle();
        const bstyle = self.border_style;

        // Border
        for (0..window.width) |col| {
            window.writeCell(@intCast(col), 0, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = bstyle,
            });
            window.writeCell(@intCast(col), window.height - 1, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = bstyle,
            });
        }
        for (1..window.height - 1) |row| {
            window.writeCell(0, @intCast(row), .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = bstyle,
            });
            window.writeCell(window.width - 1, @intCast(row), .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = bstyle,
            });
        }
        window.writeCell(0, 0, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = bstyle });
        window.writeCell(window.width - 1, 0, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = bstyle });
        window.writeCell(0, window.height - 1, .{ .char = .{ .grapheme = "└", .width = 1 }, .style = bstyle });
        window.writeCell(window.width - 1, window.height - 1, .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = bstyle });

        // Content: icon + message
        const inner = window.child(.{
            .x_off = 1,
            .y_off = 1,
            .width = window.width -| 2,
            .height = window.height -| 2,
        });

        inner.clear();

        const icon = toast.level.icon();
        const icon_width = ansi.visibleWidth(icon);

        // Icon
        if (icon_width <= inner.width) {
            inner.writeCell(0, 0, .{
                .char = .{ .grapheme = icon, .width = @intCast(icon_width) },
                .style = style,
            });
        }

        // Message (truncated if needed)
        const msg_x = @min(icon_width + 1, inner.width);
        const max_msg_width = if (inner.width > msg_x) inner.width - msg_x else 0;

        if (max_msg_width > 0) {
            const msg_window = inner.child(.{ .x_off = @intCast(msg_x) });
            var col: u16 = 0;
            var idx: usize = 0;
            while (idx < toast.message.len and col < max_msg_width) {
                const cluster = ansi.nextDisplayCluster(toast.message, idx);
                if (cluster.end <= idx) break;
                if (col + cluster.width > max_msg_width) break;
                msg_window.writeCell(col, 0, .{
                    .char = .{ .grapheme = toast.message[idx..cluster.end], .width = @intCast(cluster.width) },
                    .style = style,
                });
                col += @intCast(cluster.width);
                idx = cluster.end;
            }
        }
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const ToastStack = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "toast stack renders toasts with icons and borders" {
    const allocator = std.testing.allocator;

    var stack = ToastStack.init(allocator);
    defer stack.deinit(allocator);

    try stack.push(allocator, .{ .message = "Saved", .level = .success });
    try stack.push(allocator, .{ .message = "Error", .level = .err });

    var screen = try test_helpers.renderToScreen(stack.drawComponent(), 20, 8);
    defer screen.deinit(allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Saved") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Error") != null);
}

test "toast tick removes expired toasts" {
    const allocator = std.testing.allocator;

    var stack = ToastStack.init(allocator);
    defer stack.deinit(allocator);

    try stack.push(allocator, .{ .message = "Quick", .duration_ms = 100 });
    try stack.push(allocator, .{ .message = "Long", .duration_ms = 5000 });

    try std.testing.expectEqual(@as(usize, 2), stack.toasts.items.len);

    stack.tick(150);
    try std.testing.expectEqual(@as(usize, 1), stack.toasts.items.len);
    try std.testing.expectEqualStrings("Long", stack.toasts.items[0].message);
}
