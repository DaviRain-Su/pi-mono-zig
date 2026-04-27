const std = @import("std");
const vaxis = @import("vaxis");
const component = @import("component.zig");

/// Copies plain text rows out of a vaxis screen for legacy line-oriented tests.
pub fn appendScreenRowsAsPlainLines(
    allocator: std.mem.Allocator,
    screen: *vaxis.Screen,
    width: usize,
    height: usize,
    lines: *component.LineList,
) std.mem.Allocator.Error!void {
    const row_count = @min(height, @as(usize, screen.height));
    const col_count = @min(width, @as(usize, screen.width));
    for (0..row_count) |row| {
        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);
        for (0..col_count) |col| {
            const cell = screen.readCell(@intCast(col), @intCast(row)) orelse continue;
            if (cell.char.grapheme.len == 0) {
                try builder.append(allocator, ' ');
            } else {
                try builder.appendSlice(allocator, cell.char.grapheme);
            }
        }
        try lines.append(allocator, try builder.toOwnedSlice(allocator));
    }
}

/// Copies rows out of an allocating screen for test compatibility helpers.
pub fn appendAllocatingScreenRowsAsPlainLines(
    allocator: std.mem.Allocator,
    screen: *vaxis.AllocatingScreen,
    width: usize,
    height: usize,
    lines: *component.LineList,
) std.mem.Allocator.Error!void {
    const row_count = @min(height, @as(usize, screen.height));
    const col_count = @min(width, @as(usize, screen.width));
    for (0..row_count) |row| {
        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);
        for (0..col_count) |col| {
            const cell = screen.readCell(@intCast(col), @intCast(row)) orelse continue;
            if (cell.char.grapheme.len == 0) {
                try builder.append(allocator, ' ');
            } else {
                try builder.appendSlice(allocator, cell.char.grapheme);
            }
        }
        try lines.append(allocator, try builder.toOwnedSlice(allocator));
    }
}

/// Renders plain legacy line lists into a vaxis window without interpreting ANSI.
pub fn renderLineListToWindow(window: vaxis.Window, lines: []const []const u8, _: std.mem.Allocator) std.mem.Allocator.Error!void {
    const row_count = @min(lines.len, @as(usize, window.height));
    for (lines[0..row_count], 0..) |line, row| {
        const row_window = window.child(.{
            .y_off = @intCast(row),
            .height = 1,
        });
        _ = row_window.printSegment(.{ .text = line }, .{ .wrap = .none });
    }
}
