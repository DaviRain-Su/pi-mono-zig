const std = @import("std");
const env_api_keys = @import("../env_api_keys.zig");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");
const finalize = @import("../shared/finalize.zig");
const provider_error = @import("../shared/provider_error.zig");
const provider_json = @import("../shared/provider_json.zig");
const sse_loop = @import("../shared/sse_loop.zig");
const cloudflare = @import("cloudflare.zig");
const github_copilot_headers = @import("github_copilot_headers.zig");
const test_stream_server = @import("test_stream_server.zig");

const AnthropicError = error{
    UnknownStopReason,
    InvalidAnthropicChunk,
};

const CLAUDE_CODE_IDENTITY = "You are Claude Code, Anthropic's official CLI for Claude.";
const CLAUDE_CODE_VERSION = "2.1.75";
const TOOL_PLACEHOLDER_TEXT = "";
const FINE_GRAINED_TOOL_STREAMING_BETA = "fine-grained-tool-streaming-2025-05-14";
const INTERLEAVED_THINKING_BETA = "interleaved-thinking-2025-05-14";

const CurrentBlock = union(enum) {
    text: std.ArrayList(u8),
    thinking: struct {
        text: std.ArrayList(u8),
        signature: ?[]const u8,
        redacted: bool,
    },
    tool_call: struct {
        id: []const u8,
        name: []const u8,
        partial_json: std.ArrayList(u8),
    },
};

const BlockEntry = struct {
    anthropic_index: usize,
    event_index: usize,
    block: CurrentBlock,
};

const AnthropicCompat = struct {
    supports_eager_tool_input_streaming: bool = true,
    supports_long_cache_retention: bool = true,
};

const ResolvedOptions = struct {
    options: ?types.StreamOptions,
    owned_api_key: ?[]u8 = null,

    fn deinit(self: ResolvedOptions, allocator: std.mem.Allocator) void {
        if (self.owned_api_key) |api_key| allocator.free(api_key);
    }
};

pub const AnthropicProvider = struct {
    pub const api = "anthropic-messages";

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
        errdefer stream_instance.deinit();

        streamProduction(allocator, io, model, context, options, &stream_instance) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => emitSetupRuntimeFailure(&stream_instance, model, options, err),
        };
        return stream_instance;
    }

    fn streamProduction(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
        stream_instance: *event_stream.AssistantMessageEventStream,
    ) !void {
        const resolved_options = try resolveStreamOptions(allocator, model, options);
        defer resolved_options.deinit(allocator);

        // After resolving env-based credentials, missing or blank auth must
        // surface as a deterministic terminal stream error rather than a
        // silent unauthenticated request. Mirrors the TypeScript
        // `No API key for provider:` diagnostic.
        const resolved_api_key = if (resolved_options.options) |stream_options|
            stream_options.api_key orelse ""
        else
            "";
        if (resolved_api_key.len == 0) {
            try pushMissingApiKeyError(allocator, stream_instance, model);
            return;
        }

        var payload = try buildRequestPayload(allocator, model, context, resolved_options.options);
        defer freeJsonValue(allocator, payload);

        if (resolved_options.options) |stream_options| {
            if (stream_options.on_payload) |callback| {
                if (try callback(allocator, payload, model)) |replacement| {
                    freeJsonValue(allocator, payload);
                    payload = replacement;
                }
            }
        }

        const json_body = try std.json.Stringify.valueAlloc(allocator, payload, .{});
        defer allocator.free(json_body);

        const resolved_base_url: ?[]const u8 = if (cloudflare.isCloudflareProvider(model.provider))
            try cloudflare.resolveCloudflareBaseUrl(allocator, model)
        else
            null;
        defer if (resolved_base_url) |b| allocator.free(b);

        const url = try buildMessagesUrl(allocator, resolved_base_url orelse model.base_url);
        defer allocator.free(url);

        var headers = std.StringHashMap([]const u8).init(allocator);
        defer deinitOwnedHeaders(allocator, &headers);
        try applyBaseAnthropicHeaders(allocator, &headers, model);
        try applyAuthHeaders(allocator, &headers, model, resolved_options.options);
        try applyDefaultAnthropicHeaders(allocator, &headers, model, context, resolved_options.options);
        try mergeHeaders(allocator, &headers, model.headers);
        if (resolved_options.options) |stream_options| {
            try mergeHeaders(allocator, &headers, stream_options.headers);
        }

        if (std.mem.eql(u8, model.provider, "github-copilot")) {
            var copilot_hdrs = try github_copilot_headers.buildCopilotDynamicHeaders(allocator, context.messages);
            defer {
                var it = copilot_hdrs.valueIterator();
                while (it.next()) |v| allocator.free(v.*);
                copilot_hdrs.deinit();
            }
            try mergeHeaders(allocator, &headers, copilot_hdrs);
        }

        var client = try http_client.HttpClient.init(allocator, io);
        defer client.deinit();

        var response = try client.requestStreaming(.{
            .method = .POST,
            .url = url,
            .headers = headers,
            .body = json_body,
            .timeout_ms = if (resolved_options.options) |stream_options| stream_options.timeout_ms orelse 0 else 0,
            .aborted = if (resolved_options.options) |stream_options| stream_options.signal else null,
        });
        defer response.deinit();

        if (resolved_options.options) |stream_options| {
            if (stream_options.on_response) |callback| {
                var response_headers = try normalizedResponseHeaders(allocator, response.response_headers);
                defer deinitOwnedHeaders(allocator, &response_headers);
                try callback(response.status, response_headers, model);
            }
        }

        if (response.status != 200) {
            const response_body = try response.readAllBounded(allocator, provider_error.MAX_PROVIDER_ERROR_BODY_READ_BYTES);
            defer allocator.free(response_body);
            try provider_error.pushHttpStatusError(allocator, stream_instance, model, response.status, response_body);
            return;
        }

        try parseSseStreamLines(allocator, stream_instance, &response, model, context, resolved_options.options);
    }

    pub fn streamSimple(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        return stream(allocator, io, model, context, options);
    }
};

fn emitSetupRuntimeFailure(
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
    options: ?types.StreamOptions,
    err: anyerror,
) void {
    const effective_err = if (provider_error.isAbortRequested(options)) error.RequestAborted else err;
    const error_message = provider_error.runtimeErrorMessage(effective_err);
    const message = types.AssistantMessage{
        .role = "assistant",
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = provider_error.runtimeStopReason(effective_err),
        .error_message = error_message,
        .timestamp = 0,
    };
    provider_error.pushTerminalRuntimeError(stream_ptr, message);
}

/// Emit a deterministic sanitized terminal stream error when no API key is
/// available. Mirrors the TypeScript `No API key for provider:` diagnostic and
/// must not leak environment values, credential-store paths, bearer tokens, or
/// local auth paths.
fn pushMissingApiKeyError(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
) !void {
    const error_message = try std.fmt.allocPrint(
        allocator,
        "No API key for provider: {s}",
        .{model.provider},
    );
    const message = types.AssistantMessage{
        .role = "assistant",
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = error_message,
        .timestamp = 0,
    };
    stream_ptr.push(.{
        .event_type = .error_event,
        .error_message = error_message,
        .message = message,
    });
    stream_ptr.end(message);
}

fn buildMessagesUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, trimmed, "/v1")) {
        return std.fmt.allocPrint(allocator, "{s}/messages", .{trimmed});
    }
    return std.fmt.allocPrint(allocator, "{s}/v1/messages", .{trimmed});
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

fn resolveStreamOptions(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
) !ResolvedOptions {
    return resolveStreamOptionsWithEnvMap(allocator, model, options, null);
}

fn resolveStreamOptionsWithEnvMap(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
    env_map: ?*const std.process.Environ.Map,
) !ResolvedOptions {
    var resolved = ResolvedOptions{ .options = options };
    const provided_api_key = if (options) |stream_options| stream_options.api_key else null;
    if (provided_api_key) |api_key| {
        if (api_key.len > 0) return resolved;
    }

    const env_api_key = if (env_map) |map|
        try env_api_keys.getEnvApiKeyFromMap(allocator, map, model.provider)
    else
        try env_api_keys.getEnvApiKey(allocator, model.provider);

    resolved.owned_api_key = env_api_key;
    if (env_api_key) |api_key| {
        var updated = options orelse types.StreamOptions{};
        updated.api_key = api_key;
        resolved.options = updated;
    } else if (options) |stream_options| {
        resolved.options = stream_options;
    }

    return resolved;
}

pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    const compat = getAnthropicCompat(model);
    var payload = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer payload.deinit(allocator);

    try payload.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, model.id) });
    try payload.put(
        allocator,
        try allocator.dupe(u8, "max_tokens"),
        .{ .integer = @intCast(if (options) |stream_options| stream_options.max_tokens orelse (model.max_tokens / 3) else (model.max_tokens / 3)) },
    );
    try payload.put(allocator, try allocator.dupe(u8, "stream"), .{ .bool = true });

    const cache_control = try buildCacheControl(allocator, compat, if (options) |stream_options| stream_options.cache_retention else .short);
    defer if (cache_control) |value| freeJsonValue(allocator, value);

    const is_oauth = usesAnthropicOAuth(model, if (options) |stream_options| stream_options.api_key orelse "" else "");
    const system_value = try buildSystemPromptValue(allocator, context.system_prompt, is_oauth, cache_control);
    if (system_value) |value| {
        try payload.put(allocator, try allocator.dupe(u8, "system"), value);
    }

    const messages_value = try buildMessagesValue(allocator, context.messages, context.tools, is_oauth, cache_control);
    try payload.put(allocator, try allocator.dupe(u8, "messages"), messages_value);

    if (context.tools) |tools| {
        const tools_value = try buildToolsValue(allocator, tools, is_oauth, compat.supports_eager_tool_input_streaming, cache_control);
        try payload.put(allocator, try allocator.dupe(u8, "tools"), tools_value);
    }

    if (options) |stream_options| {
        if (stream_options.temperature) |temperature| {
            if (stream_options.anthropic_thinking_enabled != true) {
                try payload.put(allocator, try allocator.dupe(u8, "temperature"), .{ .float = temperature });
            }
        }

        if (model.reasoning) {
            if (stream_options.anthropic_thinking_enabled == true) {
                const display = anthropicThinkingDisplayString(stream_options.anthropic_thinking_display orelse .summarized);
                var thinking = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                if (supportsAdaptiveThinking(model)) {
                    try thinking.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "adaptive") });
                    try thinking.put(allocator, try allocator.dupe(u8, "display"), .{ .string = try allocator.dupe(u8, display) });
                    try payload.put(allocator, try allocator.dupe(u8, "thinking"), .{ .object = thinking });

                    if (stream_options.anthropic_effort) |effort| {
                        var output_config = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                        try output_config.put(allocator, try allocator.dupe(u8, "effort"), .{ .string = try allocator.dupe(u8, anthropicEffortString(effort)) });
                        try payload.put(allocator, try allocator.dupe(u8, "output_config"), .{ .object = output_config });
                    }
                } else {
                    try thinking.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "enabled") });
                    try thinking.put(
                        allocator,
                        try allocator.dupe(u8, "budget_tokens"),
                        .{ .integer = @intCast(stream_options.anthropic_thinking_budget_tokens orelse 1024) },
                    );
                    try thinking.put(allocator, try allocator.dupe(u8, "display"), .{ .string = try allocator.dupe(u8, display) });
                    try payload.put(allocator, try allocator.dupe(u8, "thinking"), .{ .object = thinking });
                }
            } else if (stream_options.anthropic_thinking_enabled == false) {
                var thinking = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try thinking.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "disabled") });
                try payload.put(allocator, try allocator.dupe(u8, "thinking"), .{ .object = thinking });
            }
        }

        if (stream_options.metadata) |metadata| {
            if (metadata == .object) {
                if (metadata.object.get("user_id")) |user_id| {
                    if (user_id == .string) {
                        var metadata_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                        try metadata_obj.put(allocator, try allocator.dupe(u8, "user_id"), .{ .string = try allocator.dupe(u8, user_id.string) });
                        try payload.put(allocator, try allocator.dupe(u8, "metadata"), .{ .object = metadata_obj });
                    }
                }
            }
        }

        if (stream_options.anthropic_tool_choice) |tool_choice| {
            try payload.put(allocator, try allocator.dupe(u8, "tool_choice"), try buildToolChoiceValue(allocator, tool_choice, is_oauth));
        }
    }

    return .{ .object = payload };
}

pub fn mapStopReason(reason: []const u8) !types.StopReason {
    if (std.mem.eql(u8, reason, "end_turn")) return .stop;
    if (std.mem.eql(u8, reason, "max_tokens")) return .length;
    if (std.mem.eql(u8, reason, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, reason, "pause_turn")) return .stop;
    if (std.mem.eql(u8, reason, "stop_sequence")) return .stop;
    if (std.mem.eql(u8, reason, "refusal") or std.mem.eql(u8, reason, "sensitive")) return .error_reason;
    return AnthropicError.UnknownStopReason;
}

fn anthropicEffortString(effort: types.AnthropicEffort) []const u8 {
    return switch (effort) {
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
        .max => "max",
    };
}

fn anthropicThinkingDisplayString(display: types.AnthropicThinkingDisplay) []const u8 {
    return switch (display) {
        .summarized => "summarized",
        .omitted => "omitted",
    };
}

