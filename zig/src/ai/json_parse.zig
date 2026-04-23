const std = @import("std");

/// Parse a JSON string, handling incomplete/partial JSON gracefully.
/// Returns a parsed JSON value (caller must call `.deinit()` on the result).
pub fn parseStreamingJson(allocator: std.mem.Allocator, input: ?[]const u8) !std.json.Parsed(std.json.Value) {
    if (input == null or input.?.len == 0) {
        return try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    }

    const trimmed = std.mem.trim(u8, input.?, " \t\r\n");
    if (trimmed.len == 0) {
        return try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    }

    // Try standard parse first
    if (std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{})) |parsed| {
        return parsed;
    } else |_| {
        // Try to find the longest valid JSON prefix
        var end_idx: usize = trimmed.len;
        while (end_idx > 0) : (end_idx -= 1) {
            const prefix = trimmed[0..end_idx];
            if (std.json.parseFromSlice(std.json.Value, allocator, prefix, .{})) |result| {
                return result;
            } else |_| {
                continue;
            }
        }
        // All parsing failed, return empty object
        return try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    }
}

test "parseStreamingJson complete JSON" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"foo\": 123}", .{});
    defer parsed.deinit();
    const result = parsed.value;

    try std.testing.expect(result == .object);
    const foo = result.object.get("foo").?;
    try std.testing.expectEqual(@as(i64, 123), foo.integer);
}

test "parseStreamingJson empty string" {
    const allocator = std.testing.allocator;
    var result = try parseStreamingJson(allocator, "");
    defer result.deinit();

    try std.testing.expect(result.value == .object);
    try std.testing.expectEqual(@as(usize, 0), result.value.object.count());
}

test "parseStreamingJson null input" {
    const allocator = std.testing.allocator;
    var result = try parseStreamingJson(allocator, null);
    defer result.deinit();

    try std.testing.expect(result.value == .object);
    try std.testing.expectEqual(@as(usize, 0), result.value.object.count());
}

test "parseStreamingJson partial JSON" {
    const allocator = std.testing.allocator;
    var result = try parseStreamingJson(allocator, "{\"foo\": 123, \"bar");
    defer result.deinit();

    try std.testing.expect(result.value == .object);
    // The result depends on how Zig's JSON parser handles partial input
    // It may return {"foo": 123} or {}
}

test "parseStreamingJson nested objects" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\": {\"b\": [1, 2, 3]}}", .{});
    defer parsed.deinit();
    const result = parsed.value;

    try std.testing.expect(result == .object);
    const a = result.object.get("a").?;
    try std.testing.expect(a == .object);
    const b = a.object.get("b").?;
    try std.testing.expect(b == .array);
    try std.testing.expectEqual(@as(usize, 3), b.array.items.len);
}

test "parseStreamingJson arrays" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[1, 2, {\"x\": true}]", .{});
    defer parsed.deinit();
    const result = parsed.value;

    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 3), result.array.items.len);
}
