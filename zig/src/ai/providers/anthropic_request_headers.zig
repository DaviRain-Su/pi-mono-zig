//! Outbound HTTP headers for Anthropic Messages API requests.

const std = @import("std");
const types = @import("../types.zig");
const anthropic_header_map = @import("anthropic_header_map.zig");
const anthropic_compat = @import("anthropic_compat.zig");
const anthropic_cache_retention = @import("anthropic_cache_retention.zig");

const CLAUDE_CODE_VERSION = "2.1.75";
const FINE_GRAINED_TOOL_STREAMING_BETA = "fine-grained-tool-streaming-2025-05-14";
const INTERLEAVED_THINKING_BETA = "interleaved-thinking-2025-05-14";

pub fn supportsAdaptiveThinking(model: types.Model) bool {
    return std.mem.indexOf(u8, model.id, "opus-4-6") != null or
        std.mem.indexOf(u8, model.id, "opus-4.6") != null or
        std.mem.indexOf(u8, model.id, "opus-4-7") != null or
        std.mem.indexOf(u8, model.id, "opus-4.7") != null or
        std.mem.indexOf(u8, model.id, "sonnet-4-6") != null or
        std.mem.indexOf(u8, model.id, "sonnet-4.6") != null;
}

pub fn isKimiCodingProvider(model: types.Model) bool {
    return std.mem.eql(u8, model.provider, "kimi-coding");
}

fn isOAuthToken(api_key: []const u8) bool {
    return std.mem.indexOf(u8, api_key, "sk-ant-oat") != null;
}

pub fn usesAnthropicOAuth(model: types.Model, api_key: []const u8) bool {
    return std.mem.eql(u8, model.provider, "anthropic") and isOAuthToken(api_key);
}

fn shouldUseFineGrainedToolStreamingBeta(model: types.Model, context: types.Context) bool {
    if (context.tools == null or context.tools.?.len == 0) return false;
    return !anthropic_compat.getAnthropicCompat(model).supports_eager_tool_input_streaming;
}

fn shouldUseInterleavedThinkingBeta(model: types.Model, options: ?types.StreamOptions) bool {
    if (supportsAdaptiveThinking(model)) return false;
    if (options) |stream_options| {
        const anthropic_opts = stream_options.providerOptions("anthropic");
        return anthropic_opts.interleaved_thinking orelse true;
    }
    return true;
}

pub fn buildAnthropicBetaHeader(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    api_key: []const u8,
) !?[]u8 {
    if (isKimiCodingProvider(model)) return null;

    var features: [4][]const u8 = undefined;
    var count: usize = 0;

    if (!std.mem.eql(u8, model.provider, "github-copilot") and usesAnthropicOAuth(model, api_key)) {
        features[count] = "claude-code-20250219";
        count += 1;
        features[count] = "oauth-2025-04-20";
        count += 1;
    }

    if (shouldUseFineGrainedToolStreamingBeta(model, context)) {
        features[count] = FINE_GRAINED_TOOL_STREAMING_BETA;
        count += 1;
    }

    if (shouldUseInterleavedThinkingBeta(model, options)) {
        features[count] = INTERLEAVED_THINKING_BETA;
        count += 1;
    }

    if (count == 0) return null;
    return try std.mem.join(allocator, ",", features[0..count]);
}

pub fn applyAuthHeaders(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    model: types.Model,
    options: ?types.StreamOptions,
) !void {
    const api_key = if (options) |stream_options| stream_options.api_key orelse "" else "";
    if (api_key.len == 0) return;

    if (std.mem.eql(u8, model.provider, "cloudflare-ai-gateway")) {
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
        defer allocator.free(authorization);
        try anthropic_header_map.putOwnedHeader(allocator, headers, "cf-aig-authorization", authorization);
    } else if (std.mem.eql(u8, model.provider, "github-copilot") or usesAnthropicOAuth(model, api_key)) {
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
        defer allocator.free(authorization);
        try anthropic_header_map.putOwnedHeader(allocator, headers, "Authorization", authorization);
    } else {
        try anthropic_header_map.putOwnedHeader(allocator, headers, "x-api-key", api_key);
    }
}

pub fn applyBaseAnthropicHeaders(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    model: types.Model,
) !void {
    try anthropic_header_map.putOwnedHeader(allocator, headers, "Content-Type", "application/json");
    try anthropic_header_map.putOwnedHeader(allocator, headers, "Accept", "application/json");
    if (!isKimiCodingProvider(model)) {
        try anthropic_header_map.putOwnedHeader(allocator, headers, "anthropic-dangerous-direct-browser-access", "true");
    }
    try anthropic_header_map.putOwnedHeader(allocator, headers, "anthropic-version", "2023-06-01");
}

pub fn applyDefaultAnthropicHeaders(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !void {
    const api_key = if (options) |stream_options| stream_options.api_key orelse "" else "";
    if (try buildAnthropicBetaHeader(allocator, model, context, options, api_key)) |beta_header| {
        defer allocator.free(beta_header);
        try anthropic_header_map.putOwnedHeader(allocator, headers, "anthropic-beta", beta_header);
    }

    if (usesAnthropicOAuth(model, api_key)) {
        const user_agent = try std.fmt.allocPrint(allocator, "claude-cli/{s}", .{CLAUDE_CODE_VERSION});
        defer allocator.free(user_agent);
        try anthropic_header_map.putOwnedHeader(allocator, headers, "user-agent", user_agent);
        try anthropic_header_map.putOwnedHeader(allocator, headers, "x-app", "cli");
    }
}

pub fn applySessionAffinityHeaders(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    model: types.Model,
    options: ?types.StreamOptions,
) !void {
    const stream_options = options orelse return;
    const session_id = stream_options.session_id orelse return;
    if (anthropic_cache_retention.resolveOptionsCacheRetention(options) == .none) return;
    if (!anthropic_compat.getAnthropicCompat(model).send_session_affinity_headers) return;
    try anthropic_header_map.putOwnedHeader(allocator, headers, "x-session-affinity", session_id);
}
