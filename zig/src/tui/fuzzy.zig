const std = @import("std");

pub const FuzzyMatch = struct {
    matches: bool,
    score: f64,
};

pub fn fuzzyMatch(query: []const u8, text: []const u8) FuzzyMatch {
    const primary = matchQuery(query, text);
    if (primary.matches) return primary;

    var swapped_buffer: [256]u8 = undefined;
    const swapped = swappedAlphaNumeric(query, swapped_buffer[0..]) orelse return primary;
    const swapped_match = matchQuery(swapped, text);
    if (!swapped_match.matches) return primary;

    return .{
        .matches = true,
        .score = swapped_match.score + 5.0,
    };
}

pub fn fuzzyFilterStringItemsAlloc(
    allocator: std.mem.Allocator,
    items: []const []const u8,
    query: []const u8,
) ![]const []const u8 {
    if (std.mem.trim(u8, query, " \t\r\n").len == 0) return allocator.dupe([]const u8, items);

    const Ranked = struct {
        item: []const u8,
        score: f64,
        index: usize,
    };

    var ranked = std.ArrayList(Ranked).empty;
    defer ranked.deinit(allocator);

    for (items, 0..) |item, index| {
        var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
        var total_score: f64 = 0;
        var all_match = true;

        while (tokens.next()) |token| {
            const match = fuzzyMatch(token, item);
            if (!match.matches) {
                all_match = false;
                break;
            }
            total_score += match.score;
        }

        if (all_match) {
            try ranked.append(allocator, .{
                .item = item,
                .score = total_score,
                .index = index,
            });
        }
    }

    std.mem.sort(Ranked, ranked.items, {}, struct {
        fn lessThan(_: void, lhs: Ranked, rhs: Ranked) bool {
            if (lhs.score != rhs.score) return lhs.score < rhs.score;
            return lhs.index < rhs.index;
        }
    }.lessThan);

    const out = try allocator.alloc([]const u8, ranked.items.len);
    for (ranked.items, 0..) |entry, index| out[index] = entry.item;
    return out;
}

fn matchQuery(query: []const u8, text: []const u8) FuzzyMatch {
    const normalized_query = std.mem.trim(u8, query, " \t\r\n");
    if (normalized_query.len == 0) return .{ .matches = true, .score = 0 };
    if (normalized_query.len > text.len) return .{ .matches = false, .score = 0 };

    var query_index: usize = 0;
    var score: f64 = 0;
    var last_match_index: ?usize = null;
    var consecutive_matches: usize = 0;

    for (text, 0..) |byte, index| {
        if (query_index >= normalized_query.len) break;
        if (asciiLower(byte) != asciiLower(normalized_query[query_index])) continue;

        const is_word_boundary = index == 0 or isWordBoundary(text[index - 1]);
        if (last_match_index) |last| {
            if (last + 1 == index) {
                consecutive_matches += 1;
                score -= @as(f64, @floatFromInt(consecutive_matches * 5));
            } else {
                consecutive_matches = 0;
                score += @as(f64, @floatFromInt((index - last - 1) * 2));
            }
        } else {
            consecutive_matches = 0;
        }

        if (is_word_boundary) score -= 10;
        score += @as(f64, @floatFromInt(index)) * 0.1;

        last_match_index = index;
        query_index += 1;
    }

    if (query_index < normalized_query.len) return .{ .matches = false, .score = 0 };
    if (asciiEql(normalized_query, text)) score -= 100;

    return .{ .matches = true, .score = score };
}

fn swappedAlphaNumeric(query: []const u8, buffer: []u8) ?[]const u8 {
    if (query.len == 0 or query.len > buffer.len) return null;

    var split: ?usize = null;
    const first_is_alpha = std.ascii.isAlphabetic(query[0]);
    const first_is_digit = std.ascii.isDigit(query[0]);
    if (!first_is_alpha and !first_is_digit) return null;

    for (query, 0..) |byte, index| {
        if (first_is_alpha) {
            if (std.ascii.isAlphabetic(byte)) continue;
            if (std.ascii.isDigit(byte)) {
                split = index;
                break;
            }
            return null;
        }
        if (std.ascii.isDigit(byte)) continue;
        if (std.ascii.isAlphabetic(byte)) {
            split = index;
            break;
        }
        return null;
    }

    const boundary = split orelse return null;
    if (boundary == 0 or boundary == query.len) return null;
    for (query[boundary..]) |byte| {
        if (first_is_alpha and !std.ascii.isDigit(byte)) return null;
        if (first_is_digit and !std.ascii.isAlphabetic(byte)) return null;
    }

    @memcpy(buffer[0 .. query.len - boundary], query[boundary..]);
    @memcpy(buffer[query.len - boundary .. query.len], query[0..boundary]);
    return buffer[0..query.len];
}

fn asciiLower(byte: u8) u8 {
    return std.ascii.toLower(byte);
}

fn asciiEql(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn isWordBoundary(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or
        byte == '-' or byte == '_' or byte == '.' or byte == '/' or byte == ':';
}

test "fuzzyMatch rewards exact and boundary matches" {
    const exact = fuzzyMatch("readme", "README");
    const boundary = fuzzyMatch("rd", "README.md");
    const interior = fuzzyMatch("rd", "board");

    try std.testing.expect(exact.matches);
    try std.testing.expect(boundary.matches);
    try std.testing.expect(interior.matches);
    try std.testing.expect(exact.score < boundary.score);
    try std.testing.expect(boundary.score < interior.score);
}

test "fuzzyFilterStringItemsAlloc sorts best matches first" {
    const items = [_][]const u8{ "board", "README.md", "src/main.zig" };
    const filtered = try fuzzyFilterStringItemsAlloc(std.testing.allocator, &items, "rd");
    defer std.testing.allocator.free(filtered);

    try std.testing.expectEqual(@as(usize, 2), filtered.len);
    try std.testing.expectEqualStrings("README.md", filtered[0]);
}
