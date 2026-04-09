const std = @import("std");

/// Thin wrappers around std.json for our common patterns.
pub const Value = std.json.Value;
pub const ObjectMap = std.json.ObjectMap;
pub const Array = std.json.Array;

/// Parse a JSON string into a Value tree using the provided allocator.
pub fn parseValue(gpa: std.mem.Allocator, source: []const u8) !Value {
    return try std.json.parseFromSliceLeaky(Value, gpa, source, .{});
}

/// Stringify a value to a new string allocated with `gpa`.
pub fn stringifyValue(gpa: std.mem.Allocator, value: Value) ![]const u8 {
    var list = std.ArrayList(u8).init(gpa);
    defer list.deinit();
    try std.json.stringify(value, .{}, list.writer());
    return try list.toOwnedSlice();
}
