const std = @import("std");

pub const LineList = std.ArrayList([]u8);

pub const Component = struct {
    ptr: *const anyopaque,
    renderIntoFn: *const fn (ptr: *const anyopaque, allocator: std.mem.Allocator, width: usize, lines: *LineList) std.mem.Allocator.Error!void,

    pub fn renderInto(self: Component, allocator: std.mem.Allocator, width: usize, lines: *LineList) std.mem.Allocator.Error!void {
        try self.renderIntoFn(self.ptr, allocator, width, lines);
    }
};

pub fn appendOwnedLine(lines: *LineList, allocator: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error!void {
    try lines.append(allocator, try allocator.dupe(u8, line));
}

pub fn freeLines(allocator: std.mem.Allocator, lines: *LineList) void {
    for (lines.items) |line| allocator.free(line);
    lines.deinit(allocator);
}
