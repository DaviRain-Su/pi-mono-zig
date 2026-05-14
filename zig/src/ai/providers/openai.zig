const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const event_stream = @import("../event_stream.zig");
const provider_error = @import("../shared/provider_error.zig");
const provider_json = @import("../shared/provider_json.zig");
const provider_stream = @import("../shared/provider_stream.zig");
const resolve_api_key = @import("../shared/resolve_api_key.zig");
const cloudflare = @import("cloudflare.zig");
const github_copilot_headers = @import("github_copilot_headers.zig");
const chat_payload = @import("openai_chat_payload.zig");
const chat_sse = @import("openai_chat_sse.zig");
const openai_request_target = @import("openai_request_target.zig");
const openai_request_headers = @import("openai_request_headers.zig");
const test_stream_server = @import("test_stream_server.zig");

const parseSseStreamLines = chat_sse.parseSseStreamLines;
const parseChunkUsage = chat_sse.parseChunkUsage;
const mapStopReason = chat_sse.mapStopReason;

pub const OpenAIProvider = struct {
    const BaseProvider = provider_stream.DefineProvider("openai-completions", streamProduction);
    pub const api = BaseProvider.api;
    pub const stream = BaseProvider.stream;
    pub const streamSimple = BaseProvider.streamSimple;

    fn streamProduction(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
        event_stream_instance: *event_stream.AssistantMessageEventStream,
    ) !void {
        // Build request payload
        const payload = try buildFinalRequestPayload(allocator, model, context, options);
        defer provider_json.freeValue(allocator, payload);

        // Serialize payload to JSON
        var json_out: std.Io.Writer.Allocating = .init(allocator);
        const json_writer = &json_out.writer;
        defer json_out.deinit();

        try std.json.Stringify.value(payload, .{}, json_writer);

        // Resolve provider authentication.
        const resolved = try resolve_api_key.resolveApiKey(allocator, model, options);
        defer if (resolved) |r| r.deinit(allocator);

        if (resolved == null) {
            try resolve_api_key.pushMissingApiKeyError(allocator, event_stream_instance, model);
            return;
        }

        var resolved_options = if (options) |stream_options| stream_options else types.StreamOptions{};
        resolved_options.api_key = resolved.?.key;

        // Build HTTP request
        var headers = try openai_request_headers.buildRequestHeaders(allocator, model, resolved_options);
        defer provider_stream.deinitOwnedHeaders(allocator, &headers);

        if (std.mem.eql(u8, model.provider, "github-copilot")) {
            var copilot_hdrs = try github_copilot_headers.buildCopilotDynamicHeaders(allocator, context.messages);
            defer {
                var it = copilot_hdrs.valueIterator();
                while (it.next()) |v| allocator.free(v.*);
                copilot_hdrs.deinit();
            }
            try provider_stream.mergeHeadersCaseInsensitive(allocator, &headers, copilot_hdrs);
        }

        const resolved_base_url: ?[]const u8 = if (cloudflare.isCloudflareProvider(model.provider))
            try cloudflare.resolveCloudflareBaseUrl(allocator, model)
        else
            null;
        defer if (resolved_base_url) |url| allocator.free(url);

        const request_target = try openai_request_target.buildOpenAIChatRequestTarget(allocator, resolved_base_url orelse model.base_url);
        defer request_target.deinit(allocator);

        const req = http_client.HttpRequest{
            .method = .POST,
            .url = request_target.url,
            .headers = headers,
            .body = json_out.written(),
            .timeout_ms = if (options) |opts| opts.timeout_ms orelse 0 else 0,
            .aborted = if (options) |opts| opts.signal else null,
        };

        // Send request and process response
        var client = try http_client.HttpClient.init(allocator, io);
        defer client.deinit();

        var streaming = try client.requestStreaming(req);
        defer streaming.deinit();

        if (options) |opts| {
            if (opts.on_response) |on_response| {
                try provider_stream.invokeOnResponse(allocator, on_response, streaming.status, streaming.response_headers, model);
            }
        }

        if (streaming.status != 200) {
            const response_body = try streaming.readAllBounded(allocator, provider_error.MAX_PROVIDER_ERROR_BODY_READ_BYTES);
            defer allocator.free(response_body);
            try provider_error.pushHttpStatusError(allocator, event_stream_instance, model, streaming.status, response_body);
            return;
        }

        // Parse SSE stream incrementally from lines
        try parseSseStreamLines(allocator, event_stream_instance, &streaming, model, options);
    }
};