fn supportsAdaptiveThinking(model: types.Model) bool {
    return std.mem.indexOf(u8, model.id, "opus-4-6") != null or
        std.mem.indexOf(u8, model.id, "opus-4.6") != null or
        std.mem.indexOf(u8, model.id, "opus-4-7") != null or
        std.mem.indexOf(u8, model.id, "opus-4.7") != null or
        std.mem.indexOf(u8, model.id, "sonnet-4-6") != null or
        std.mem.indexOf(u8, model.id, "sonnet-4.6") != null;
}

fn buildToolChoiceValue(
    allocator: std.mem.Allocator,
    tool_choice: types.AnthropicToolChoice,
    is_oauth: bool,
) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    switch (tool_choice) {
        .auto => try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "auto") }),
        .any => try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "any") }),
        .none => try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "none") }),
        .tool => |name| {
            try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "tool") });
            try object.put(
                allocator,
                try allocator.dupe(u8, "name"),
                .{ .string = try allocator.dupe(u8, if (is_oauth) canonicalClaudeCodeToolName(name) else name) },
            );
        },
    }
    return .{ .object = object };
}

test "VAL-MSG-010 Anthropic skips failed assistants" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };
    const first_user = [_]types.ContentBlock{.{ .text = .{ .text = "hello" } }};
    const failed_content = [_]types.ContentBlock{
        .{ .text = .{ .text = "partial" } },
        .{ .tool_call = .{ .id = "failed-tool", .name = "lookup", .arguments = .null } },
    };
    const final_user = [_]types.ContentBlock{.{ .text = .{ .text = "continue" } }};

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &[_]types.Message{
        .{ .user = .{ .content = &first_user, .timestamp = 1 } },
        .{ .assistant = .{
            .content = &failed_content,
            .api = "anthropic-messages",
            .provider = "anthropic",
            .model = "claude-3-7-sonnet-latest",
            .usage = types.Usage.init(),
            .stop_reason = .error_reason,
            .error_message = "failed",
            .timestamp = 2,
        } },
        .{ .assistant = .{
            .content = &failed_content,
            .api = "anthropic-messages",
            .provider = "anthropic",
            .model = "claude-3-7-sonnet-latest",
            .usage = types.Usage.init(),
            .stop_reason = .aborted,
            .error_message = "aborted",
            .timestamp = 3,
        } },
        .{ .user = .{ .content = &final_user, .timestamp = 4 } },
    } }, null);
    defer freeJsonValue(allocator, payload);

    const messages = payload.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualStrings("user", messages.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("user", messages.items[1].object.get("role").?.string);
}

test "buildRequestPayload includes system tools and cache control without default thinking" {
    const allocator = std.testing.allocator;

    var tool_params = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_params.put(allocator, try allocator.dupe(u8, "city"), .{ .string = try allocator.dupe(u8, "string") });
    const tool_params_value = std.json.Value{ .object = tool_params };
    defer freeJsonValue(allocator, tool_params_value);

    const tools = &[_]types.Tool{.{
        .name = "read",
        .description = "Read a file",
        .parameters = tool_params_value,
    }};

    const context = types.Context{
        .system_prompt = "You are helpful.",
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
        .tools = tools,
    };

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const payload = try buildRequestPayload(allocator, model, context, .{
        .max_tokens = 4096,
        .cache_retention = .long,
    });
    defer freeJsonValue(allocator, payload);

    const object = payload.object;
    try std.testing.expectEqualStrings("claude-3-7-sonnet-latest", object.get("model").?.string);
    try std.testing.expect(object.get("system").? == .array);
    try std.testing.expect(object.get("messages").? == .array);
    try std.testing.expect(object.get("tools").? == .array);
    try std.testing.expect(object.get("thinking") == null);
}

test "buildRequestPayload applies Claude Code stealth mode for oauth" {
    const allocator = std.testing.allocator;
    const oauth_token_placeholder = "placeholder-" ++ "sk" ++ "-ant-oat" ++ "-token";

    const tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    const tool_schema_value = std.json.Value{ .object = tool_schema };
    defer freeJsonValue(allocator, tool_schema_value);

    const tools = &[_]types.Tool{.{
        .name = "todoWrite",
        .description = "Write todos",
        .parameters = tool_schema_value,
    }};

    const context = types.Context{
        .system_prompt = "Follow mission boundaries.",
        .messages = &[_]types.Message{},
        .tools = tools,
    };

    const model = types.Model{
        .id = "claude-3-5-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const payload = try buildRequestPayload(allocator, model, context, .{
        .api_key = oauth_token_placeholder,
    });
    defer freeJsonValue(allocator, payload);

    const system_val = payload.object.get("system").?;
    try std.testing.expect(system_val == .array);
    try std.testing.expect(system_val.array.items.len >= 2);

    const tools_val = payload.object.get("tools").?;
    try std.testing.expect(tools_val == .array);
    const first_tool = tools_val.array.items[0].object;
    try std.testing.expectEqualStrings("TodoWrite", first_tool.get("name").?.string);
}

test "parse anthropic stream emits text events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0,\"cache_read_input_tokens\":2,\"cache_creation_input_tokens\":3}}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .cost = .{ .input = 3, .output = 15, .cache_read = 0.3, .cache_write = 3.75 },
        .context_window = 200000,
        .max_tokens = 64000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{ .messages = &[_]types.Message{} }, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);
    const delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("Hello", delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream_instance.next().?.event_type);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqualStrings("Hello", done.message.?.content[0].text.text);
    try std.testing.expectEqual(@as(u32, 10), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 5), done.message.?.usage.output);
    try std.testing.expectEqual(@as(u32, 2), done.message.?.usage.cache_read);
    try std.testing.expectEqual(@as(u32, 3), done.message.?.usage.cache_write);
    try std.testing.expectEqual(@as(u32, 20), done.message.?.usage.total_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00011685), done.message.?.usage.cost.total, 0.000000001);
}

test "parse anthropic stream handles compact data fields and provider errors" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: error\n" ++
        "data:{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad request\"}}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{ .messages = &[_]types.Message{} }, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    const error_event = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.error_event, error_event.event_type);
    try std.testing.expectEqualStrings("invalid_request_error: bad request", error_event.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, error_event.message.?.stop_reason);
}

test "parse anthropic stream preserves frame-aware multiline data under shared SSE loop" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        ": keepalive\n" ++
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_multiline\",\"usage\":{\"input_tokens\":4,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "event: ignored_vendor_event\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ignored\"}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\n" ++
        "data: \"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Frame\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n" ++
        "\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{ .messages = &[_]types.Message{} }, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);
    const delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("Frame", delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream_instance.next().?.event_type);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqualStrings("msg_multiline", done.message.?.response_id.?);
    try std.testing.expectEqualStrings("Frame", done.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.stop, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(u32, 4), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 2), done.message.?.usage.output);
}

test "parse anthropic stream returns error for empty successful stream" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_empty\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{ .messages = &[_]types.Message{} }, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    const error_event = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.error_event, error_event.event_type);
    try std.testing.expectEqualStrings("Provider returned an empty assistant response", error_event.error_message.?);
}

test "parse anthropic stream emits tool call and thinking events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const oauth_token_placeholder = "placeholder-" ++ "sk" ++ "-ant-oat" ++ "-token";

    const body =
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"I should inspect the file.\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig-1\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"TodoWrite\",\"input\":{}}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"todos\\\":\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"item\\\"}\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"input_tokens\":20,\"output_tokens\":12}}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const tools = &[_]types.Tool{.{
        .name = "todoWrite",
        .description = "Write todos",
        .parameters = .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) },
    }};

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{
        .messages = &[_]types.Message{},
        .tools = tools,
    }, .{
        .api_key = oauth_token_placeholder,
    });

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_delta, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_end, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream_instance.next().?.event_type);
    _ = stream_instance.next().?;
    _ = stream_instance.next().?;
    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqualStrings("todoWrite", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("item", tool_end.tool_call.?.arguments.object.get("todos").?.string);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), done.message.?.content.len);
    try std.testing.expect(done.message.?.content[1] == .tool_call);
    try std.testing.expectEqualStrings("todoWrite", done.message.?.content[1].tool_call.name);
    try std.testing.expectEqualStrings("item", done.message.?.content[1].tool_call.arguments.object.get("todos").?.string);
    try std.testing.expect(done.message.?.tool_calls == null);
}

test "ISS-002 Anthropic content_index remains stable after block removal" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_content_index\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"intro\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_content_index\",\"name\":\"lookup\",\"input\":{}}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"stable\\\"}\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":8}}\n" ++
        "\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{
        .messages = &[_]types.Message{},
    }, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);

    const text_start = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_start, text_start.event_type);
    try std.testing.expectEqual(@as(?u32, 0), text_start.content_index);

    const text_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, text_delta.event_type);
    try std.testing.expectEqual(@as(?u32, 0), text_delta.content_index);
    try std.testing.expectEqualStrings("intro", text_delta.delta.?);

    const text_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqual(@as(?u32, 0), text_end.content_index);
    try std.testing.expectEqualStrings("intro", text_end.content.?);

    const tool_start = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, tool_start.event_type);
    try std.testing.expectEqual(@as(?u32, 1), tool_start.content_index);

    const tool_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta.event_type);
    try std.testing.expectEqual(@as(?u32, 1), tool_delta.content_index);
    try std.testing.expectEqualStrings("{\"query\":\"stable\"}", tool_delta.delta.?);

    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqual(@as(?u32, 1), tool_end.content_index);
    try std.testing.expectEqualStrings("toolu_content_index", tool_end.tool_call.?.id);
    try std.testing.expectEqualStrings("lookup", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("stable", tool_end.tool_call.?.arguments.object.get("query").?.string);

    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), done.message.?.content.len);
    try std.testing.expect(done.message.?.content[0] == .text);
    try std.testing.expectEqualStrings("intro", done.message.?.content[0].text.text);
    try std.testing.expect(done.message.?.content[1] == .tool_call);
    try std.testing.expectEqualStrings("toolu_content_index", done.message.?.content[1].tool_call.id);
    try std.testing.expectEqualStrings("lookup", done.message.?.content[1].tool_call.name);
    try std.testing.expectEqualStrings("stable", done.message.?.content[1].tool_call.arguments.object.get("query").?.string);
    try std.testing.expect(done.message.?.tool_calls == null);
    try std.testing.expect(stream_instance.next() == null);
}

test "parse anthropic stream coerces end_turn to tool_use when tool calls are present" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_stop_tool\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_stop_coerce\",\"name\":\"lookup\",\"input\":{}}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"coerce\\\"}\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":4}}\n" ++
        "\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{
        .messages = &[_]types.Message{},
    }, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_delta, stream_instance.next().?.event_type);
    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqualStrings("lookup", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("coerce", tool_end.tool_call.?.arguments.object.get("query").?.string);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), done.message.?.content.len);
    try std.testing.expect(done.message.?.content[0] == .tool_call);
    try std.testing.expect(done.message.?.tool_calls == null);
    try std.testing.expect(stream_instance.next() == null);
}

test "parse kimi anthropic-compatible stream repairs malformed json and ignores unknown events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_kimi\",\"usage\":{\"input_tokens\":7,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "event: response.output_text.delta\n" ++
        "data: {\"not\":\"an anthropic event\"}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello \\_Kimi\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_kimi\",\"name\":\"run_terminal\",\"input\":{}}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"echo \\_Kimi\\\"}\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"unknown_tool_delta\",\"ignored\":\"safe\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":9}}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{
        .messages = &[_]types.Message{},
    }, .{
        .api_key = "placeholder-kimi-auth-value",
    });

    var saw_text_delta = false;
    var saw_tool_end = false;
    var saw_error = false;
    var done_message: ?types.AssistantMessage = null;
    while (stream_instance.next()) |event| {
        if (event.event_type == .text_delta) {
            saw_text_delta = true;
            try std.testing.expectEqualStrings("Hello \\_Kimi", event.delta.?);
        } else if (event.event_type == .toolcall_end) {
            saw_tool_end = true;
            try std.testing.expectEqualStrings("run_terminal", event.tool_call.?.name);
            try std.testing.expectEqualStrings("echo \\_Kimi", event.tool_call.?.arguments.object.get("command").?.string);
        } else if (event.event_type == .error_event) {
            saw_error = true;
            if (event.error_message) |message| {
                try std.testing.expect(std.mem.indexOf(u8, message, "SyntaxError") == null);
            }
        } else if (event.event_type == .done) {
            done_message = event.message.?;
        }
    }

    try std.testing.expect(saw_text_delta);
    try std.testing.expect(saw_tool_end);
    try std.testing.expect(!saw_error);
    try std.testing.expect(done_message != null);
    try std.testing.expectEqualStrings("kimi-coding", done_message.?.provider);
    try std.testing.expectEqualStrings("kimi-for-coding", done_message.?.model);
    try std.testing.expectEqual(types.StopReason.tool_use, done_message.?.stop_reason);
}

