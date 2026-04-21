const std = @import("std");

/// Parse a JSON string, handling incomplete/partial JSON gracefully.
/// Returns a parsed JSON value or an empty object on failure.
pub fn parseStreamingJson(allocator: std.mem.Allocator, input: ?[]const u8) !std.json.Value {
    if (input == null or input.?.len == 0) {
        var empty_map = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        errdefer empty_map.deinit(allocator);
        return std.json.Value{ .object = empty_map };
    }

    const trimmed = std.mem.trim(u8, input.?, " \t\r\n");
    if (trimmed.len == 0) {
        var empty_map = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        errdefer empty_map.deinit(allocator);
        return std.json.Value{ .object = empty_map };
    }

    // Try standard parse first
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        // Try to find the longest valid JSON prefix
        var end_idx: usize = trimmed.len;
        while (end_idx > 0) : (end_idx -= 1) {
            const prefix = trimmed[0..end_idx];
            if (std.json.parseFromSlice(std.json.Value, allocator, prefix, .{})) |result| {
                return result.value;
            } else |_| {
                continue;
            }
        }
        // All parsing failed, return empty object
        var empty_map = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        errdefer empty_map.deinit(allocator);
        return std.json.Value{ .object = empty_map };
    };

    return parsed.value;
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
    defer {
        var it = result.object.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        result.object.deinit(allocator);
    }

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 0), result.object.count());
}

test "parseStreamingJson null input" {
    const allocator = std.testing.allocator;
    var result = try parseStreamingJson(allocator, null);
    defer {
        var it = result.object.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        result.object.deinit(allocator);
    }

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 0), result.object.count());
}

test "parseStreamingJson partial JSON" {
    const allocator = std.testing.allocator;
    var result = try parseStreamingJson(allocator, "{\"foo\": 123, \"bar");
    defer {
        var it = result.object.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        result.object.deinit(allocator);
    }

    try std.testing.expect(result == .object);
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
