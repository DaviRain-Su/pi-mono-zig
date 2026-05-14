//! HTTP headers for OpenAI Chat Completions requests (shared by `openai.zig`).

const std = @import("std");
const types = @import("../types.zig");
const provider_json = @import("../shared/provider_json.zig");
const provider_stream = @import("../shared/provider_stream.zig");
const chat_payload = @import("openai_chat_payload.zig");
const asciiLowerAlloc = @import("../shared/string_utils.zig").asciiLowerAlloc;

fn processCacheRetentionEnv() ?[]const u8 {
    return chat_payload.processCacheRetentionEnv();
}

fn resolveOptionsCacheRetention(options: ?types.StreamOptions, pi_cache_retention_env: ?[]const u8) types.CacheRetention {
    return chat_payload.resolveOptionsCacheRetention(options, pi_cache_retention_env);
}

fn getCompat(model: types.Model) chat_payload.OpenAICompat {
    return chat_payload.getCompat(model);
}

pub fn buildRequestHeaders(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
) !std.StringHashMap([]const u8) {
    return buildRequestHeadersWithCacheRetentionEnv(allocator, model, options, processCacheRetentionEnv());
}

pub fn buildRequestHeadersWithCacheRetentionEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
    pi_cache_retention_env: ?[]const u8,
) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer provider_stream.deinitOwnedHeaders(allocator, &headers);
    const compat = getCompat(model);
    const cache_retention = resolveOptionsCacheRetention(options, pi_cache_retention_env);

    try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "Content-Type", "application/json");
    try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "Accept", "text/event-stream");

    const api_key = if (options) |opts| opts.api_key orelse "" else "";
    if (std.mem.trim(u8, api_key, &std.ascii.whitespace).len > 0) {
        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
        defer allocator.free(auth_header);
        if (std.mem.eql(u8, model.provider, "cloudflare-ai-gateway")) {
            try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "cf-aig-authorization", auth_header);
        } else {
            try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "Authorization", auth_header);
        }
    }

    try provider_stream.mergeHeadersCaseInsensitive(allocator, &headers, model.headers);
    if (options) |stream_options| {
        if (cache_retention != .none and stream_options.session_id != null and compat.send_session_affinity_headers) {
            const session_id = stream_options.session_id.?;
            try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "session_id", session_id);
            try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "x-client-request-id", session_id);
            try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "x-session-affinity", session_id);
        }
        try provider_stream.mergeHeadersCaseInsensitive(allocator, &headers, stream_options.headers);
    }

    return headers;
}

pub fn normalizeSemanticHeaders(
    allocator: std.mem.Allocator,
    headers: std.StringHashMap([]const u8),
) !std.json.ObjectMap {
    var semantic = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer semantic.deinit(allocator);

    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        const lower = try asciiLowerAlloc(allocator, entry.key_ptr.*);
        defer allocator.free(lower);
        const include = std.mem.eql(u8, lower, "authorization") or
            std.mem.eql(u8, lower, "content-type") or
            std.mem.eql(u8, lower, "session_id") or
            std.mem.eql(u8, lower, "x-client-request-id") or
            std.mem.eql(u8, lower, "x-session-affinity") or
            std.mem.startsWith(u8, lower, "x-fixture-");
        if (!include) continue;

        const value = if (std.mem.eql(u8, lower, "authorization"))
            if (entry.value_ptr.*.len > 0) "<redacted-present>" else "<redacted-empty>"
        else
            entry.value_ptr.*;

        const next_value = std.json.Value{ .string = try allocator.dupe(u8, value) };
        if (semantic.getPtr(lower)) |existing| {
            provider_json.freeValue(allocator, existing.*);
            existing.* = next_value;
        } else {
            try semantic.put(allocator, try allocator.dupe(u8, lower), next_value);
        }
    }

    return semantic;
}

