const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");

const AnthropicError = error{
    UnknownStopReason,
    InvalidAnthropicChunk,
};

const CLAUDE_CODE_IDENTITY = "You are Claude Code, Anthropic's official CLI for Claude.";
const CLAUDE_CODE_VERSION = "2.1.75";
const TOOL_PLACEHOLDER_TEXT = "";

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

        var payload = try buildRequestPayload(allocator, model, context, options);
        defer freeJsonValue(allocator, payload);

        if (options) |stream_options| {
            if (stream_options.on_payload) |callback| {
                if (try callback(allocator, payload, model)) |replacement| {
                    freeJsonValue(allocator, payload);
                    payload = replacement;
                }
            }
        }

        const json_body = try std.json.Stringify.valueAlloc(allocator, payload, .{});
        defer allocator.free(json_body);

        const url = try std.fmt.allocPrint(allocator, "{s}/messages", .{model.base_url});
        defer allocator.free(url);

        var headers = std.StringHashMap([]const u8).init(allocator);
        defer headers.deinit();
        try headers.put("Content-Type", "application/json");
        try headers.put("Accept", "text/event-stream");
        try headers.put("anthropic-version", "2023-06-01");
        try applyAuthHeaders(allocator, &headers, model, options);
        try applyDefaultAnthropicHeaders(allocator, &headers, model, context, options);
        try mergeHeaders(allocator, &headers, model.headers);
        if (options) |stream_options| {
            try mergeHeaders(allocator, &headers, stream_options.headers);
        }

        var client = try http_client.HttpClient.init(allocator, io);
        defer client.deinit();

        var response = try client.requestStreaming(.{
            .method = .POST,
            .url = url,
            .headers = headers,
            .body = json_body,
            .aborted = if (options) |stream_options| stream_options.signal else null,
        });
        defer response.deinit();

        if (options) |stream_options| {
            if (stream_options.on_response) |callback| {
                var response_headers = std.StringHashMap([]const u8).init(allocator);
                defer response_headers.deinit();
                callback(response.status, response_headers, model);
            }
        }

        if (response.status != 200) {
            const error_message = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ response.status, response.body });
            const message = types.AssistantMessage{
                .content = &[_]types.ContentBlock{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = types.Usage.init(),
                .stop_reason = .error_reason,
                .error_message = error_message,
                .timestamp = 0,
            };
            stream_instance.push(.{
                .event_type = .error_event,
                .error_message = error_message,
                .message = message,
            });
            stream_instance.end(message);
            return stream_instance;
        }

        try parseSseStreamLines(allocator, &stream_instance, &response, model, context, options);
        return stream_instance;
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

    const is_oauth = isOAuthToken(if (options) |stream_options| stream_options.api_key orelse "" else "");
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

    if (model.reasoning) {
        var thinking = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try thinking.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "enabled") });
        try thinking.put(allocator, try allocator.dupe(u8, "budget_tokens"), .{ .integer = 1024 });
        try thinking.put(allocator, try allocator.dupe(u8, "display"), .{ .string = try allocator.dupe(u8, "summarized") });
        try payload.put(allocator, try allocator.dupe(u8, "thinking"), .{ .object = thinking });
    }

    if (options) |stream_options| {
        if (stream_options.temperature) |temperature| {
            if (!model.reasoning) {
                try payload.put(allocator, try allocator.dupe(u8, "temperature"), .{ .float = temperature });
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

test "buildRequestPayload includes system tools and cache control" {
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
    try std.testing.expect(object.get("thinking").? == .object);
}

test "buildRequestPayload applies Claude Code stealth mode for oauth" {
    const allocator = std.testing.allocator;

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
        .api_key = "sk-ant-oat-secret",
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
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n" ++
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
}

test "parse anthropic stream emits tool call and thinking events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

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
        .api_key = "sk-ant-oat-secret",
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
    defer headers.deinit();

    try applyDefaultAnthropicHeaders(allocator, &headers, model, context, null);
    try std.testing.expectEqualStrings(
        "fine-grained-tool-streaming-2025-05-14",
        headers.get("anthropic-beta").?,
    );
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

    while (try streaming.readLine()) |line| {
        if (isAbortRequested(options)) {
            output.stop_reason = .aborted;
            output.error_message = "Request was aborted";
            stream_ptr.push(.{
                .event_type = .error_event,
                .error_message = output.error_message,
                .message = output,
            });
            stream_ptr.end(output);
            return;
        }

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "event:")) continue;
        const data = parseSseLine(trimmed) orelse continue;
        if (std.mem.eql(u8, data, "[DONE]")) break;

        var parsed = try json_parse.parseStreamingJson(allocator, data);
        defer parsed.deinit();
        const value = parsed.value;
        if (value != .object) return AnthropicError.InvalidAnthropicChunk;

        const event_type = value.object.get("type") orelse return AnthropicError.InvalidAnthropicChunk;
        if (event_type != .string) return AnthropicError.InvalidAnthropicChunk;

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
            continue;
        }

        if (std.mem.eql(u8, event_type.string, "content_block_start")) {
            try handleContentBlockStart(allocator, &active_blocks, stream_ptr, value, context, options);
            continue;
        }

        if (std.mem.eql(u8, event_type.string, "content_block_delta")) {
            try handleContentBlockDelta(allocator, &active_blocks, stream_ptr, value);
            continue;
        }

        if (std.mem.eql(u8, event_type.string, "content_block_stop")) {
            try handleContentBlockStop(allocator, &active_blocks, &content_blocks, &tool_calls, stream_ptr, value);
            continue;
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
            continue;
        }
    }

    output.usage.total_tokens = output.usage.input + output.usage.output + output.usage.cache_read + output.usage.cache_write;
    calculateCost(model, &output.usage);
    output.content = try content_blocks.toOwnedSlice(allocator);
    output.tool_calls = if (tool_calls.items.len > 0) try tool_calls.toOwnedSlice(allocator) else null;

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

