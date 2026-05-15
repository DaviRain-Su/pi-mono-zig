const std = @import("std");

const allocator = std.heap.c_allocator;
const Match = struct {
    id: []const u8,
    score: u32,
};

export fn pi_fuzzy_filter_batch(
    query_ptr: [*]const u8,
    query_len: usize,
    items_json_ptr: [*]const u8,
    items_json_len: usize,
    out_len: *usize,
) ?[*]u8 {
    out_len.* = 0;
    const query = query_ptr[0..query_len];
    const items_json = items_json_ptr[0..items_json_len];

    const output = fuzzyFilterBatch(query, items_json) catch return null;
    out_len.* = output.len;
    return output.ptr;
}

export fn pi_zig_free(ptr: ?[*]u8, len: usize) void {
    if (ptr) |valid_ptr| {
        allocator.free(valid_ptr[0..len]);
    }
}

fn fuzzyFilterBatch(query: []const u8, items_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, items_json, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidInput;

    var matches = std.ArrayList(Match).empty;
    defer matches.deinit(allocator);

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const id_value = item.object.get("id") orelse continue;
        const text_value = item.object.get("text") orelse continue;
        if (id_value != .string or text_value != .string) continue;

        if (scoreItem(query, text_value.string)) |score| {
            try matches.append(allocator, .{ .id = id_value.string, .score = score });
        }
    }

    std.mem.sort(Match, matches.items, {}, compareMatches);
    return try encodeMatches(matches.items);
}

fn compareMatches(_: void, left: Match, right: Match) bool {
    if (left.score == right.score) {
        return std.mem.order(u8, left.id, right.id) == .lt;
    }
    return left.score > right.score;
}

fn scoreItem(query: []const u8, text: []const u8) ?u32 {
    if (query.len == 0) return 0;

    var score: u32 = 0;
    var text_index: usize = 0;
    var previous_match: ?usize = null;

    for (query) |query_byte| {
        const needle = std.ascii.toLower(query_byte);
        var found: ?usize = null;
        while (text_index < text.len) : (text_index += 1) {
            if (std.ascii.toLower(text[text_index]) == needle) {
                found = text_index;
                text_index += 1;
                break;
            }
        }

        const match_index = found orelse return null;
        score += 1;
        if (previous_match) |previous| {
            if (match_index == previous + 1) score += 2;
        }
        previous_match = match_index;
    }

    return score;
}

fn encodeMatches(matches: []const Match) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '[');
    for (matches, 0..) |match, index| {
        if (index > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"id\":");
        try appendJsonString(&out, match.id);
        try out.appendSlice(allocator, ",\"score\":");
        const score_text = try std.fmt.allocPrint(allocator, "{}", .{match.score});
        defer allocator.free(score_text);
        try out.appendSlice(allocator, score_text);
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');

    return try out.toOwnedSlice(allocator);
}

fn appendJsonString(out: *std.ArrayList(u8), value: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = value }, .{});
    defer allocator.free(encoded);
    try out.appendSlice(allocator, encoded);
}

test "scoreItem matches ordered characters" {
    try std.testing.expectEqual(@as(?u32, 2), scoreItem("mn", "main"));
    try std.testing.expectEqual(@as(?u32, null), scoreItem("zz", "main"));
}

test "fuzzyFilterBatch encodes matches" {
    const output = try fuzzyFilterBatch("mn", "[{\"id\":\"main\",\"text\":\"src/main.rs\"}]");
    defer allocator.free(output);
    try std.testing.expectEqualStrings("[{\"id\":\"main\",\"score\":2}]", output);
}