test "buildRequestHeaders merges model and option headers" {
    const allocator = std.testing.allocator;

    var model_headers = std.StringHashMap([]const u8).init(allocator);
    defer model_headers.deinit();
    try model_headers.put("X-Model", "model");
    try model_headers.put("X-Shared", "model");

    var option_headers = std.StringHashMap([]const u8).init(allocator);
    defer option_headers.deinit();
    try option_headers.put("X-Option", "option");
    try option_headers.put("X-Shared", "option");

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
        .headers = model_headers,
    };

    var headers = try buildRequestHeaders(allocator, model, .{
        .api_key = "test-key",
        .headers = option_headers,
    });
    defer provider_stream.deinitOwnedHeaders(allocator, &headers);

    try std.testing.expectEqualStrings("application/json", headers.get("Content-Type").?);
    try std.testing.expectEqualStrings("Bearer test-key", headers.get("Authorization").?);
    try std.testing.expectEqualStrings("text/event-stream", headers.get("Accept").?);
    try std.testing.expectEqualStrings("model", headers.get("X-Model").?);
    try std.testing.expectEqualStrings("option", headers.get("X-Option").?);
    try std.testing.expectEqualStrings("option", headers.get("X-Shared").?);

    var anonymous_headers = try buildRequestHeaders(allocator, model, .{});
    defer provider_stream.deinitOwnedHeaders(allocator, &anonymous_headers);
    try std.testing.expect(anonymous_headers.get("Authorization") == null);
}

test "buildRequestHeaders applies case-insensitive override order" {
    const allocator = std.testing.allocator;

    var model_headers = std.StringHashMap([]const u8).init(allocator);
    defer model_headers.deinit();
    try model_headers.put("authorization", "Bearer model");
    try model_headers.put("accept", "application/json");
    try model_headers.put("X-Shared", "model");

    var option_headers = std.StringHashMap([]const u8).init(allocator);
    defer option_headers.deinit();
    try option_headers.put("AUTHORIZATION", "Bearer option");
    try option_headers.put("CONTENT-TYPE", "application/x-fixture");
    try option_headers.put("x-shared", "option");

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
        .headers = model_headers,
    };

    var headers = try buildRequestHeaders(allocator, model, .{
        .api_key = "test-key",
        .headers = option_headers,
    });
    defer provider_stream.deinitOwnedHeaders(allocator, &headers);

    try std.testing.expectEqual(@as(u32, 4), headers.count());
    try std.testing.expect(headers.get("Authorization") == null);
    try std.testing.expect(headers.get("authorization") == null);
    try std.testing.expectEqualStrings("Bearer option", headers.get("AUTHORIZATION").?);
    try std.testing.expect(headers.get("Content-Type") == null);
    try std.testing.expectEqualStrings("application/x-fixture", headers.get("CONTENT-TYPE").?);
    try std.testing.expect(headers.get("Accept") == null);
    try std.testing.expectEqualStrings("application/json", headers.get("accept").?);
    try std.testing.expect(headers.get("X-Shared") == null);
    try std.testing.expectEqualStrings("option", headers.get("x-shared").?);
}

test "buildRequestHeaders uses production cache retention resolver for session affinity" {
    const allocator = std.testing.allocator;

    var compat = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try compat.put(allocator, try allocator.dupe(u8, "sendSessionAffinityHeaders"), .{ .bool = true });
    const compat_value = std.json.Value{ .object = compat };
    defer provider_json.freeValue(allocator, compat_value);

    const model = types.Model{
        .id = "openrouter-session-affinity",
        .name = "OpenRouter Session Affinity",
        .api = "openai-completions",
        .provider = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
        .compat = compat_value,
    };

    var env_long_headers = try buildRequestHeadersWithCacheRetentionEnv(allocator, model, .{
        .session_id = "session-env-long",
        .cache_retention = .unset,
    }, "long");
    defer provider_stream.deinitOwnedHeaders(allocator, &env_long_headers);
    try std.testing.expectEqualStrings("session-env-long", env_long_headers.get("session_id").?);
    try std.testing.expectEqualStrings("session-env-long", env_long_headers.get("x-client-request-id").?);
    try std.testing.expectEqualStrings("session-env-long", env_long_headers.get("x-session-affinity").?);

    var explicit_none_headers = try buildRequestHeadersWithCacheRetentionEnv(allocator, model, .{
        .session_id = "session-none",
        .cache_retention = .none,
    }, "long");
    defer provider_stream.deinitOwnedHeaders(allocator, &explicit_none_headers);
    try std.testing.expect(explicit_none_headers.get("session_id") == null);
    try std.testing.expect(explicit_none_headers.get("x-client-request-id") == null);
    try std.testing.expect(explicit_none_headers.get("x-session-affinity") == null);
}