test "parse kimi anthropic-compatible stream tolerates noncanonical chunk shapes" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_kimi_noncanonical\",\"usage\":{\"input_tokens\":3,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"review notes\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":99,\"delta\":{\"type\":\"unknown_delta\",\"payload\":\"ignored\"}}\n" ++
        "\n" ++
        "data: {\"control\":\"keepalive\",\"payload\":{\"ignored\":true}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":42}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_kimi_noncanonical\",\"name\":\"run_terminal\",\"input\":{}}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"zig test\\\"}\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"unknown_tool_delta\",\"ignored\":\"safe\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":6}}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{
        .messages = &[_]types.Message{},
    }, .{
        .api_key = "placeholder-kimi-auth-value",
    });

    var saw_text_delta = false;
    var saw_text_end = false;
    var saw_tool_end = false;
    var done_message: ?types.AssistantMessage = null;
    while (stream_instance.next()) |event| {
        if (event.event_type == .text_delta) {
            saw_text_delta = true;
            try std.testing.expectEqualStrings("review notes", event.delta.?);
        } else if (event.event_type == .text_end) {
            saw_text_end = true;
            try std.testing.expectEqualStrings("review notes", event.content.?);
        } else if (event.event_type == .toolcall_end) {
            saw_tool_end = true;
            try std.testing.expectEqualStrings("run_terminal", event.tool_call.?.name);
            try std.testing.expectEqualStrings("zig test", event.tool_call.?.arguments.object.get("command").?.string);
        } else if (event.event_type == .error_event) {
            if (event.error_message) |message| {
                try std.testing.expect(std.mem.indexOf(u8, message, "InvalidAnthropicChunk") == null);
            }
            return error.UnexpectedKimiNoncanonicalError;
        } else if (event.event_type == .done) {
            done_message = event.message.?;
        }
    }

    try std.testing.expect(saw_text_delta);
    try std.testing.expect(saw_text_end);
    try std.testing.expect(saw_tool_end);
    try std.testing.expect(done_message != null);
    try std.testing.expectEqualStrings("kimi-coding", done_message.?.provider);
    try std.testing.expectEqualStrings("kimi-for-coding", done_message.?.model);
    try std.testing.expectEqual(types.StopReason.tool_use, done_message.?.stop_reason);
    try std.testing.expectEqualStrings("review notes", done_message.?.content[0].text.text);
}

test "parse kimi anthropic-compatible stream ignores orphan tool input deltas after tool stop" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_kimi_orphan_tool_delta\",\"usage\":{\"input_tokens\":74,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_kimi_code_review\",\"name\":\"ls\",\"input\":{}}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"/Users/davirian/dev/active/pi-mono-davirain\\\"}\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"/tmp/duplicate-should-be-ignored\\\"}\"}}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":106}}\n" ++
        "\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{
        .messages = &[_]types.Message{},
    }, .{
        .api_key = "placeholder-kimi-auth-value",
    });

    var tool_end_count: usize = 0;
    var tool_delta_count: usize = 0;
    var done_message: ?types.AssistantMessage = null;
    while (stream_instance.next()) |event| {
        if (event.event_type == .toolcall_delta) {
            tool_delta_count += 1;
        } else if (event.event_type == .toolcall_end) {
            tool_end_count += 1;
            try std.testing.expectEqualStrings("tool_kimi_code_review", event.tool_call.?.id);
            try std.testing.expectEqualStrings("ls", event.tool_call.?.name);
            try std.testing.expectEqualStrings("/Users/davirian/dev/active/pi-mono-davirain", event.tool_call.?.arguments.object.get("path").?.string);
        } else if (event.event_type == .error_event) {
            if (event.error_message) |message| {
                try std.testing.expect(std.mem.indexOf(u8, message, "InvalidAnthropicChunk") == null);
            }
            return error.UnexpectedKimiOrphanToolDeltaError;
        } else if (event.event_type == .done) {
            done_message = event.message.?;
        }
    }

    try std.testing.expectEqual(@as(usize, 1), tool_delta_count);
    try std.testing.expectEqual(@as(usize, 1), tool_end_count);
    try std.testing.expect(done_message != null);
    try std.testing.expectEqualStrings("kimi-coding", done_message.?.provider);
    try std.testing.expectEqualStrings("kimi-for-coding", done_message.?.model);
    try std.testing.expectEqual(types.StopReason.tool_use, done_message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), done_message.?.content.len);
    try std.testing.expect(done_message.?.content[0] == .tool_call);
    try std.testing.expectEqualStrings("tool_kimi_code_review", done_message.?.content[0].tool_call.id);
    try std.testing.expectEqualStrings("ls", done_message.?.content[0].tool_call.name);
    try std.testing.expectEqualStrings("/Users/davirian/dev/active/pi-mono-davirain", done_message.?.content[0].tool_call.arguments.object.get("path").?.string);
    try std.testing.expect(done_message.?.tool_calls == null);
}

test "parse kimi anthropic-compatible stream finalizes recoverable partial EOF" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial code review\"}}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{
        .messages = &[_]types.Message{},
    }, .{
        .api_key = "placeholder-kimi-auth-value",
    });

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);
    const delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial code review", delta.delta.?);
    const text_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial code review", text_end.content.?);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqualStrings("kimi-coding", done.message.?.provider);
    try std.testing.expectEqualStrings("kimi-for-coding", done.message.?.model);
    try std.testing.expectEqualStrings("partial code review", done.message.?.content[0].text.text);
    try std.testing.expect(stream_instance.next() == null);
}

test "parse first-party anthropic unmatched lifecycle remains strict" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_anthropic_strict\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{ .messages = &[_]types.Message{} }, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    const error_event = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.error_event, error_event.event_type);
    try std.testing.expectEqualStrings("InvalidAnthropicChunk", error_event.error_message.?);
    try std.testing.expectEqualStrings("anthropic", error_event.message.?.provider);
    try std.testing.expectEqualStrings("claude-3-7-sonnet-latest", error_event.message.?.model);
    try std.testing.expect(stream_instance.next() == null);
}

test "mapStopReason covers anthropic variants" {
    try std.testing.expectEqual(types.StopReason.stop, try mapStopReason("end_turn"));
    try std.testing.expectEqual(types.StopReason.length, try mapStopReason("max_tokens"));
    try std.testing.expectEqual(types.StopReason.tool_use, try mapStopReason("tool_use"));
    try std.testing.expectEqual(types.StopReason.stop, try mapStopReason("pause_turn"));
    try std.testing.expectError(error.UnknownStopReason, mapStopReason("unexpected"));
}

test "buildRequestPayload adds eager_input_streaming by default" {
    const allocator = std.testing.allocator;

    const tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    const tool_schema_value = std.json.Value{ .object = tool_schema };
    defer freeJsonValue(allocator, tool_schema_value);

    const tools = &[_]types.Tool{.{
        .name = "todoWrite",
        .description = "Write todos",
        .parameters = tool_schema_value,
    }};

    const model = types.Model{
        .id = "claude-sonnet-4-5",
        .name = "Claude Sonnet 4.5",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const payload = try buildRequestPayload(allocator, model, .{
        .messages = &[_]types.Message{},
        .tools = tools,
    }, null);
    defer freeJsonValue(allocator, payload);

    const first_tool = payload.object.get("tools").?.array.items[0];
    try std.testing.expect(first_tool == .object);
    try std.testing.expectEqual(true, first_tool.object.get("eager_input_streaming").?.bool);
}

test "github-copilot compat disables eager_input_streaming and enables legacy beta header" {
    const allocator = std.testing.allocator;

    const tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    const tool_schema_value = std.json.Value{ .object = tool_schema };
    defer freeJsonValue(allocator, tool_schema_value);

    const tools = &[_]types.Tool{.{
        .name = "todoWrite",
        .description = "Write todos",
        .parameters = tool_schema_value,
    }};

    var compat = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try compat.put(allocator, try allocator.dupe(u8, "supportsEagerToolInputStreaming"), .{ .bool = false });
    const compat_value = std.json.Value{ .object = compat };
    defer freeJsonValue(allocator, compat_value);

    const model = types.Model{
        .id = "claude-sonnet-4-5",
        .name = "Claude Sonnet 4.5",
        .api = "anthropic-messages",
        .provider = "github-copilot",
        .base_url = "https://api.githubcopilot.com/anthropic",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
        .compat = compat_value,
    };

    const context = types.Context{
        .messages = &[_]types.Message{},
        .tools = tools,
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer freeJsonValue(allocator, payload);

    const first_tool = payload.object.get("tools").?.array.items[0];
    try std.testing.expect(first_tool == .object);
    try std.testing.expect(first_tool.object.get("eager_input_streaming") == null);

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer deinitOwnedHeaders(allocator, &headers);

    try applyDefaultAnthropicHeaders(allocator, &headers, model, context, null);
    try std.testing.expectEqualStrings(
        "fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14",
        headers.get("anthropic-beta").?,
    );
}

test "kimi-coding api-key headers preserve truthful client identity" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer deinitOwnedHeaders(allocator, &headers);

    try applyBaseAnthropicHeaders(allocator, &headers, model);
    try applyAuthHeaders(allocator, &headers, model, .{ .api_key = "placeholder-auth-value" });
    try applyDefaultAnthropicHeaders(allocator, &headers, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = "placeholder-auth-value",
    });

    try std.testing.expect(headers.get("user-agent") == null);
    try std.testing.expectEqualStrings("placeholder-auth-value", headers.get("x-api-key").?);
    try std.testing.expect(headers.get("Authorization") == null);
    try std.testing.expect(headers.get("anthropic-beta") == null);
    try std.testing.expect(headers.get("anthropic-dangerous-direct-browser-access") == null);
}

test "kimi-coding api-key payload does not inject Claude Code identity" {
    const allocator = std.testing.allocator;

    const tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    const tool_schema_value = std.json.Value{ .object = tool_schema };
    defer freeJsonValue(allocator, tool_schema_value);

    const tools = &[_]types.Tool{.{
        .name = "todoWrite",
        .description = "Write todos",
        .parameters = tool_schema_value,
    }};

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    const payload = try buildRequestPayload(allocator, model, .{
        .system_prompt = "Identify yourself according to the selected provider.",
        .messages = &[_]types.Message{},
        .tools = tools,
    }, .{
        .api_key = "placeholder-auth-value",
    });
    defer freeJsonValue(allocator, payload);

    try std.testing.expectEqualStrings("kimi-for-coding", payload.object.get("model").?.string);
    const system = payload.object.get("system").?;
    try std.testing.expect(system == .array);
    try std.testing.expectEqual(@as(usize, 1), system.array.items.len);
    const system_text = system.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, system_text, "Claude Code") == null);
    try std.testing.expect(std.mem.indexOf(u8, system_text, "Anthropic") == null);

    const first_tool = payload.object.get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings("todoWrite", first_tool.get("name").?.string);
}

test "buildRequestPayload omits anthropic long cache ttl when compat disables it" {
    const allocator = std.testing.allocator;

    var compat = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try compat.put(allocator, try allocator.dupe(u8, "supportsLongCacheRetention"), .{ .bool = false });
    const compat_value = std.json.Value{ .object = compat };
    defer freeJsonValue(allocator, compat_value);

    const model = types.Model{
        .id = "claude-sonnet-4-5",
        .name = "Claude Sonnet 4.5",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
        .compat = compat_value,
    };

    const payload = try buildRequestPayload(allocator, model, .{
        .system_prompt = "Cache me",
        .messages = &[_]types.Message{},
    }, .{
        .cache_retention = .long,
    });
    defer freeJsonValue(allocator, payload);

    const system = payload.object.get("system").?.array.items[0];
    try std.testing.expect(system == .object);
    const cache_control = system.object.get("cache_control").?;
    try std.testing.expect(cache_control == .object);
    try std.testing.expect(cache_control.object.get("ttl") == null);
}

test "buildRequestPayload supports disabled thinking and temperature" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const payload = try buildRequestPayload(allocator, model, .{
        .messages = &[_]types.Message{},
    }, .{
        .temperature = 0.25,
        .anthropic_thinking_enabled = false,
    });
    defer freeJsonValue(allocator, payload);

    const thinking = payload.object.get("thinking").?.object;
    try std.testing.expectEqualStrings("disabled", thinking.get("type").?.string);
    try std.testing.expectEqual(@as(f64, 0.25), payload.object.get("temperature").?.float);
}

test "buildRequestPayload supports adaptive thinking effort" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "claude-opus-4-6",
        .name = "Claude Opus 4.6",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const payload = try buildRequestPayload(allocator, model, .{
        .messages = &[_]types.Message{},
    }, .{
        .anthropic_thinking_enabled = true,
        .anthropic_effort = .max,
    });
    defer freeJsonValue(allocator, payload);

    const thinking = payload.object.get("thinking").?.object;
    try std.testing.expectEqualStrings("adaptive", thinking.get("type").?.string);
    try std.testing.expectEqualStrings("summarized", thinking.get("display").?.string);
    const output_config = payload.object.get("output_config").?.object;
    try std.testing.expectEqualStrings("max", output_config.get("effort").?.string);
    try std.testing.expect(payload.object.get("temperature") == null);
}