/// Removes unpaired Unicode surrogate characters from text.
/// Valid paired surrogates (proper emoji) are preserved.
pub fn sanitizeSurrogates(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return chat_payload.sanitizeSurrogates(allocator, text);
}

/// Recursively free a JSON value and all its children, including ObjectMap keys.
/// Use this only for values where ALL keys and strings were allocated by the same allocator.
pub fn freeOwnedJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    provider_json.freeValue(allocator, value);
}

fn processCacheRetentionEnv() ?[]const u8 {
    return chat_payload.processCacheRetentionEnv();
}

pub fn buildFinalRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    return chat_payload.buildFinalRequestPayload(allocator, model, context, options);
}

fn buildFinalRequestPayloadWithCacheRetentionEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    pi_cache_retention_env: ?[]const u8,
) !std.json.Value {
    return chat_payload.buildFinalRequestPayloadWithCacheRetentionEnv(allocator, model, context, options, pi_cache_retention_env);
}

/// Build the request payload for OpenAI chat completions API
pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    return chat_payload.buildRequestPayload(allocator, model, context, options);
}

/// Parse an OpenAI Chat SSE byte slice and return the final AssistantMessage.
/// This is a test/parity helper that wraps the extracted SSE stream parser.
/// The caller owns the returned message; free with the same allocator used for parsing.
pub fn parseSseAssistantMessageFromSlice(
    allocator: std.mem.Allocator,
    io: std.Io,
    sse_data: []const u8,
    model: types.Model,
) !types.AssistantMessage {
    return chat_sse.parseSseAssistantMessageFromSlice(allocator, io, sse_data, model);
}

/// Parse SSE line and extract JSON data.
pub fn parseSseLine(line: []const u8) ?[]const u8 {
    return chat_sse.parseSseLine(line);
}

/// Parse a streaming chunk from OpenAI.
/// Returns a parsed JSON value or null. Caller must call `.deinit()` on the result.
pub fn parseChunk(allocator: std.mem.Allocator, data: []const u8) !?std.json.Parsed(std.json.Value) {
    return chat_sse.parseChunk(allocator, data);
}

pub fn buildResolvedCompatSnapshotValue(allocator: std.mem.Allocator, model: types.Model) !std.json.Value {
    return chat_payload.buildResolvedCompatSnapshotValue(allocator, model);
}

pub fn buildRequestSnapshotValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    return buildRequestSnapshotValueWithCacheRetentionEnv(allocator, model, context, options, processCacheRetentionEnv());
}

pub fn buildRequestSnapshotValueWithCacheRetentionEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    pi_cache_retention_env: ?[]const u8,
) !std.json.Value {
    var payload = try buildFinalRequestPayloadWithCacheRetentionEnv(allocator, model, context, options, pi_cache_retention_env);
    errdefer provider_json.freeValue(allocator, payload);

    var headers = try openai_request_headers.buildRequestHeadersWithCacheRetentionEnv(allocator, model, options, pi_cache_retention_env);
    defer provider_stream.deinitOwnedHeaders(allocator, &headers);

    var snapshot = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer snapshot.deinit(allocator);

    const request_target = try openai_request_target.buildOpenAIChatRequestTarget(allocator, model.base_url);
    defer request_target.deinit(allocator);

    try snapshot.put(allocator, try allocator.dupe(u8, "baseUrl"), std.json.Value{ .string = try allocator.dupe(u8, model.base_url) });
    try snapshot.put(allocator, try allocator.dupe(u8, "headers"), .{ .object = try openai_request_headers.normalizeSemanticHeaders(allocator, headers) });
    try snapshot.put(allocator, try allocator.dupe(u8, "jsonPayload"), payload);
    payload = .null;
    try snapshot.put(allocator, try allocator.dupe(u8, "method"), std.json.Value{ .string = try allocator.dupe(u8, "POST") });
    try snapshot.put(allocator, try allocator.dupe(u8, "path"), std.json.Value{ .string = try allocator.dupe(u8, request_target.path) });
    try snapshot.put(allocator, try allocator.dupe(u8, "url"), std.json.Value{ .string = try allocator.dupe(u8, request_target.url) });

    return .{ .object = snapshot };
}

test {
    _ = @import("openai_tests.zig");
}
