const std = @import("std");
const provider_info = @import("provider_info.zig");

pub const ProviderDisplayName = struct {
    provider: []const u8,
    display_name: []const u8,
};

/// Built-in providers that carry a display name. Derived from the canonical
/// `provider_info.PROVIDERS` table; providers whose `display_name` is null are
/// omitted so this list preserves the exact set of entries the previous
/// hand-maintained array exposed.
pub const BUILT_IN_PROVIDER_DISPLAY_NAMES: []const ProviderDisplayName = blk: {
    const all = provider_info.PROVIDERS;
    var count: usize = 0;
    for (all) |entry| {
        if (entry.display_name != null) count += 1;
    }
    var result: [count]ProviderDisplayName = undefined;
    var index: usize = 0;
    for (all) |entry| {
        if (entry.display_name) |display_name| {
            result[index] = .{ .provider = entry.id, .display_name = display_name };
            index += 1;
        }
    }
    const final = result;
    break :blk &final;
};

pub fn builtInProviderDisplayName(provider: []const u8) ?[]const u8 {
    return provider_info.displayNameFor(provider);
}

test "builtInProviderDisplayName returns known provider names" {
    try std.testing.expectEqualStrings("OpenAI", builtInProviderDisplayName("openai").?);
    try std.testing.expectEqual(@as(?[]const u8, null), builtInProviderDisplayName("missing"));
}

test "BUILT_IN_PROVIDER_DISPLAY_NAMES only contains providers with display names" {
    for (BUILT_IN_PROVIDER_DISPLAY_NAMES) |entry| {
        try std.testing.expect(entry.display_name.len > 0);
    }
}