test "buildRequestPayload supports budget thinking display and tool choice" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const payload = try buildRequestPayload(allocator, model, .{
        .messages = &[_]types.Message{},
    }, .{
        .anthropic_thinking_enabled = true,
        .anthropic_thinking_budget_tokens = 4096,
        .anthropic_thinking_display = .omitted,
        .anthropic_tool_choice = .{ .tool = "todoWrite" },
    });
    defer freeJsonValue(allocator, payload);

    const thinking = payload.object.get("thinking").?.object;
    try std.testing.expectEqualStrings("enabled", thinking.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 4096), thinking.get("budget_tokens").?.integer);
    try std.testing.expectEqualStrings("omitted", thinking.get("display").?.string);

    const tool_choice = payload.object.get("tool_choice").?.object;
    try std.testing.expectEqualStrings("tool", tool_choice.get("type").?.string);
    try std.testing.expectEqualStrings("todoWrite", tool_choice.get("name").?.string);
}

test "applyDefaultAnthropicHeaders adds interleaved thinking beta for legacy models" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer deinitOwnedHeaders(allocator, &headers);

    try applyDefaultAnthropicHeaders(allocator, &headers, model, .{
        .messages = &[_]types.Message{},
    }, .{
        .anthropic_interleaved_thinking = true,
    });

    try std.testing.expectEqualStrings("interleaved-thinking-2025-05-14", headers.get("anthropic-beta").?);
}

test "resolveStreamOptions falls back to env api key before building payload" {
    const allocator = std.testing.allocator;
    const oauth_token_placeholder = "placeholder-" ++ "sk" ++ "-ant-oat" ++ "-env-token";

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("ANTHROPIC_OAUTH_TOKEN", oauth_token_placeholder);

    const model = types.Model{
        .id = "claude-3-5-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const resolved = try resolveStreamOptionsWithEnvMap(allocator, model, null, &env_map);
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings(oauth_token_placeholder, resolved.options.?.api_key.?);

    const payload = try buildRequestPayload(allocator, model, .{
        .messages = &[_]types.Message{},
    }, resolved.options);
    defer freeJsonValue(allocator, payload);

    try std.testing.expect(payload.object.get("system").? == .array);
}

test "stream on_response receives actual response headers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_headers\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n" ++
        "\n";

    var server = try ResponseHeaderServer.init(
        io,
        "x-request-id: req_123\r\nanthropic-processing-ms: 17\r\n",
        body,
    );
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = url,
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const user_content = [_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }};
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &user_content,
                .timestamp = 1,
            } },
        },
    };

    OnResponseCapture.reset();

    var stream = try AnthropicProvider.stream(allocator, io, model, context, .{
        .api_key = "test-key",
        .on_response = &OnResponseCapture.callback,
    });
    defer stream.deinit();

    try drainStreamAndFreeDoneMessage(allocator, &stream);

    try std.testing.expect(OnResponseCapture.called);
    try std.testing.expectEqual(@as(u16, 200), OnResponseCapture.status);
}

test "stream HTTP status error is terminal sanitized event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const redacted_secret_placeholder = "sk" ++ "-anthropic-secret";
    const body = "{\"type\":\"error\",\"error\":{\"message\":\"bad request\",\"authorization\":\"Bearer " ++ redacted_secret_placeholder ++ "\",\"request_id\":\"req_anthropic_random_123456\"},\"trace\":\"/Users/alice/pi/anthropic.zig\"}";
    var server = try provider_error.TestStatusServer.init(io, 401, "Unauthorized", "", body);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try AnthropicProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 401: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "bad request") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, redacted_secret_placeholder) == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_anthropic_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expect(stream.next() == null);
    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("anthropic-messages", result.api);
}

fn parseSseStreamLines(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    streaming: *http_client.StreamingResponse,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !void {
    var output = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    };

    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(allocator);

    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);

    var active_blocks = std.ArrayList(BlockEntry).empty;
    defer {
        for (active_blocks.items) |*entry| deinitCurrentBlock(allocator, &entry.block);
        active_blocks.deinit(allocator);
    }

    stream_ptr.push(.{ .event_type = .start });

    var handler = AnthropicSseFrameHandler{
        .allocator = allocator,
        .stream_ptr = stream_ptr,
        .output = &output,
        .content_blocks = &content_blocks,
        .tool_calls = &tool_calls,
        .active_blocks = &active_blocks,
        .model = model,
        .context = context,
        .options = options,
    };
    const loop_result = sse_loop.runFrames(allocator, AnthropicSseFrameHandler, &handler, streaming, options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, err);
            return;
        },
    };
    if (loop_result == .stopped) {
        return;
    }

    if (active_blocks.items.len > 0) {
        if (shouldTolerateNoncanonicalAnthropicChunk(model)) {
            try finalizeOutputFromPartials(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model);
            if (output.content.len == 0 and output.tool_calls == null) {
                const error_message = try allocator.dupe(u8, "Provider returned an empty assistant response");
                output.stop_reason = .error_reason;
                output.error_message = error_message;
                stream_ptr.push(.{
                    .event_type = .error_event,
                    .error_message = error_message,
                    .message = output,
                });
                stream_ptr.end(output);
                return;
            }
            stream_ptr.push(.{
                .event_type = .done,
                .message = output,
            });
            stream_ptr.end(output);
            return;
        } else {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, AnthropicError.InvalidAnthropicChunk);
            return;
        }
    }

    if (content_blocks.items.len == 0 and tool_calls.items.len == 0) {
        const error_message = try allocator.dupe(u8, "Provider returned an empty assistant response");
        output.stop_reason = .error_reason;
        output.error_message = error_message;
        stream_ptr.push(.{
            .event_type = .error_event,
            .error_message = error_message,
            .message = output,
        });
        stream_ptr.end(output);
        return;
    }

    try finalizeCollectedOutput(allocator, &output, &content_blocks, &tool_calls, model, .always, true);
    // Tool calls live inline in output.content; legacy AssistantMessage.tool_calls
    // is intentionally left null. tool_calls ArrayList holds borrow-only copies
    // and tool_calls.deinit only releases its buffer.

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

const AnthropicSseFrameHandler = struct {
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,

    pub fn handleFrame(self: *AnthropicSseFrameHandler, sse_event: []const u8, data: []const u8) !bool {
        const event_finished = try processAnthropicSseEvent(
            self.allocator,
            self.stream_ptr,
            sse_event,
            data,
            self.output,
            self.content_blocks,
            self.tool_calls,
            self.active_blocks,
            self.model,
            self.context,
            self.options,
        );
        return !event_finished;
    }

    pub fn handleRuntimeFailure(self: *AnthropicSseFrameHandler, err: anyerror) !void {
        try emitRuntimeFailure(
            self.allocator,
            self.stream_ptr,
            self.output,
            self.content_blocks,
            self.tool_calls,
            self.active_blocks,
            self.model,
            err,
        );
    }
};

fn finalizeOutputFromPartials(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
) !void {
    while (active_blocks.items.len > 0) {
        var entry = active_blocks.orderedRemove(0);
        defer deinitCurrentBlock(allocator, &entry.block);
        switch (entry.block) {
            .text => |text| {
                const owned = try allocator.dupe(u8, text.items);
                try content_blocks.append(allocator, .{ .text = .{ .text = owned } });
                stream_ptr.push(.{ .event_type = .text_end, .content_index = @intCast(entry.event_index), .content = owned });
            },
            .thinking => |thinking| {
                const text = try allocator.dupe(u8, thinking.text.items);
                const signature = if (thinking.signature) |sig| try allocator.dupe(u8, sig) else null;
                try content_blocks.append(allocator, .{ .thinking = .{ .thinking = text, .signature = signature, .redacted = thinking.redacted } });
                stream_ptr.push(.{ .event_type = .thinking_end, .content_index = @intCast(entry.event_index), .content = text });
            },
            .tool_call => |tool| {
                var parsed_arguments = try json_parse.parseStreamingJson(allocator, tool.partial_json.items);
                defer parsed_arguments.deinit();
                const arguments = try cloneJsonValue(allocator, parsed_arguments.value);
                const final_tool_call = blk: {
                    errdefer freeJsonValue(allocator, arguments);
                    const id = try allocator.dupe(u8, tool.id);
                    errdefer allocator.free(id);
                    const name = try allocator.dupe(u8, tool.name);
                    errdefer allocator.free(name);
                    break :blk types.ToolCall{
                        .id = id,
                        .name = name,
                        .arguments = arguments,
                    };
                };
                try finalize.appendInlineToolCall(allocator, content_blocks, tool_calls, final_tool_call);
                stream_ptr.push(.{ .event_type = .toolcall_end, .content_index = @intCast(entry.event_index), .tool_call = final_tool_call });
            },
        }
    }

    try finalizeCollectedOutput(allocator, output, content_blocks, tool_calls, model, .when_output_empty, false);
    // Tool calls are emitted inline; legacy field intentionally null.
}

fn finalizeCollectedOutput(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    model: types.Model,
    content_transfer: finalize.ContentTransferMode,
    coerce_stop_reason_for_tool_calls: bool,
) !void {
    try finalize.finalizeOutput(allocator, output, .{
        .content_blocks = content_blocks,
        .tool_calls = tool_calls,
    }, .{
        .content_transfer = content_transfer,
        .total_tokens = .preserve_or_full_usage,
        .coerce_stop_reason_for_tool_calls = coerce_stop_reason_for_tool_calls,
    });
    calculateCost(model, &output.usage);
}

fn emitRuntimeFailure(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
    err: anyerror,
) !void {
    try finalizeOutputFromPartials(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model);
    output.stop_reason = provider_error.runtimeStopReason(err);
    output.error_message = provider_error.runtimeErrorMessage(err);
    provider_error.pushTerminalRuntimeError(stream_ptr, output.*);
}

fn isAnthropicMessageSseEvent(event_name: []const u8) bool {
    return std.mem.eql(u8, event_name, "message_start") or
        std.mem.eql(u8, event_name, "message_delta") or
        std.mem.eql(u8, event_name, "message_stop") or
        std.mem.eql(u8, event_name, "content_block_start") or
        std.mem.eql(u8, event_name, "content_block_delta") or
        std.mem.eql(u8, event_name, "content_block_stop");
}

fn processAnthropicSseEvent(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    sse_event: []const u8,
    data: []const u8,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !bool {
    if (data.len == 0) return false;
    if (std.mem.eql(u8, std.mem.trim(u8, data, " \t\r\n"), "[DONE]")) return true;
    const tolerate_noncanonical = shouldTolerateNoncanonicalAnthropicChunk(model);
    if (sse_event.len > 0 and
        !std.mem.eql(u8, sse_event, "error") and
        !isAnthropicMessageSseEvent(sse_event))
    {
        return false;
    }

    var parsed = json_parse.parseJsonWithRepair(allocator, data) catch |err| {
        if (std.mem.eql(u8, sse_event, "error")) {
            try emitAnthropicStreamError(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model, data);
            return true;
        }
        return err;
    };
    defer parsed.deinit();
    const value = parsed.value;
    if (value != .object) return AnthropicError.InvalidAnthropicChunk;

    if (std.mem.eql(u8, sse_event, "error")) {
        const error_message = try formatAnthropicStreamError(allocator, value, data);
        try emitOwnedAnthropicStreamError(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model, error_message);
        return true;
    }

    const event_type = value.object.get("type") orelse {
        if (value.object.get("error") != null) {
            const error_message = try formatAnthropicStreamError(allocator, value, data);
            try emitOwnedAnthropicStreamError(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model, error_message);
            return true;
        }
        if (tolerate_noncanonical) return false;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (event_type != .string) {
        if (tolerate_noncanonical) return false;
        return AnthropicError.InvalidAnthropicChunk;
    }

    if (std.mem.eql(u8, event_type.string, "message_start")) {
        if (value.object.get("message")) |message_value| {
            if (message_value == .object) {
                if (message_value.object.get("id")) |id_value| {
                    if (id_value == .string and output.response_id == null) {
                        output.response_id = try allocator.dupe(u8, id_value.string);
                    }
                }
                if (message_value.object.get("usage")) |usage_value| {
                    updateUsage(&output.usage, usage_value);
                }
            }
        }
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "content_block_start")) {
        try handleContentBlockStart(allocator, active_blocks, stream_ptr, value, context, options, tolerate_noncanonical);
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "content_block_delta")) {
        try handleContentBlockDelta(allocator, active_blocks, stream_ptr, value, tolerate_noncanonical);
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "content_block_stop")) {
        try handleContentBlockStop(allocator, active_blocks, content_blocks, tool_calls, stream_ptr, value, tolerate_noncanonical);
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "message_delta")) {
        if (value.object.get("delta")) |delta_value| {
            if (delta_value == .object) {
                if (delta_value.object.get("stop_reason")) |stop_reason| {
                    if (stop_reason == .string) output.stop_reason = try mapStopReason(stop_reason.string);
                }
            }
        }
        if (value.object.get("usage")) |usage_value| {
            updateUsage(&output.usage, usage_value);
        }
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "message_stop") or
        std.mem.eql(u8, event_type.string, "ping"))
    {
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "error")) {
        const error_message = try formatAnthropicStreamError(allocator, value, data);
        try emitOwnedAnthropicStreamError(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model, error_message);
        return true;
    }

    return false;
}

fn emitAnthropicStreamError(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
    data: []const u8,
) !void {
    const detail = try provider_error.sanitizeProviderErrorDetail(allocator, data);
    defer allocator.free(detail);
    const error_message = try std.fmt.allocPrint(allocator, "Provider stream error: {s}", .{detail});
    try emitOwnedAnthropicStreamError(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model, error_message);
}

