const std = @import("std");

pub const LineList = std.ArrayList([]u8);

pub fn appendOwnedLine(lines: *LineList, allocator: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error!void {
    try lines.append(allocator, try allocator.dupe(u8, line));
}

pub fn freeLines(allocator: std.mem.Allocator, lines: *LineList) void {
    for (lines.items) |line| allocator.free(line);
    lines.deinit(allocator);
}
