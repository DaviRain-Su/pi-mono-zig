//! OpenAI Chat Completions HTTP URL and path derived from `base_url`.
//! Extracted from `openai.zig` to keep the provider shell smaller.

const std = @import("std");
const shared_url = @import("../shared/url.zig");

pub const OpenAIChatRequestTarget = struct {
    url: []const u8,
    path: []const u8,

    pub fn deinit(self: OpenAIChatRequestTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.url);
    }
};

pub fn buildOpenAIChatRequestTarget(allocator: std.mem.Allocator, base_url: []const u8) !OpenAIChatRequestTarget {
    const url = try buildOpenAIChatRequestUrl(allocator, base_url);
    errdefer allocator.free(url);

    const path = try buildRequestPathFromUrl(allocator, url);
    errdefer allocator.free(path);

    return .{
        .url = url,
        .path = path,
    };
}

pub fn buildOpenAIChatRequestUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    return shared_url.buildUrl("/chat/completions", allocator, base_url);
}

pub fn buildRequestPathFromUrl(allocator: std.mem.Allocator, request_url: []const u8) ![]const u8 {
    const scheme = std.mem.indexOf(u8, request_url, "://") orelse return try allocator.dupe(u8, "/chat/completions");
    const after_scheme_index = scheme + 3;
    const after_origin = request_url[after_scheme_index..];
    const slash_index = std.mem.indexOfScalar(u8, after_origin, '/') orelse return try allocator.dupe(u8, "/");
    return try allocator.dupe(u8, request_url[after_scheme_index + slash_index ..]);
}

test "OpenAI Chat request target uses one production URL builder for trailing slash and base path" {
    const allocator = std.testing.allocator;

    const base_path_target = try buildOpenAIChatRequestTarget(allocator, "https://proxy.example.test/custom/openai/v1/");
    defer base_path_target.deinit(allocator);
    try std.testing.expectEqualStrings("https://proxy.example.test/custom/openai/v1/chat/completions", base_path_target.url);
    try std.testing.expectEqualStrings("/custom/openai/v1/chat/completions", base_path_target.path);

    const root_target = try buildOpenAIChatRequestTarget(allocator, "https://api.openai.com");
    defer root_target.deinit(allocator);
    try std.testing.expectEqualStrings("https://api.openai.com/chat/completions", root_target.url);
    try std.testing.expectEqualStrings("/chat/completions", root_target.path);

    const standard_target = try buildOpenAIChatRequestTarget(allocator, "https://api.openai.com/v1");
    defer standard_target.deinit(allocator);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", standard_target.url);
    try std.testing.expectEqualStrings("/v1/chat/completions", standard_target.path);
}
