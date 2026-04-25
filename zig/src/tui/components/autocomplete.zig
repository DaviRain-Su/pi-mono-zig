const std = @import("std");
const select_list = @import("select_list.zig");

pub const Item = select_list.SelectItem;

pub const Match = struct {
    matches: bool,
    score: i32,
};

const RankedItem = struct {
    item: Item,
    score: i32,
    original_index: usize,
};

pub fn fuzzyMatch(query: []const u8, text: []const u8) Match {
    if (query.len == 0) return .{ .matches = true, .score = 0 };

    const primary = fuzzyMatchNormalized(query, text);
    if (primary.matches) return primary;

    var swapped_buffer: [256]u8 = undefined;
    const swapped = buildSwappedQuery(query, swapped_buffer[0..]) orelse return primary;

    const swapped_match = fuzzyMatchNormalized(swapped, text);
    if (!swapped_match.matches) return primary;

    return .{
        .matches = true,
        .score = swapped_match.score + 50,
    };
}

pub fn fuzzyFilterAlloc(
    allocator: std.mem.Allocator,
    items: []const Item,
    query: []const u8,
) std.mem.Allocator.Error![]Item {
    if (std.mem.trim(u8, query, " \t\r\n").len == 0) {
        return allocator.dupe(Item, items);
    }

    var ranked = std.ArrayList(RankedItem).empty;
    defer ranked.deinit(allocator);

    for (items, 0..) |item, index| {
        var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
        var total_score: i32 = 0;
        var all_match = true;

        while (tokens.next()) |token| {
            const match = fuzzyMatch(token, item.display());
            if (!match.matches) {
                all_match = false;
                break;
            }
            total_score += match.score;
        }

        if (!all_match) continue;

        try ranked.append(allocator, .{
            .item = item,
            .score = total_score,
            .original_index = index,
        });
    }

    std.mem.sort(RankedItem, ranked.items, {}, lessThanRankedItem);

    const filtered = try allocator.alloc(Item, ranked.items.len);
    for (ranked.items, 0..) |entry, index| {
        filtered[index] = entry.item;
    }
    return filtered;
}

fn fuzzyMatchNormalized(query: []const u8, text: []const u8) Match {
    if (query.len == 0) return .{ .matches = true, .score = 0 };
    if (query.len > text.len) return .{ .matches = false, .score = 0 };

    var query_index: usize = 0;
    var score: i32 = 0;
    var last_match_index: ?usize = null;
    var consecutive_matches: usize = 0;

    for (text, 0..) |byte, index| {
        if (query_index >= query.len) break;
        if (asciiLower(byte) != asciiLower(query[query_index])) continue;

        const is_word_boundary = index == 0 or isWordBoundary(text[index - 1]);
        if (last_match_index) |last| {
            if (last + 1 == index) {
                consecutive_matches += 1;
                score -= @as(i32, @intCast(consecutive_matches * 50));
            } else {
                consecutive_matches = 0;
                score += @as(i32, @intCast((index - last - 1) * 20));
            }
        } else {
            consecutive_matches = 0;
        }

        if (is_word_boundary) score -= 100;
        score += @as(i32, @intCast(index));
        last_match_index = index;
        query_index += 1;
    }

    if (query_index < query.len) {
        return .{ .matches = false, .score = 0 };
    }

    return .{ .matches = true, .score = score };
}

fn buildSwappedQuery(query: []const u8, buffer: []u8) ?[]const u8 {
    if (query.len == 0 or query.len > buffer.len) return null;

    var split_index: usize = 0;
    while (split_index < query.len and std.ascii.isAlphabetic(query[split_index])) : (split_index += 1) {}
    if (split_index > 0 and split_index < query.len) {
        var digit_index = split_index;
        while (digit_index < query.len and std.ascii.isDigit(query[digit_index])) : (digit_index += 1) {}
        if (digit_index == query.len) {
            @memcpy(buffer[0 .. query.len - split_index], query[split_index..]);
            @memcpy(buffer[query.len - split_index .. query.len], query[0..split_index]);
            return buffer[0..query.len];
        }
    }

    split_index = 0;
    while (split_index < query.len and std.ascii.isDigit(query[split_index])) : (split_index += 1) {}
    if (split_index > 0 and split_index < query.len) {
        var alpha_index = split_index;
        while (alpha_index < query.len and std.ascii.isAlphabetic(query[alpha_index])) : (alpha_index += 1) {}
        if (alpha_index == query.len) {
            @memcpy(buffer[0 .. query.len - split_index], query[split_index..]);
            @memcpy(buffer[query.len - split_index .. query.len], query[0..split_index]);
            return buffer[0..query.len];
        }
    }

    return null;
}

fn lessThanRankedItem(_: void, lhs: RankedItem, rhs: RankedItem) bool {
    if (lhs.score != rhs.score) return lhs.score < rhs.score;
    return lhs.original_index < rhs.original_index;
}

fn asciiLower(byte: u8) u8 {
    return std.ascii.toLower(byte);
}

fn isWordBoundary(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '-', '_', '.', '/', ':' => true,
        else => false,
    };
}

test "fuzzy match rewards boundaries and consecutive matches" {
    const boundary = fuzzyMatch("rd", "README.md");
    const interior = fuzzyMatch("rd", "board");

    try std.testing.expect(boundary.matches);
    try std.testing.expect(interior.matches);
    try std.testing.expect(boundary.score < interior.score);
}

test "fuzzy filter sorts best matches first" {
    const allocator = std.testing.allocator;

    const items = [_]Item{
        .{ .value = "reload", .label = "reload" },
        .{ .value = "read", .label = "read" },
        .{ .value = "render", .label = "render" },
    };

    const filtered = try fuzzyFilterAlloc(allocator, &items, "rd");
    defer allocator.free(filtered);

    try std.testing.expectEqual(@as(usize, 3), filtered.len);
    try std.testing.expectEqualStrings("read", filtered[0].value);
}