fn emitOwnedAnthropicStreamError(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
    error_message: []const u8,
) !void {
    try finalizeOutputFromPartials(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model);
    output.stop_reason = .error_reason;
    output.error_message = error_message;
    stream_ptr.push(.{
        .event_type = .error_event,
        .error_message = error_message,
        .message = output.*,
    });
    stream_ptr.end(output.*);
}

fn formatAnthropicStreamError(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    raw: []const u8,
) ![]u8 {
    if (value == .object) {
        if (value.object.get("error")) |error_value| {
            if (error_value == .object) {
                const error_type = if (error_value.object.get("type")) |type_value|
                    if (type_value == .string) type_value.string else "error"
                else
                    "error";
                const message = if (error_value.object.get("message")) |message_value|
                    if (message_value == .string) message_value.string else raw
                else
                    raw;
                const detail = try provider_error.sanitizeProviderErrorDetail(allocator, message);
                defer allocator.free(detail);
                return std.fmt.allocPrint(allocator, "{s}: {s}", .{ error_type, detail });
            }
        }
        if (value.object.get("message")) |message_value| {
            if (message_value == .string) return provider_error.sanitizeProviderErrorDetail(allocator, message_value.string);
        }
    }
    const detail = try provider_error.sanitizeProviderErrorDetail(allocator, raw);
    defer allocator.free(detail);
    return std.fmt.allocPrint(allocator, "Provider stream error: {s}", .{detail});
}

fn handleContentBlockStart(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    value: std.json.Value,
    context: types.Context,
    options: ?types.StreamOptions,
    tolerate_noncanonical: bool,
) !void {
    const index_value = value.object.get("index") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (index_value != .integer) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    const anthropic_index: usize = @intCast(index_value.integer);
    const content_block = value.object.get("content_block") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (content_block != .object) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    const block_type = content_block.object.get("type") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (block_type != .string) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }

    const event_index = anthropic_index;
    if (std.mem.eql(u8, block_type.string, "text")) {
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .text = std.ArrayList(u8).empty },
        });
        stream_ptr.push(.{ .event_type = .text_start, .content_index = @intCast(event_index) });
        return;
    }

    if (std.mem.eql(u8, block_type.string, "thinking")) {
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .thinking = .{
                .text = std.ArrayList(u8).empty,
                .signature = null,
                .redacted = false,
            } },
        });
        stream_ptr.push(.{ .event_type = .thinking_start, .content_index = @intCast(event_index) });
        return;
    }

    if (std.mem.eql(u8, block_type.string, "redacted_thinking")) {
        const signature = if (content_block.object.get("data")) |data_value|
            if (data_value == .string) try allocator.dupe(u8, data_value.string) else null
        else
            null;
        var text = std.ArrayList(u8).empty;
        try text.appendSlice(allocator, "[Reasoning redacted]");
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .thinking = .{
                .text = text,
                .signature = signature,
                .redacted = true,
            } },
        });
        stream_ptr.push(.{ .event_type = .thinking_start, .content_index = @intCast(event_index) });
        return;
    }

    if (std.mem.eql(u8, block_type.string, "tool_use")) {
        const id_value = content_block.object.get("id") orelse return AnthropicError.InvalidAnthropicChunk;
        const name_value = content_block.object.get("name") orelse return AnthropicError.InvalidAnthropicChunk;
        if (id_value != .string or name_value != .string) return AnthropicError.InvalidAnthropicChunk;
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .tool_call = .{
                .id = try allocator.dupe(u8, id_value.string),
                .name = try normalizeIncomingToolName(allocator, name_value.string, context.tools, options),
                .partial_json = std.ArrayList(u8).empty,
            } },
        });
        stream_ptr.push(.{ .event_type = .toolcall_start, .content_index = @intCast(event_index) });
        return;
    }
}

fn handleContentBlockDelta(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    value: std.json.Value,
    tolerate_noncanonical: bool,
) !void {
    const index_value = value.object.get("index") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (index_value != .integer) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    const anthropic_index: usize = @intCast(index_value.integer);
    const delta_value = value.object.get("delta") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (delta_value != .object) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    const delta_type = delta_value.object.get("type") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (delta_type != .string) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    var entry: *BlockEntry = undefined;
    if (findActiveBlockIndex(active_blocks, anthropic_index)) |found_index| {
        entry = &active_blocks.items[found_index];
    } else {
        if (tolerate_noncanonical) {
            if (!isSupportedAnthropicDeltaType(delta_type.string)) return;
            if (std.mem.eql(u8, delta_type.string, "input_json_delta")) return;
            entry = try createImplicitActiveBlock(allocator, active_blocks, stream_ptr, anthropic_index, delta_type.string);
        } else {
            return AnthropicError.InvalidAnthropicChunk;
        }
    }

    if (std.mem.eql(u8, delta_type.string, "text_delta")) {
        const text_value = delta_value.object.get("text") orelse {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        };
        if (text_value != .string) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        if (entry.block != .text) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        try entry.block.text.appendSlice(allocator, text_value.string);
        stream_ptr.push(.{
            .event_type = .text_delta,
            .content_index = @intCast(entry.event_index),
            .delta = try allocator.dupe(u8, text_value.string),
            .owns_delta = true,
        });
        return;
    }

    if (std.mem.eql(u8, delta_type.string, "thinking_delta")) {
        const thinking_value = delta_value.object.get("thinking") orelse {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        };
        if (thinking_value != .string) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        if (entry.block != .thinking) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        try entry.block.thinking.text.appendSlice(allocator, thinking_value.string);
        stream_ptr.push(.{
            .event_type = .thinking_delta,
            .content_index = @intCast(entry.event_index),
            .delta = try allocator.dupe(u8, thinking_value.string),
            .owns_delta = true,
        });
        return;
    }

    if (std.mem.eql(u8, delta_type.string, "signature_delta")) {
        const signature_value = delta_value.object.get("signature") orelse {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        };
        if (signature_value != .string) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        if (entry.block != .thinking) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        if (entry.block.thinking.signature) |existing| {
            const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing, signature_value.string });
            allocator.free(existing);
            entry.block.thinking.signature = combined;
        } else {
            entry.block.thinking.signature = try allocator.dupe(u8, signature_value.string);
        }
        return;
    }

    if (std.mem.eql(u8, delta_type.string, "input_json_delta")) {
        const partial_json = delta_value.object.get("partial_json") orelse {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        };
        if (partial_json != .string) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        if (entry.block != .tool_call) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        try entry.block.tool_call.partial_json.appendSlice(allocator, partial_json.string);
        stream_ptr.push(.{
            .event_type = .toolcall_delta,
            .content_index = @intCast(entry.event_index),
            .delta = try allocator.dupe(u8, partial_json.string),
            .owns_delta = true,
        });
        return;
    }
}

fn isSupportedAnthropicDeltaType(delta_type: []const u8) bool {
    return std.mem.eql(u8, delta_type, "text_delta") or
        std.mem.eql(u8, delta_type, "thinking_delta") or
        std.mem.eql(u8, delta_type, "signature_delta") or
        std.mem.eql(u8, delta_type, "input_json_delta");
}

fn createImplicitActiveBlock(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    anthropic_index: usize,
    delta_type: []const u8,
) !*BlockEntry {
    const event_index = anthropic_index;
    if (std.mem.eql(u8, delta_type, "text_delta")) {
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .text = std.ArrayList(u8).empty },
        });
        stream_ptr.push(.{ .event_type = .text_start, .content_index = @intCast(event_index) });
        return &active_blocks.items[active_blocks.items.len - 1];
    }
    if (std.mem.eql(u8, delta_type, "thinking_delta") or std.mem.eql(u8, delta_type, "signature_delta")) {
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .thinking = .{
                .text = std.ArrayList(u8).empty,
                .signature = null,
                .redacted = false,
            } },
        });
        stream_ptr.push(.{ .event_type = .thinking_start, .content_index = @intCast(event_index) });
        return &active_blocks.items[active_blocks.items.len - 1];
    }
    return AnthropicError.InvalidAnthropicChunk;
}

fn handleContentBlockStop(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    value: std.json.Value,
    tolerate_noncanonical: bool,
) !void {
    const index_value = value.object.get("index") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (index_value != .integer) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    const anthropic_index: usize = @intCast(index_value.integer);

    const remove_index = findActiveBlockIndex(active_blocks, anthropic_index) orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    var entry = active_blocks.orderedRemove(remove_index);
    defer deinitCurrentBlock(allocator, &entry.block);

    switch (entry.block) {
        .text => |text| {
            const owned = try allocator.dupe(u8, text.items);
            try content_blocks.append(allocator, .{ .text = .{ .text = owned } });
            stream_ptr.push(.{
                .event_type = .text_end,
                .content_index = @intCast(entry.event_index),
                .content = owned,
            });
        },
        .thinking => |thinking| {
            const text = try allocator.dupe(u8, thinking.text.items);
            const signature = if (thinking.signature) |sig| try allocator.dupe(u8, sig) else null;
            try content_blocks.append(allocator, .{ .thinking = .{
                .thinking = text,
                .signature = signature,
                .redacted = thinking.redacted,
            } });
            stream_ptr.push(.{
                .event_type = .thinking_end,
                .content_index = @intCast(entry.event_index),
                .content = text,
            });
        },
        .tool_call => |tool| {
            var parsed_arguments = try json_parse.parseStreamingJson(allocator, tool.partial_json.items);
            defer parsed_arguments.deinit();
            const arguments = try cloneJsonValue(allocator, parsed_arguments.value);
            const final_tool_call = blk: {
                errdefer freeJsonValue(allocator, arguments);
                const id = try allocator.dupe(u8, tool.id);
                errdefer allocator.free(id);
                const name = try allocator.dupe(u8, tool.name);
                errdefer allocator.free(name);
                break :blk types.ToolCall{
                    .id = id,
                    .name = name,
                    .arguments = arguments,
                };
            };
            try finalize.appendInlineToolCall(allocator, content_blocks, tool_calls, final_tool_call);
            stream_ptr.push(.{
                .event_type = .toolcall_end,
                .content_index = @intCast(entry.event_index),
                .tool_call = final_tool_call,
            });
        },
    }
}

fn getAnthropicCompat(model: types.Model) AnthropicCompat {
    return .{
        .supports_eager_tool_input_streaming = compatBoolField(model.compat, "supportsEagerToolInputStreaming") orelse true,
        .supports_long_cache_retention = compatBoolField(model.compat, "supportsLongCacheRetention") orelse true,
    };
}

fn compatBoolField(compat: ?std.json.Value, key: []const u8) ?bool {
    const value = compat orelse return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field != .bool) return null;
    return field.bool;
}

fn buildCacheControl(
    allocator: std.mem.Allocator,
    compat: AnthropicCompat,
    retention: types.CacheRetention,
) !?std.json.Value {
    if (retention == .none) return null;
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "ephemeral") });
    if (retention == .long and compat.supports_long_cache_retention) {
        try object.put(allocator, try allocator.dupe(u8, "ttl"), .{ .string = try allocator.dupe(u8, "1h") });
    }
    return .{ .object = object };
}

fn buildSystemPromptValue(
    allocator: std.mem.Allocator,
    system_prompt: ?[]const u8,
    is_oauth: bool,
    cache_control: ?std.json.Value,
) !?std.json.Value {
    if (!is_oauth and system_prompt == null) return null;

    var array = std.json.Array.init(allocator);
    if (is_oauth) {
        try array.append(try buildTextBlockObject(allocator, CLAUDE_CODE_IDENTITY, cache_control));
    }
    if (system_prompt) |prompt| {
        try array.append(try buildTextBlockObject(allocator, prompt, cache_control));
    }
    return .{ .array = array };
}

fn buildMessagesValue(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    tools: ?[]const types.Tool,
    is_oauth: bool,
    cache_control: ?std.json.Value,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();

    var index: usize = 0;
    while (index < messages.len) : (index += 1) {
        switch (messages[index]) {
            .user => |user| try array.append(try buildUserMessageValue(allocator, user)),
            .assistant => |assistant| {
                if (types.shouldReplayAssistantInProviderContext(assistant)) {
                    try array.append(try buildAssistantMessageValue(allocator, assistant, is_oauth));
                }
            },
            .tool_result => {
                const grouped = try buildToolResultUserMessageValue(allocator, messages[index..], cache_control);
                try array.append(grouped.value);
                index += grouped.consumed - 1;
            },
        }
    }
    _ = tools;
    if (cache_control) |_| {
        if (array.items.len > 0) {
            const last = &array.items[array.items.len - 1];
            try applyCacheControlToLastUserContent(allocator, last, cache_control.?);
        }
    }
    return .{ .array = array };
}

fn buildUserMessageValue(allocator: std.mem.Allocator, user: types.UserMessage) !std.json.Value {
    var content = std.json.Array.init(allocator);
    errdefer content.deinit();

    for (user.content) |block| {
        switch (block) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) continue;
                try content.append(try buildTextBlockObject(allocator, text.text, null));
            },
            .image => |image| {
                var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                var source = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "image") });
                try source.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "base64") });
                try source.put(allocator, try allocator.dupe(u8, "media_type"), .{ .string = try allocator.dupe(u8, image.mime_type) });
                try source.put(allocator, try allocator.dupe(u8, "data"), .{ .string = try allocator.dupe(u8, image.data) });
                try object.put(allocator, try allocator.dupe(u8, "source"), .{ .object = source });
                try content.append(.{ .object = object });
            },
            .thinking, .tool_call => {},
        }
    }

    if (content.items.len == 0) {
        try content.append(try buildTextBlockObject(allocator, "", null));
    }
    return try buildRoleMessageObject(allocator, "user", .{ .array = content });
}