fn handleContentBlockStart(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    value: std.json.Value,
    context: types.Context,
    options: ?types.StreamOptions,
) !void {
    const index_value = value.object.get("index") orelse return AnthropicError.InvalidAnthropicChunk;
    if (index_value != .integer) return AnthropicError.InvalidAnthropicChunk;
    const anthropic_index: usize = @intCast(index_value.integer);
    const content_block = value.object.get("content_block") orelse return AnthropicError.InvalidAnthropicChunk;
    if (content_block != .object) return AnthropicError.InvalidAnthropicChunk;
    const block_type = content_block.object.get("type") orelse return AnthropicError.InvalidAnthropicChunk;
    if (block_type != .string) return AnthropicError.InvalidAnthropicChunk;

    const event_index = active_blocks.items.len;
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
) !void {
    const entry = try findActiveBlock(active_blocks, value);
    const delta_value = value.object.get("delta") orelse return AnthropicError.InvalidAnthropicChunk;
    if (delta_value != .object) return AnthropicError.InvalidAnthropicChunk;
    const delta_type = delta_value.object.get("type") orelse return AnthropicError.InvalidAnthropicChunk;
    if (delta_type != .string) return AnthropicError.InvalidAnthropicChunk;

    if (std.mem.eql(u8, delta_type.string, "text_delta")) {
        const text_value = delta_value.object.get("text") orelse return AnthropicError.InvalidAnthropicChunk;
        if (text_value != .string) return AnthropicError.InvalidAnthropicChunk;
        if (entry.block != .text) return AnthropicError.InvalidAnthropicChunk;
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
        const thinking_value = delta_value.object.get("thinking") orelse return AnthropicError.InvalidAnthropicChunk;
        if (thinking_value != .string) return AnthropicError.InvalidAnthropicChunk;
        if (entry.block != .thinking) return AnthropicError.InvalidAnthropicChunk;
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
        const signature_value = delta_value.object.get("signature") orelse return AnthropicError.InvalidAnthropicChunk;
        if (signature_value != .string) return AnthropicError.InvalidAnthropicChunk;
        if (entry.block != .thinking) return AnthropicError.InvalidAnthropicChunk;
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
        const partial_json = delta_value.object.get("partial_json") orelse return AnthropicError.InvalidAnthropicChunk;
        if (partial_json != .string) return AnthropicError.InvalidAnthropicChunk;
        if (entry.block != .tool_call) return AnthropicError.InvalidAnthropicChunk;
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

fn handleContentBlockStop(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    value: std.json.Value,
) !void {
    const index_value = value.object.get("index") orelse return AnthropicError.InvalidAnthropicChunk;
    if (index_value != .integer) return AnthropicError.InvalidAnthropicChunk;
    const anthropic_index: usize = @intCast(index_value.integer);

    const remove_index = findActiveBlockIndex(active_blocks, anthropic_index) orelse return AnthropicError.InvalidAnthropicChunk;
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
            const final_tool_call = types.ToolCall{
                .id = try allocator.dupe(u8, tool.id),
                .name = try allocator.dupe(u8, tool.name),
                .arguments = arguments,
            };
            try tool_calls.append(allocator, final_tool_call);
            try content_blocks.append(allocator, .{ .text = .{ .text = TOOL_PLACEHOLDER_TEXT } });
            stream_ptr.push(.{
                .event_type = .toolcall_end,
                .content_index = @intCast(entry.event_index),
                .tool_call = final_tool_call,
            });
        },
    }
}

