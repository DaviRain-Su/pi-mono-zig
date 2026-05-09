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