fn buildAssistantMessageValue(
    allocator: std.mem.Allocator,
    assistant: types.AssistantMessage,
    is_oauth: bool,
) !std.json.Value {
    var content = std.json.Array.init(allocator);
    errdefer content.deinit();

    for (assistant.content) |block| {
        switch (block) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) continue;
                try content.append(try buildTextBlockObject(allocator, text.text, null));
            },
            .thinking => |thinking| {
                const signature = types.thinkingSignature(thinking);
                if (thinking.redacted) {
                    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "redacted_thinking") });
                    try object.put(allocator, try allocator.dupe(u8, "data"), .{ .string = try allocator.dupe(u8, signature orelse "") });
                    try content.append(.{ .object = object });
                    continue;
                }
                if (signature) |value| {
                    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "thinking") });
                    try object.put(allocator, try allocator.dupe(u8, "thinking"), .{ .string = try allocator.dupe(u8, thinking.thinking) });
                    try object.put(allocator, try allocator.dupe(u8, "signature"), .{ .string = try allocator.dupe(u8, value) });
                    try content.append(.{ .object = object });
                } else {
                    try content.append(try buildTextBlockObject(allocator, thinking.thinking, null));
                }
            },
            .image => {},
            .tool_call => |tool_call| {
                var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "tool_use") });
                try object.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, tool_call.id) });
                try object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, if (is_oauth) canonicalClaudeCodeToolName(tool_call.name) else tool_call.name) });
                try object.put(allocator, try allocator.dupe(u8, "input"), try cloneJsonValue(allocator, tool_call.arguments));
                try content.append(.{ .object = object });
            },
        }
    }

    if (!types.hasInlineToolCalls(assistant)) {
        if (assistant.tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "tool_use") });
                try object.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, tool_call.id) });
                try object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, if (is_oauth) canonicalClaudeCodeToolName(tool_call.name) else tool_call.name) });
                try object.put(allocator, try allocator.dupe(u8, "input"), try cloneJsonValue(allocator, tool_call.arguments));
                try content.append(.{ .object = object });
            }
        }
    }

    return try buildRoleMessageObject(allocator, "assistant", .{ .array = content });
}

fn buildToolResultUserMessageValue(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    cache_control: ?std.json.Value,
) !struct { value: std.json.Value, consumed: usize } {
    var content = std.json.Array.init(allocator);
    errdefer content.deinit();

    var consumed: usize = 0;
    while (consumed < messages.len) : (consumed += 1) {
        switch (messages[consumed]) {
            .tool_result => |tool_result| {
                var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "tool_result") });
                try object.put(allocator, try allocator.dupe(u8, "tool_use_id"), .{ .string = try allocator.dupe(u8, tool_result.tool_call_id) });
                try object.put(allocator, try allocator.dupe(u8, "content"), try buildToolResultContentValue(allocator, tool_result.content));
                if (tool_result.is_error) {
                    try object.put(allocator, try allocator.dupe(u8, "is_error"), .{ .bool = true });
                }
                try content.append(.{ .object = object });
            },
            else => break,
        }
    }

    if (cache_control) |_| {
        if (content.items.len > 0) {
            try applyCacheControlToBlock(allocator, &content.items[content.items.len - 1], cache_control.?);
        }
    }

    return .{
        .value = try buildRoleMessageObject(allocator, "user", .{ .array = content }),
        .consumed = consumed,
    };
}

fn buildToolResultContentValue(allocator: std.mem.Allocator, content: []const types.ContentBlock) !std.json.Value {
    var only_text = true;
    for (content) |block| {
        if (block != .text) {
            only_text = false;
            break;
        }
    }

    if (only_text) {
        var text = std.ArrayList(u8).empty;
        defer text.deinit(allocator);
        for (content, 0..) |block, index| {
            if (index > 0) try text.append(allocator, '\n');
            try text.appendSlice(allocator, block.text.text);
        }
        return .{ .string = try allocator.dupe(u8, text.items) };
    }

    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (content) |block| {
        switch (block) {
            .text => |text| try array.append(try buildTextBlockObject(allocator, text.text, null)),
            .image => |image| {
                var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                var source = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "image") });
                try source.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "base64") });
                try source.put(allocator, try allocator.dupe(u8, "media_type"), .{ .string = try allocator.dupe(u8, image.mime_type) });
                try source.put(allocator, try allocator.dupe(u8, "data"), .{ .string = try allocator.dupe(u8, image.data) });
                try object.put(allocator, try allocator.dupe(u8, "source"), .{ .object = source });
                try array.append(.{ .object = object });
            },
            .thinking => |thinking| try array.append(try buildTextBlockObject(allocator, thinking.thinking, null)),
            .tool_call => {},
        }
    }
    return .{ .array = array };
}

fn buildToolsValue(
    allocator: std.mem.Allocator,
    tools: []const types.Tool,
    is_oauth: bool,
    supports_eager_tool_input_streaming: bool,
    cache_control: ?std.json.Value,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (tools, 0..) |tool, index| {
        var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, if (is_oauth) canonicalClaudeCodeToolName(tool.name) else tool.name) });
        try object.put(allocator, try allocator.dupe(u8, "description"), .{ .string = try allocator.dupe(u8, tool.description) });
        if (supports_eager_tool_input_streaming) {
            try object.put(allocator, try allocator.dupe(u8, "eager_input_streaming"), .{ .bool = true });
        }

        var schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try schema.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });
        if (tool.parameters == .object) {
            if (tool.parameters.object.get("properties")) |properties| {
                try schema.put(allocator, try allocator.dupe(u8, "properties"), try cloneJsonValue(allocator, properties));
            } else {
                try schema.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) });
            }
            if (tool.parameters.object.get("required")) |required| {
                try schema.put(allocator, try allocator.dupe(u8, "required"), try cloneJsonValue(allocator, required));
            }
        } else {
            try schema.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) });
        }
        try object.put(allocator, try allocator.dupe(u8, "input_schema"), .{ .object = schema });
        if (cache_control != null and index == tools.len - 1) {
            try object.put(allocator, try allocator.dupe(u8, "cache_control"), try cloneJsonValue(allocator, cache_control.?));
        }
        try array.append(.{ .object = object });
    }
    return .{ .array = array };
}

fn buildTextBlockObject(allocator: std.mem.Allocator, text: []const u8, cache_control: ?std.json.Value) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "text") });
    try object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text) });
    if (cache_control) |value| {
        try object.put(allocator, try allocator.dupe(u8, "cache_control"), try cloneJsonValue(allocator, value));
    }
    return .{ .object = object };
}

fn buildRoleMessageObject(allocator: std.mem.Allocator, role: []const u8, content: std.json.Value) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, role) });
    try object.put(allocator, try allocator.dupe(u8, "content"), content);
    return .{ .object = object };
}

fn applyCacheControlToLastUserContent(allocator: std.mem.Allocator, message: *std.json.Value, cache_control: std.json.Value) !void {
    if (message.* != .object) return;
    const role_value = message.object.get("role") orelse return;
    if (role_value != .string or !std.mem.eql(u8, role_value.string, "user")) return;
    const content_value = message.object.getPtr("content") orelse return;
    if (content_value.* == .array and content_value.array.items.len > 0) {
        try applyCacheControlToBlock(allocator, &content_value.array.items[content_value.array.items.len - 1], cache_control);
    } else if (content_value.* == .string) {
        const text_copy = try allocator.dupe(u8, content_value.string);
        content_value.* = .{ .array = std.json.Array.init(allocator) };
        try content_value.array.append(try buildTextBlockObject(allocator, text_copy, cache_control));
        allocator.free(text_copy);
    }
}

fn applyCacheControlToBlock(allocator: std.mem.Allocator, block: *std.json.Value, cache_control: std.json.Value) !void {
    if (block.* != .object) return;
    try block.object.put(allocator, try allocator.dupe(u8, "cache_control"), try cloneJsonValue(allocator, cache_control));
}

fn applyAuthHeaders(
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
        try putOwnedHeader(allocator, headers, "cf-aig-authorization", authorization);
    } else if (std.mem.eql(u8, model.provider, "github-copilot") or usesAnthropicOAuth(model, api_key)) {
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
        defer allocator.free(authorization);
        try putOwnedHeader(allocator, headers, "Authorization", authorization);
    } else {
        try putOwnedHeader(allocator, headers, "x-api-key", api_key);
    }
}

fn applyBaseAnthropicHeaders(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    model: types.Model,
) !void {
    try putOwnedHeader(allocator, headers, "Content-Type", "application/json");
    try putOwnedHeader(allocator, headers, "Accept", "application/json");
    if (!isKimiCodingProvider(model)) {
        try putOwnedHeader(allocator, headers, "anthropic-dangerous-direct-browser-access", "true");
    }
    try putOwnedHeader(allocator, headers, "anthropic-version", "2023-06-01");
}

fn applyDefaultAnthropicHeaders(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !void {
    const api_key = if (options) |stream_options| stream_options.api_key orelse "" else "";
    if (try buildAnthropicBetaHeader(allocator, model, context, options, api_key)) |beta_header| {
        defer allocator.free(beta_header);
        try putOwnedHeader(allocator, headers, "anthropic-beta", beta_header);
    }

    if (usesAnthropicOAuth(model, api_key)) {
        const user_agent = try std.fmt.allocPrint(allocator, "claude-cli/{s}", .{CLAUDE_CODE_VERSION});
        defer allocator.free(user_agent);
        try putOwnedHeader(allocator, headers, "user-agent", user_agent);
        try putOwnedHeader(allocator, headers, "x-app", "cli");
    }
}

fn shouldUseFineGrainedToolStreamingBeta(model: types.Model, context: types.Context) bool {
    if (context.tools == null or context.tools.?.len == 0) return false;
    return !getAnthropicCompat(model).supports_eager_tool_input_streaming;
}

fn shouldUseInterleavedThinkingBeta(model: types.Model, options: ?types.StreamOptions) bool {
    if (supportsAdaptiveThinking(model)) return false;
    if (options) |stream_options| {
        return stream_options.anthropic_interleaved_thinking orelse true;
    }
    return true;
}

fn buildAnthropicBetaHeader(
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

fn isKimiCodingProvider(model: types.Model) bool {
    return std.mem.eql(u8, model.provider, "kimi-coding");
}

fn shouldTolerateNoncanonicalAnthropicChunk(model: types.Model) bool {
    return isKimiCodingProvider(model);
}

fn usesAnthropicOAuth(model: types.Model, api_key: []const u8) bool {
    return std.mem.eql(u8, model.provider, "anthropic") and isOAuthToken(api_key);
}

fn mergeHeaders(
    allocator: std.mem.Allocator,
    target: *std.StringHashMap([]const u8),
    source: ?std.StringHashMap([]const u8),
) !void {
    if (source) |headers| {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            try putOwnedHeader(allocator, target, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

fn putOwnedHeader(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    name: []const u8,
    value: []const u8,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    if (try headers.fetchPut(owned_name, owned_value)) |previous| {
        allocator.free(previous.key);
        allocator.free(previous.value);
    }
}

fn deinitOwnedHeaders(allocator: std.mem.Allocator, headers: *std.StringHashMap([]const u8)) void {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    headers.deinit();
}

fn asciiLowerAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, input.len);
    for (input, 0..) |byte, index| {
        output[index] = std.ascii.toLower(byte);
    }
    return output;
}

/// Normalize response header names to TypeScript-compatible lowercase keys
/// before invoking `on_response` callbacks. Mirrors the OpenAI Chat path so
/// callbacks can rely on consistent lookup semantics regardless of the
/// on-the-wire casing emitted by the upstream server.
fn normalizedResponseHeaders(
    allocator: std.mem.Allocator,
    maybe_headers: ?std.StringHashMap([]const u8),
) !std.StringHashMap([]const u8) {
    var normalized = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitOwnedHeaders(allocator, &normalized);

    if (maybe_headers) |headers| {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            const lower = try asciiLowerAlloc(allocator, entry.key_ptr.*);
            defer allocator.free(lower);
            try putOwnedHeader(allocator, &normalized, lower, entry.value_ptr.*);
        }
    }

    return normalized;
}

fn isOAuthToken(api_key: []const u8) bool {
    return std.mem.indexOf(u8, api_key, "sk-ant-oat") != null;
}

fn updateUsage(usage: *types.Usage, usage_value: std.json.Value) void {
    if (usage_value != .object) return;
    if (usage_value.object.get("input_tokens")) |value| {
        if (value == .integer) usage.input = @intCast(value.integer);
    }
    if (usage_value.object.get("output_tokens")) |value| {
        if (value == .integer) usage.output = @intCast(value.integer);
    }
    if (usage_value.object.get("cache_read_input_tokens")) |value| {
        if (value == .integer) usage.cache_read = @intCast(value.integer);
    }
    if (usage_value.object.get("cache_creation_input_tokens")) |value| {
        if (value == .integer) usage.cache_write = @intCast(value.integer);
    }
    usage.total_tokens = usage.input + usage.output + usage.cache_read + usage.cache_write;
}

fn calculateCost(model: types.Model, usage: *types.Usage) void {
    usage.cost.input = (@as(f64, @floatFromInt(usage.input)) / 1_000_000.0) * model.cost.input;
    usage.cost.output = (@as(f64, @floatFromInt(usage.output)) / 1_000_000.0) * model.cost.output;
    usage.cost.cache_read = (@as(f64, @floatFromInt(usage.cache_read)) / 1_000_000.0) * model.cost.cache_read;
    usage.cost.cache_write = (@as(f64, @floatFromInt(usage.cache_write)) / 1_000_000.0) * model.cost.cache_write;
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
}

fn findActiveBlock(active_blocks: *std.ArrayList(BlockEntry), value: std.json.Value) !*BlockEntry {
    const index_value = value.object.get("index") orelse return AnthropicError.InvalidAnthropicChunk;
    if (index_value != .integer) return AnthropicError.InvalidAnthropicChunk;
    const anthropic_index: usize = @intCast(index_value.integer);
    const found_index = findActiveBlockIndex(active_blocks, anthropic_index) orelse return AnthropicError.InvalidAnthropicChunk;
    return &active_blocks.items[found_index];
}

fn findActiveBlockIndex(active_blocks: *const std.ArrayList(BlockEntry), anthropic_index: usize) ?usize {
    for (active_blocks.items, 0..) |entry, index| {
        if (entry.anthropic_index == anthropic_index) return index;
    }
    return null;
}

fn deinitCurrentBlock(allocator: std.mem.Allocator, block: *CurrentBlock) void {
    switch (block.*) {
        .text => |*text| text.deinit(allocator),
        .thinking => |*thinking| {
            textDeinit(allocator, &thinking.text);
            if (thinking.signature) |signature| allocator.free(signature);
        },
        .tool_call => |*tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            tool_call.partial_json.deinit(allocator);
        },
    }
}

fn textDeinit(allocator: std.mem.Allocator, text: *std.ArrayList(u8)) void {
    text.deinit(allocator);
}

fn normalizeIncomingToolName(
    allocator: std.mem.Allocator,
    name: []const u8,
    tools: ?[]const types.Tool,
    options: ?types.StreamOptions,
) ![]const u8 {
    _ = options;
    if (tools) |available_tools| {
        for (available_tools) |tool| {
            if (std.ascii.eqlIgnoreCase(tool.name, name)) {
                return try allocator.dupe(u8, tool.name);
            }
        }
    }
    return try allocator.dupe(u8, name);
}

fn canonicalClaudeCodeToolName(name: []const u8) []const u8 {
    inline for ([_]struct { lower: []const u8, canonical: []const u8 }{
        .{ .lower = "read", .canonical = "Read" },
        .{ .lower = "write", .canonical = "Write" },
        .{ .lower = "edit", .canonical = "Edit" },
        .{ .lower = "bash", .canonical = "Bash" },
        .{ .lower = "grep", .canonical = "Grep" },
        .{ .lower = "glob", .canonical = "Glob" },
        .{ .lower = "askuserquestion", .canonical = "AskUserQuestion" },
        .{ .lower = "enterplanmode", .canonical = "EnterPlanMode" },
        .{ .lower = "exitplanmode", .canonical = "ExitPlanMode" },
        .{ .lower = "killshell", .canonical = "KillShell" },
        .{ .lower = "notebookedit", .canonical = "NotebookEdit" },
        .{ .lower = "skill", .canonical = "Skill" },
        .{ .lower = "task", .canonical = "Task" },
        .{ .lower = "taskoutput", .canonical = "TaskOutput" },
        .{ .lower = "todowrite", .canonical = "TodoWrite" },
        .{ .lower = "webfetch", .canonical = "WebFetch" },
        .{ .lower = "websearch", .canonical = "WebSearch" },
    }) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.lower, name)) return entry.canonical;
    }
    return name;
}

const ResponseHeaderServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    response_headers: []const u8,
    body: []const u8,
    thread: ?std.Thread = null,

    fn init(io: std.Io, response_headers: []const u8, body: []const u8) !ResponseHeaderServer {
        return .{
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .response_headers = response_headers,
            .body = body,
        };
    }

    fn start(self: *ResponseHeaderServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *ResponseHeaderServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
    }

    fn url(self: *const ResponseHeaderServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.server.socket.address.getPort()});
    }

    fn run(self: *ResponseHeaderServer) void {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            else => std.debug.panic("response header test server accept failed: {}", .{err}),
        };
        defer stream.close(self.io);

        readRequestHead(stream) catch |err| std.debug.panic("response header test server read failed: {}", .{err});
        writeResponse(self, stream) catch |err| std.debug.panic("response header test server write failed: {}", .{err});
    }

    fn readRequestHead(stream: std.Io.net.Stream) !void {
        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(std.testing.io, &read_buffer);
        var tail = [_]u8{ 0, 0, 0, 0 };
        var count: usize = 0;

        while (true) {
            const byte = try reader.interface.takeByte();
            tail[count % tail.len] = byte;
            count += 1;

            if (count >= 4) {
                const start_index = count % tail.len;
                const ordered = [_]u8{
                    tail[start_index],
                    tail[(start_index + 1) % tail.len],
                    tail[(start_index + 2) % tail.len],
                    tail[(start_index + 3) % tail.len],
                };
                if (std.mem.eql(u8, &ordered, "\r\n\r\n")) break;
            }
        }
    }

    fn writeResponse(self: *ResponseHeaderServer, stream: std.Io.net.Stream) !void {
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        try writer.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n{s}\r\n",
            .{ self.body.len, self.response_headers },
        );
        try writer.interface.writeAll(self.body);
        try writer.interface.flush();
    }
};

const OnResponseCapture = struct {
    var called = false;
    var status: u16 = 0;

    fn reset() void {
        called = false;
        status = 0;
    }

    fn callback(callback_status: u16, headers: std.StringHashMap([]const u8), model: types.Model) !void {
        called = true;
        status = callback_status;
        try std.testing.expectEqualStrings("anthropic-messages", model.api);
        try std.testing.expectEqualStrings("text/event-stream", headers.get("content-type").?);
        try std.testing.expectEqualStrings("req_123", headers.get("x-request-id").?);
        try std.testing.expectEqualStrings("17", headers.get("anthropic-processing-ms").?);
        try std.testing.expect(headers.get("Content-Type") == null);
    }
};

fn drainStreamAndFreeDoneMessage(
    allocator: std.mem.Allocator,
    stream: *event_stream.AssistantMessageEventStream,
) !void {
    while (stream.next()) |event| {
        defer event.deinitTransient(allocator);
        if (event.message) |message| freeAssistantMessageOwned(allocator, message);
    }
}

fn freeToolCallOwned(allocator: std.mem.Allocator, tool_call: types.ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    if (tool_call.thought_signature) |signature| allocator.free(signature);
    freeJsonValue(allocator, tool_call.arguments);
}

fn freeAssistantMessageOwned(allocator: std.mem.Allocator, message: types.AssistantMessage) void {
    for (message.content) |block| {
        switch (block) {
            .text => |text| {
                allocator.free(text.text);
                if (text.text_signature) |signature| allocator.free(signature);
            },
            .thinking => |thinking| {
                allocator.free(thinking.thinking);
                if (thinking.thinking_signature) |signature| allocator.free(signature);
                if (thinking.signature) |signature| allocator.free(signature);
            },
            .image => |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            },
            .tool_call => |tool_call| freeToolCallOwned(allocator, tool_call),
        }
    }
    if (message.content.len > 0) allocator.free(message.content);
    if (message.tool_calls) |tool_calls| {
        for (tool_calls) |tool_call| freeToolCallOwned(allocator, tool_call);
        allocator.free(tool_calls);
    }
    if (message.response_id) |response_id| allocator.free(response_id);
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return provider_json.cloneValue(allocator, value);
}

fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    provider_json.freeValue(allocator, value);
}

fn runtimePreservationTestModel(api: types.Api, provider: types.Provider) types.Model {
    return .{
        .id = "runtime-test-model",
        .name = "Runtime Test Model",
        .api = api,
        .provider = provider,
        .base_url = "https://example.test",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
    };
}

test "parseSseStreamLines preserves partial Anthropic text before malformed terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "event: message_start\n" ++
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"anthropic-runtime\"}}\n\n" ++
            "event: content_block_start\n" ++
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
            "event: content_block_delta\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial\"}}\n\n" ++
            "data: {not-json}\n\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();
    const context = types.Context{ .messages = &[_]types.Message{} };

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("anthropic-messages", "anthropic"), context, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial", delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial", text_end.content.?);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqualStrings("anthropic-runtime", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
}

test "stream preserves partial Anthropic text before mid-stream abort terminal event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    const chunks = [_]test_stream_server.DelayedChunk{
        .{
            .bytes = "event: message_start\n" ++
                "data: {\"type\":\"message_start\",\"message\":{\"id\":\"anthropic-abort\"}}\n\n" ++
                "event: content_block_start\n" ++
                "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
                "event: content_block_delta\n" ++
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial anthropic\"}}\n\n",
            .delay_after_ms = 120,
        },
        .{ .bytes = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n" },
    };
    var server = try test_stream_server.DelayedChunkServer.init(io, &chunks);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);
    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 8192,
    };

    var abort_signal = std.atomic.Value(bool).init(false);
    const abort_thread = try test_stream_server.startAbortThread(io, &abort_signal, 20);
    defer abort_thread.join();

    var stream = try AnthropicProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = "test-key",
        .signal = &abort_signal,
    });
    defer stream.deinit();

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial anthropic", delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial anthropic", text_end.content.?);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expectEqualStrings("Request was aborted", terminal.error_message.?);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqual(types.StopReason.aborted, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("anthropic-abort", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial anthropic", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);
}

test "parseSseStreamLines finalizes partial Anthropic blocks before provider error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const redacted_secret_placeholder = "sk" ++ "-anthropic-secret";
    const body = try allocator.dupe(
        u8,
        "event: message_start\n" ++
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"anthropic-provider-error\"}}\n\n" ++
            "event: content_block_start\n" ++
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
            "event: content_block_delta\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial text\"}}\n\n" ++
            "event: content_block_start\n" ++
            "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n" ++
            "event: content_block_delta\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"partial thought\"}}\n\n" ++
            "event: content_block_delta\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig-1\"}}\n\n" ++
            "event: content_block_start\n" ++
            "data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"todoWrite\",\"input\":{}}}\n\n" ++
            "event: content_block_delta\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"todos\\\":\\\"item\\\"}\"}}\n\n" ++
            "event: error\n" ++
            "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"provider failed with " ++ redacted_secret_placeholder ++ " at /Users/alice/file.zig\"}}\n\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();
    const context = types.Context{ .messages = &[_]types.Message{} };

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("anthropic-messages", "anthropic"), context, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_delta, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_delta, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_delta, stream.next().?.event_type);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial text", text_end.content.?);
    const thinking_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.thinking_end, thinking_end.event_type);
    try std.testing.expectEqualStrings("partial thought", thinking_end.content.?);
    const tool_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqualStrings("todoWrite", tool_end.tool_call.?.name);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqualStrings("anthropic-provider-error", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial text", terminal.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("partial thought", terminal.message.?.content[1].thinking.thinking);
    try std.testing.expectEqualStrings("sig-1", terminal.message.?.content[1].thinking.signature.?);
    try std.testing.expectEqualStrings("item", terminal.message.?.content[2].tool_call.arguments.object.get("todos").?.string);
    try std.testing.expect(terminal.message.?.tool_calls == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.error_message.?, redacted_secret_placeholder) == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.error_message.?, "/Users/alice") == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
    try std.testing.expect(stream.next() == null);
}

test "parseSseStreamLines finalizes partial Anthropic text before EOF terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "event: content_block_start\n" ++
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
            "event: content_block_delta\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial before eof\"}}\n\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();
    const context = types.Context{ .messages = &[_]types.Message{} };

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("anthropic-messages", "anthropic"), context, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_delta, stream.next().?.event_type);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial before eof", text_end.content.?);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqualStrings("partial before eof", terminal.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);
}

fn streamErrorContractAnthropicModel(base_url: []const u8) types.Model {
    return .{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };
}

fn streamErrorContractAnthropicContext() types.Context {
    return .{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };
}

fn expectOnlyTerminalErrorAnthropic(
    stream: *event_stream.AssistantMessageEventStream,
    expected_error: []const u8,
    expected_stop: types.StopReason,
) !void {
    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expect(event.error_message != null);
    try std.testing.expectEqualStrings(expected_error, event.error_message.?);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expectEqual(expected_stop, event.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqualStrings(event.message.?.api, result.api);
    try std.testing.expectEqualStrings(event.message.?.provider, result.provider);
    try std.testing.expectEqualStrings(event.message.?.model, result.model);
    try std.testing.expectEqual(expected_stop, result.stop_reason);
}

fn failingAnthropicOnPayload(allocator: std.mem.Allocator, payload: std.json.Value, model: types.Model) !?std.json.Value {
    _ = allocator;
    _ = payload;
    _ = model;
    return error.FixtureAnthropicPayloadFailure;
}

fn failingAnthropicOnResponse(status: u16, headers: std.StringHashMap([]const u8), model: types.Model) !void {
    _ = status;
    _ = headers;
    _ = model;
    return error.FixtureAnthropicResponseFailure;
}

test "VAL-M9-STREAM-003 stream URL construction failure returns one terminal error event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try AnthropicProvider.stream(
        allocator,
        io,
        streamErrorContractAnthropicModel("not-a-valid-url"),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "test-key" },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorAnthropic(&stream, "InvalidUrl", .error_reason);
}

