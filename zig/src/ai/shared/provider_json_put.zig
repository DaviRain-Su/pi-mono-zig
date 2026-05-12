const std = @import("std");

/// Inserts `value` under a duplicated copy of `key` as a JSON bool.
pub fn putBoolValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: bool) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .bool = value });
}

/// Inserts `value` under a duplicated copy of `key` as a JSON string. Both the
/// key and the string contents are duplicated into `allocator`.
pub fn putStringValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .string = try allocator.dupe(u8, value) });
}

/// Inserts `value` under a duplicated copy of `key`. The caller transfers
/// ownership of `value` to `object`.
pub fn putObjectValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    try object.put(allocator, try allocator.dupe(u8, key), value);
}

/// Inserts `value` under a duplicated copy of `key` as a JSON integer. `value`
/// can be any integer type that fits via `@intCast` into `i64`.
pub fn putIntegerValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: anytype) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .integer = @intCast(value) });
}