fn parseSseLine(line: []const u8) ?[]const u8 {
    const prefix = "data: ";
    if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    return null;
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
            .assistant => |assistant| try array.append(try buildAssistantMessageValue(allocator, assistant, is_oauth)),
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
            .thinking => {},
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
                if (thinking.redacted) {
                    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "redacted_thinking") });
                    try object.put(allocator, try allocator.dupe(u8, "data"), .{ .string = try allocator.dupe(u8, thinking.signature orelse "") });
                    try content.append(.{ .object = object });
                    continue;
                }
                if (thinking.signature) |signature| {
                    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "thinking") });
                    try object.put(allocator, try allocator.dupe(u8, "thinking"), .{ .string = try allocator.dupe(u8, thinking.thinking) });
                    try object.put(allocator, try allocator.dupe(u8, "signature"), .{ .string = try allocator.dupe(u8, signature) });
                    try content.append(.{ .object = object });
                } else {
                    try content.append(try buildTextBlockObject(allocator, thinking.thinking, null));
                }
            },
            .image => {},
        }
    }

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

    if (std.mem.eql(u8, model.provider, "github-copilot") or isOAuthToken(api_key)) {
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
        try headers.put("Authorization", authorization);
    } else {
        try headers.put("x-api-key", try allocator.dupe(u8, api_key));
    }
}

fn applyDefaultAnthropicHeaders(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !void {
    const api_key = if (options) |stream_options| stream_options.api_key orelse "" else "";
    const use_fine_grained_tool_streaming_beta = shouldUseFineGrainedToolStreamingBeta(model, context);

    if (std.mem.eql(u8, model.provider, "github-copilot")) {
        if (use_fine_grained_tool_streaming_beta) {
            try headers.put("anthropic-beta", "fine-grained-tool-streaming-2025-05-14");
        }
        return;
    }

    if (isOAuthToken(api_key)) {
        if (use_fine_grained_tool_streaming_beta) {
            try headers.put("anthropic-beta", "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14");
        } else {
            try headers.put("anthropic-beta", "claude-code-20250219,oauth-2025-04-20");
        }
        try headers.put("user-agent", try std.fmt.allocPrint(allocator, "claude-cli/{s}", .{CLAUDE_CODE_VERSION}));
        try headers.put("x-app", "cli");
    } else {
        if (use_fine_grained_tool_streaming_beta) {
            try headers.put("anthropic-beta", "fine-grained-tool-streaming-2025-05-14");
        }
    }
}

fn shouldUseFineGrainedToolStreamingBeta(model: types.Model, context: types.Context) bool {
    if (context.tools == null or context.tools.?.len == 0) return false;
    return !getAnthropicCompat(model).supports_eager_tool_input_streaming;
}

fn mergeHeaders(
    allocator: std.mem.Allocator,
    target: *std.StringHashMap([]const u8),
    source: ?std.StringHashMap([]const u8),
) !void {
    if (source) |headers| {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            try target.put(try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.*));
        }
    }
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

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => |boolean| return .{ .bool = boolean },
        .integer => |integer| return .{ .integer = integer },
        .float => |float| return .{ .float = float },
        .number_string => |number_string| return .{ .number_string = try allocator.dupe(u8, number_string) },
        .string => |string| return .{ .string = try allocator.dupe(u8, string) },
        .array => |array| {
            var clone = std.json.Array.init(allocator);
            for (array.items) |item| try clone.append(try cloneJsonValue(allocator, item));
            return .{ .array = clone };
        },
        .object => |object| {
            var clone = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try clone.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            return .{ .object = clone };
        },
    }
}

fn isAbortRequested(options: ?types.StreamOptions) bool {
    if (options) |stream_options| {
        if (stream_options.signal) |signal| {
            return signal.load(.seq_cst);
        }
    }
    return false;
}

fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            var owned = arr;
            owned.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var owned = obj;
            owned.deinit(allocator);
        },
        else => {},
    }
}
