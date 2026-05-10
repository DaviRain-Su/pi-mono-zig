const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const LogLevel = enum {
    trace,
    debug,
    info,
    warn,
    err,
};

pub const LogEntry = struct {
    text: []const u8,
    level: LogLevel = .info,
    timestamp: ?[]const u8 = null,
};

pub const LogViewer = struct {
    entries: []const LogEntry,
    follow_tail: bool = false,
    scroll_offset: usize = 0,
    show_level: bool = true,
    show_timestamp: bool = false,
    style: vaxis.Cell.Style = .{},
    trace_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },
    debug_style: vaxis.Cell.Style = .{ .fg = .{ .index = 39 } },
    info_style: vaxis.Cell.Style = .{},
    warn_style: vaxis.Cell.Style = .{ .fg = .{ .index = 214 } },
    err_style: vaxis.Cell.Style = .{ .fg = .{ .index = 196 } },
    timestamp_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },
    trace: ?Scrollbar = null,

    pub fn drawComponent(self: *const LogViewer) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn draw(
        self: *const LogViewer,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        window.clear();

        const level_width: u16 = if (self.show_level) 7 else 0;
        const ts_width: u16 = if (self.show_timestamp and self.entries.len > 0) 10 else 0;
        const prefix_width = level_width + ts_width;

        const visible_count = @min(self.entries.len, window.height);
        const start = if (self.follow_tail)
            if (self.entries.len > window.height) self.entries.len - window.height else 0
        else
            @min(self.scroll_offset, if (self.entries.len > window.height) self.entries.len - window.height else 0);

        for (0..visible_count) |i| {
            const entry_index = start + i;
            if (entry_index >= self.entries.len) break;
            const entry = self.entries[entry_index];
            const row_window = window.child(.{ .y_off = @intCast(i), .height = 1 });

            const style = switch (entry.level) {
                .trace => self.trace_style,
                .debug => self.debug_style,
                .info => self.info_style,
                .warn => self.warn_style,
                .err => self.err_style,
            };

            var col: u16 = 0;

            // Level badge
            if (self.show_level) {
                const level_text = levelString(entry.level);
                var idx: usize = 0;
                while (idx < level_text.len and col < level_width) {
                    row_window.writeCell(col, 0, .{
                        .char = .{ .grapheme = level_text[idx .. idx + 1], .width = 1 },
                        .style = style,
                    });
                    col += 1;
                    idx += 1;
                }
            }

            // Timestamp
            if (self.show_timestamp and entry.timestamp != null) {
                const ts = entry.timestamp.?;
                var idx: usize = 0;
                while (idx < ts.len and col < prefix_width) {
                    row_window.writeCell(col, 0, .{
                        .char = .{ .grapheme = ts[idx .. idx + 1], .width = 1 },
                        .style = self.timestamp_style,
                    });
                    col += 1;
                    idx += 1;
                }
            }

            // Content
            if (col < row_window.width) {
                const content_window = row_window.child(.{ .x_off = col });
                var idx: usize = 0;
                var ccol: u16 = 0;
                while (idx < entry.text.len and ccol < content_window.width) {
                    const cluster = ansi.nextDisplayCluster(entry.text, idx);
                    if (cluster.end <= idx) break;
                    const width: u16 = @intCast(cluster.width);
                    if (width == 0) {
                        idx = cluster.end;
                        continue;
                    }
                    if (ccol + width > content_window.width) break;
                    content_window.writeCell(ccol, 0, .{
                        .char = .{ .grapheme = entry.text[idx..cluster.end], .width = @intCast(width) },
                        .style = style,
                    });
                    ccol += width;
                    idx = cluster.end;
                }
            }
        }

        // Scrollbar
        if (self.trace) |sb| {
            if (self.entries.len > window.height) {
                _ = sb;
            }
        }

        return .{ .width = window.width, .height = visible_count };
    }

    pub fn scrollDown(self: *LogViewer, lines: usize) void {
        self.scroll_offset = @min(self.scroll_offset + lines, if (self.entries.len > 0) self.entries.len - 1 else 0);
    }

    pub fn scrollUp(self: *LogViewer, lines: usize) void {
        self.scroll_offset = if (self.scroll_offset > lines) self.scroll_offset - lines else 0;
    }

    fn levelString(level: LogLevel) []const u8 {
        return switch (level) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const LogViewer = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

// Forward declaration placeholder
const Scrollbar = @import("scrollbar.zig").Scrollbar;

test "log viewer renders colored levels" {
    const entries = &[_]LogEntry{
        .{ .text = "app started", .level = .info },
        .{ .text = "connection failed", .level = .err },
        .{ .text = "retrying...", .level = .warn },
    };

    const viewer = LogViewer{ .entries = entries, .show_level = true };

    var screen = try test_helpers.renderToScreen(viewer.drawComponent(), 40, 3);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "I", .{});
    try test_helpers.expectCell(&screen, 0, 1, "E", .{ .fg = .{ .index = 196 } });
    try test_helpers.expectCell(&screen, 0, 2, "W", .{ .fg = .{ .index = 214 } });
}

test "log viewer does not draw wide grapheme past narrow content" {
    const entries = &[_]LogEntry{.{ .text = "你", .level = .info }};
    const viewer = LogViewer{ .entries = entries, .show_level = false };

    var screen = try test_helpers.renderToScreen(viewer.drawComponent(), 1, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, " ", .{});
    try test_helpers.expectNoWideCellOverflow(&screen);
}
