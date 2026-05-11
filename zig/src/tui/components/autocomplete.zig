const std = @import("std");
const select_list = @import("vaxis-widgets").components.select_list;
const fuzzy = @import("../fuzzy.zig");

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

/// Cfg used by the Item-oriented autocomplete helpers. Matches the previous
/// `fuzzyMatchNormalized` behaviour exactly: i32 scores, no query trim, no
/// newline boundaries, no exact-match bonus.
const AutocompleteFuzzyCfg = struct {
    pub const Score = i32;
    pub const boundary_bonus: Score = 100;
    pub const consecutive_penalty_unit: Score = 50;
    pub const gap_weight: Score = 20;
    pub const position_weight: Score = 1;
    pub const exact_match_bonus: Score = 0;
    pub const swap_bonus: Score = 50;
    pub const trim_query: bool = false;
    pub const boundary_includes_newline: bool = false;
};

const Matcher = fuzzy.FuzzyMatcher(AutocompleteFuzzyCfg);

pub fn fuzzyMatch(query: []const u8, text: []const u8) Match {
    const result = Matcher.matchWithSwap(query, text);
    return .{ .matches = result.matches, .score = result.score };
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

fn lessThanRankedItem(_: void, lhs: RankedItem, rhs: RankedItem) bool {
    if (lhs.score != rhs.score) return lhs.score < rhs.score;
    return lhs.original_index < rhs.original_index;
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