test "VAL-M9-STREAM-003 streamSimple URL construction failure returns one terminal error event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try AnthropicProvider.streamSimple(
        allocator,
        io,
        streamErrorContractAnthropicModel("not-a-valid-url"),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "test-key" },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorAnthropic(&stream, "InvalidUrl", .error_reason);
}

test "VAL-M9-STREAM-004 stream on_payload failure returns one terminal error event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try AnthropicProvider.stream(
        allocator,
        io,
        streamErrorContractAnthropicModel("https://api.anthropic.com/v1"),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "test-key", .on_payload = failingAnthropicOnPayload },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorAnthropic(&stream, "FixtureAnthropicPayloadFailure", .error_reason);
}

test "VAL-M9-STREAM-005 stream on_response failure returns one terminal error event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_unread\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-3-7-sonnet-latest\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n";
    var server = try provider_error.TestStatusServer.init(io, 200, "OK", "", body);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var stream = try AnthropicProvider.stream(
        allocator,
        io,
        streamErrorContractAnthropicModel(url),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "test-key", .on_response = &failingAnthropicOnResponse },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorAnthropic(&stream, "FixtureAnthropicResponseFailure", .error_reason);
}

test "VAL-M9-STREAM-010 stream pre-aborted signal yields terminal aborted event without throwing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var aborted = std.atomic.Value(bool).init(true);

    var stream = try AnthropicProvider.stream(
        allocator,
        io,
        streamErrorContractAnthropicModel("http://127.0.0.1:1"),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "test-key", .signal = &aborted },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorAnthropic(&stream, "Request was aborted", .aborted);
}

test "VAL-M9-STREAM-010 streamSimple pre-aborted signal matches stream terminal aborted semantics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var aborted = std.atomic.Value(bool).init(true);

    var simple_stream = try AnthropicProvider.streamSimple(
        allocator,
        io,
        streamErrorContractAnthropicModel("http://127.0.0.1:1"),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "test-key", .signal = &aborted },
    );
    defer simple_stream.deinit();

    try expectOnlyTerminalErrorAnthropic(&simple_stream, "Request was aborted", .aborted);
}

fn expectMissingApiKeyTerminalErrorAnthropic(
    stream: *event_stream.AssistantMessageEventStream,
    expected_provider: []const u8,
) !void {
    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expect(event.error_message != null);

    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "No API key for provider: {s}",
        .{expected_provider},
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, event.error_message.?);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);

    // Diagnostic must not leak secrets, environment values, bearer tokens,
    // credential-store paths, or local auth paths.
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "Bearer") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "sk-ant") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "ANTHROPIC_API_KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "ANTHROPIC_OAUTH_TOKEN") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "x-api-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/home/") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "auth.json") == null);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqualStrings(event.message.?.api, result.api);
    try std.testing.expectEqualStrings(event.message.?.provider, result.provider);
    try std.testing.expectEqualStrings(event.message.?.model, result.model);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    std.testing.allocator.free(result.error_message.?);
}

test "VAL-M9-STREAM-006 stream missing api key returns sanitized terminal error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try AnthropicProvider.stream(
        allocator,
        io,
        streamErrorContractAnthropicModel("https://api.anthropic.com/v1"),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "" },
    );
    defer stream.deinit();

    try expectMissingApiKeyTerminalErrorAnthropic(&stream, "anthropic");
}

test "VAL-M9-STREAM-006 streamSimple missing api key returns sanitized terminal error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try AnthropicProvider.streamSimple(
        allocator,
        io,
        streamErrorContractAnthropicModel("https://api.anthropic.com/v1"),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "" },
    );
    defer stream.deinit();

    try expectMissingApiKeyTerminalErrorAnthropic(&stream, "anthropic");
}

test "VAL-M9-STREAM-006 stream null api key options returns sanitized terminal error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try AnthropicProvider.stream(
        allocator,
        io,
        streamErrorContractAnthropicModel("https://api.anthropic.com/v1"),
        streamErrorContractAnthropicContext(),
        null,
    );
    defer stream.deinit();

    try expectMissingApiKeyTerminalErrorAnthropic(&stream, "anthropic");
}

test "anthropic stream cloudflare provider resolves base_url placeholders via env" {
    // Verifies that isCloudflareProvider gates resolveCloudflareBaseUrl: when the
    // env var referenced in base_url is absent, the stream returns a terminal
    // EnvironmentVariableNotFound error event rather than a networking error for a
    // literal {VAR} URL.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const model = types.Model{
        .id = "cloudflare-anthropic-model",
        .name = "Cloudflare Anthropic Model",
        .api = "anthropic-messages",
        .provider = "cloudflare-ai-gateway",
        .base_url = "https://gateway.ai.cloudflare.com/v1/{ANTHROPIC_WIRE_IN_CF_TEST_ABSENT_VAR}/{ANTHROPIC_WIRE_IN_CF_TEST_GATEWAY_ABSENT}/anthropic",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 4096,
    };

    const context = streamErrorContractAnthropicContext();

    var stream = try AnthropicProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.error_message != null);
    try std.testing.expectEqualStrings("EnvironmentVariableNotFound", event.error_message.?);
    try std.testing.expect(stream.next() == null);
}

const SSE_FUZZ_SMOKE_SEED: u64 = 0x5eed_55e5_0000_0001;

const SseFuzzExpectation = union(enum) {
    text_done: []const u8,
    text_error: []const u8,
    empty_error,
};

test "VAL-REFACTOR-008 deterministic SSE parser chunk fuzz smoke" {
    const allocator = std.heap.page_allocator;
    const cases = [_]struct {
        label: []const u8,
        body: []const u8,
        model: types.Model,
        expected: SseFuzzExpectation,
    }{
        .{
            .label = "repairable-stream-with-unknown-fields",
            .body = ": ignored comment\n" ++
                "event: vendor_debug\n" ++
                "data: {\"ignored\":true}\n" ++
                "\n" ++
                "event: message_start\n" ++
                "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_fuzz\",\"usage\":{\"input_tokens\":3,\"output_tokens\":0}},\"unknown\":true}\n" ++
                "\n" ++
                "event: content_block_start\n" ++
                "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"},\"extra\":\"ok\"}\n" ++
                "\n" ++
                "event: content_block_delta\n" ++
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"repair\\\\q\"}}\n" ++
                "\n" ++
                "event: content_block_stop\n" ++
                "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
                "\n" ++
                "event: message_delta\n" ++
                "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":4}}\n" ++
                "\n" ++
                "event: message_stop\n" ++
                "data: {\"type\":\"message_stop\"}\n" ++
                "\n",
            .model = sseFuzzModel("claude-fuzz", "anthropic"),
            .expected = .{ .text_done = "repair\\q" },
        },
        .{
            .label = "truncated-repairable-kimi-stream",
            .body = "event: content_block_start\n" ++
                "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
                "\n" ++
                "event: content_block_delta\n" ++
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial\"}}\n" ++
                "\n",
            .model = sseFuzzModel("kimi-for-coding", "kimi-coding"),
            .expected = .{ .text_done = "partial" },
        },
        .{
            .label = "malformed-frame-preserves-partial-text",
            .body = "event: content_block_start\n" ++
                "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
                "\n" ++
                "event: content_block_delta\n" ++
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"before\"}}\n" ++
                "\n" ++
                "event: content_block_delta\n" ++
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":123}}\n" ++
                "\n",
            .model = sseFuzzModel("claude-fuzz", "anthropic"),
            .expected = .{ .text_error = "before" },
        },
        .{
            .label = "boundary-size-repairable-text",
            .body = try sseFuzzBoundaryBody(allocator),
            .model = sseFuzzModel("kimi-for-coding", "kimi-coding"),
            .expected = .{ .text_done = "boundary-" },
        },
        .{
            .label = "malformed-truncated-empty-frame",
            .body = "event: content_block_delta\n" ++
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"unterminated",
            .model = sseFuzzModel("claude-fuzz", "anthropic"),
            .expected = .empty_error,
        },
    };

    for (cases) |case| {
        var chunk_lengths = std.ArrayList(usize).empty;
        defer chunk_lengths.deinit(allocator);
        const chunked_body = try deterministicChunkedCopy(allocator, case.body, SSE_FUZZ_SMOKE_SEED, case.label, &chunk_lengths);
        defer allocator.free(chunked_body);

        sseFuzzSmokeCase(allocator, case.label, chunked_body, chunk_lengths.items, case.model, case.expected) catch |err| {
            reportSseFuzzFailure(SSE_FUZZ_SMOKE_SEED, case.label, chunked_body, chunk_lengths.items);
            return err;
        };
    }
}

fn sseFuzzModel(id: []const u8, provider: []const u8) types.Model {
    return .{
        .id = id,
        .name = id,
        .api = "anthropic-messages",
        .provider = provider,
        .base_url = "https://example.invalid/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };
}

fn sseFuzzBoundaryBody(allocator: std.mem.Allocator) ![]const u8 {
    const text = try allocator.alloc(u8, 8192);
    @memset(text, 'x');
    defer allocator.free(text);
    return std.fmt.allocPrint(
        allocator,
        "event: content_block_start\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n" ++
            "\n" ++
            "event: content_block_delta\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"boundary-{s}\"}}}}\n" ++
            "\n",
        .{text},
    );
}

fn deterministicChunkedCopy(
    allocator: std.mem.Allocator,
    input: []const u8,
    seed: u64,
    label: []const u8,
    chunk_lengths: *std.ArrayList(usize),
) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed ^ std.hash.Wyhash.hash(seed, label));
    const random = prng.random();
    var out = try std.ArrayList(u8).initCapacity(allocator, input.len);
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < input.len) {
        const remaining = input.len - index;
        const max_chunk = @min(remaining, @as(usize, 31));
        const len = random.intRangeAtMost(usize, 1, max_chunk);
        try out.appendSlice(allocator, input[index .. index + len]);
        try chunk_lengths.append(allocator, len);
        index += len;
    }
    return out.toOwnedSlice(allocator);
}

fn sseFuzzSmokeCase(
    allocator: std.mem.Allocator,
    label: []const u8,
    body: []const u8,
    chunk_lengths: []const usize,
    model: types.Model,
    expected: SseFuzzExpectation,
) !void {
    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, std.Io.failing);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{ .messages = &[_]types.Message{} }, null);

    switch (expected) {
        .text_done => |prefix| try expectSseFuzzTerminal(label, chunk_lengths, &stream_instance, .done, prefix),
        .text_error => |prefix| try expectSseFuzzTerminal(label, chunk_lengths, &stream_instance, .error_event, prefix),
        .empty_error => try expectSseFuzzTerminal(label, chunk_lengths, &stream_instance, .error_event, null),
    }
}

fn expectSseFuzzTerminal(
    label: []const u8,
    chunk_lengths: []const usize,
    stream_instance: *event_stream.AssistantMessageEventStream,
    expected_terminal: types.EventType,
    expected_text_prefix: ?[]const u8,
) !void {
    var saw_terminal = false;
    while (stream_instance.next()) |event| {
        if (event.event_type == .done or event.event_type == .error_event) {
            saw_terminal = true;
            if (event.event_type != expected_terminal) {
                reportSseFuzzTerminalMismatch(label, chunk_lengths, expected_terminal, event.event_type);
                return error.TestExpectedEqual;
            }
            if (expected_text_prefix) |prefix| {
                if (event.message == null or event.message.?.content.len == 0 or event.message.?.content[0] != .text or
                    !std.mem.startsWith(u8, event.message.?.content[0].text.text, prefix))
                {
                    reportSseFuzzTerminalMismatch(label, chunk_lengths, expected_terminal, event.event_type);
                    return error.TestExpectedEqual;
                }
            }
        }
    }
    if (!saw_terminal) {
        reportSseFuzzTerminalMismatch(label, chunk_lengths, expected_terminal, .start);
        return error.TestExpectedEqual;
    }
}

fn reportSseFuzzFailure(seed: u64, label: []const u8, body: []const u8, chunk_lengths: []const usize) void {
    std.debug.print("SSE fuzz smoke failure seed=0x{x} case={s} input={s} chunks=", .{ seed, label, body });
    for (chunk_lengths, 0..) |len, index| {
        if (index > 0) std.debug.print(",", .{});
        std.debug.print("{d}", .{len});
    }
    std.debug.print("\n", .{});
}

fn reportSseFuzzTerminalMismatch(
    label: []const u8,
    chunk_lengths: []const usize,
    expected_terminal: types.EventType,
    actual_terminal: types.EventType,
) void {
    std.debug.print("SSE fuzz smoke assertion case={s} expected={s} actual={s} smallest_chunks=", .{
        label,
        @tagName(expected_terminal),
        @tagName(actual_terminal),
    });
    for (chunk_lengths, 0..) |len, index| {
        if (index > 0) std.debug.print(",", .{});
        std.debug.print("{d}", .{len});
    }
    std.debug.print("\n", .{});
}
