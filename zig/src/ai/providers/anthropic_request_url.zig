//! Anthropic Messages API URL from `base_url` (SDK-style `/v1/messages` normalization).
//! Extracted from `anthropic.zig` to shrink the provider shell.

const std = @import("std");
const shared_url = @import("../shared/url.zig");

pub fn buildMessagesUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    return shared_url.buildUrlV1Normalized("/messages", allocator, base_url);
}

test "buildMessagesUrl appends SDK-compatible Anthropic path" {
    const allocator = std.testing.allocator;

    const anthropic_url = try buildMessagesUrl(allocator, "https://api.anthropic.com/v1");
    defer allocator.free(anthropic_url);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", anthropic_url);

    const kimi_url = try buildMessagesUrl(allocator, "https://api.kimi.com/coding");
    defer allocator.free(kimi_url);
    try std.testing.expectEqualStrings("https://api.kimi.com/coding/v1/messages", kimi_url);
}
