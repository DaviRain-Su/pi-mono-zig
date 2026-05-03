const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");
const provider_error = @import("../shared/provider_error.zig");
const env_api_keys = @import("../env_api_keys.zig");
const openai = @import("openai.zig");

pub const KimiProvider = struct {
    pub const api = "kimi-completions";

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
        var env_api_key: ?[]u8 = null;
        defer if (env_api_key) |key| allocator.free(key);

        const provided_api_key = if (options) |stream_options| stream_options.api_key else null;
        const api_key = blk: {
            if (provided_api_key) |key| break :blk key;
            env_api_key = try env_api_keys.getEnvApiKey(allocator, model.provider);
            break :blk env_api_key;
        };

        if (api_key == null or api_key.?.len == 0) {
            try pushMissingApiKeyError(allocator, stream_instance, model);
            return;
        }

        const payload = try buildRequestPayload(allocator, model, context, options);
        defer freeJsonValue(allocator, payload);

        var json_out: std.Io.Writer.Allocating = .init(allocator);
        defer json_out.deinit();
        try std.json.Stringify.value(payload, .{}, &json_out.writer);

        var headers = std.StringHashMap([]const u8).init(allocator);
        defer headers.deinit();

        if (model.headers) |model_headers| {
            var it = model_headers.iterator();
            while (it.next()) |entry| {
                try headers.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        try headers.put("Content-Type", "application/json");
        try headers.put("Accept", "text/event-stream");

        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key.?});
        defer allocator.free(auth_header);
        try headers.put("Authorization", auth_header);

        if (options) |stream_options| {
            if (stream_options.headers) |extra_headers| {
                var it = extra_headers.iterator();
                while (it.next()) |entry| {
                    try headers.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }

        const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{model.base_url});
        defer allocator.free(url);

        const request = http_client.HttpRequest{
            .method = .POST,
            .url = url,
            .headers = headers,
            .body = json_out.written(),
            .aborted = if (options) |stream_options| stream_options.signal else null,
        };

        var client = try http_client.HttpClient.init(allocator, io);
        defer client.deinit();

        var streaming = try client.requestStreaming(request);
        defer streaming.deinit();

        if (streaming.status != 200) {
            const response_body = try streaming.readAllBounded(allocator, provider_error.MAX_PROVIDER_ERROR_BODY_READ_BYTES);
            defer allocator.free(response_body);
            try provider_error.pushHttpStatusError(allocator, stream_instance, model, streaming.status, response_body);
            return;
        }

        try parseSseStreamLines(allocator, stream_instance, &streaming, model, options);
    }

    pub fn streamSimple(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        return try stream(allocator, io, model, context, options);
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

const CurrentBlock = union(enum) {
    text: struct {
        event_index: usize,
        text: std.ArrayList(u8),
    },
    thinking: struct {
        event_index: usize,
        text: std.ArrayList(u8),
    },
    tool_call: struct {
        event_index: usize,
        id: std.ArrayList(u8),
        name: std.ArrayList(u8),
        partial_args: std.ArrayList(u8),
    },
};

fn deinitCurrentBlock(allocator: std.mem.Allocator, block: *CurrentBlock) void {
    switch (block.*) {
        .text => |*text| text.text.deinit(allocator),
        .thinking => |*thinking| thinking.text.deinit(allocator),
        .tool_call => |*tool_call| {
            tool_call.id.deinit(allocator);
            tool_call.name.deinit(allocator);
            tool_call.partial_args.deinit(allocator);
        },
    }
}

pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    var messages = std.json.Array.init(allocator);
    errdefer messages.deinit();

    if (context.system_prompt) |system_prompt| {
        try messages.append(.{ .object = try buildMessageObject(allocator, "system", system_prompt) });
    }

    for (context.messages) |message| {
        switch (message) {
            .user => |user_message| try messages.append(try buildUserMessage(allocator, model, user_message)),
            .assistant => |assistant_message| try messages.append(try buildAssistantMessage(allocator, assistant_message)),
            .tool_result => |tool_result| try messages.append(try buildToolResultMessage(allocator, model, tool_result)),
        }
    }

    var payload = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer payload.deinit(allocator);

    try payload.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, model.id) });
    try payload.put(allocator, try allocator.dupe(u8, "messages"), .{ .array = messages });
    try payload.put(allocator, try allocator.dupe(u8, "stream"), .{ .bool = true });

    var stream_options = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer stream_options.deinit(allocator);
    try stream_options.put(allocator, try allocator.dupe(u8, "include_usage"), .{ .bool = true });
    try payload.put(allocator, try allocator.dupe(u8, "stream_options"), .{ .object = stream_options });

    if (options) |stream_config| {
        if (stream_config.max_tokens) |max_tokens| {
            try payload.put(allocator, try allocator.dupe(u8, "max_completion_tokens"), .{ .integer = @intCast(max_tokens) });
        }
        if (stream_config.temperature) |temperature| {
            try payload.put(allocator, try allocator.dupe(u8, "temperature"), .{ .float = temperature });
        }
        if (stream_config.session_id) |session_id| {
            if (stream_config.cache_retention != .none) {
                try payload.put(allocator, try allocator.dupe(u8, "prompt_cache_key"), .{ .string = try allocator.dupe(u8, session_id) });
            }
        }
    }

    if (model.reasoning) {
        try payload.put(allocator, try allocator.dupe(u8, "thinking"), try buildThinkingConfig(allocator, context));
    }

    if (context.tools) |tools| {
        var tool_array = std.json.Array.init(allocator);
        errdefer tool_array.deinit();
        for (tools) |tool| {
            try tool_array.append(try buildToolObject(allocator, tool));
        }
        try payload.put(allocator, try allocator.dupe(u8, "tools"), .{ .array = tool_array });
    }

    return .{ .object = payload };
}

fn buildThinkingConfig(allocator: std.mem.Allocator, context: types.Context) !std.json.Value {
    var thinking = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer thinking.deinit(allocator);

    try thinking.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "enabled") });
    if (containsHistoricalThinking(context)) {
        try thinking.put(allocator, try allocator.dupe(u8, "keep"), .{ .string = try allocator.dupe(u8, "all") });
    }
    return .{ .object = thinking };
}

fn containsHistoricalThinking(context: types.Context) bool {
    for (context.messages) |message| {
        switch (message) {
            .assistant => |assistant_message| {
                for (assistant_message.content) |block| {
                    if (block == .thinking and block.thinking.thinking.len > 0) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn buildUserMessage(
    allocator: std.mem.Allocator,
    model: types.Model,
    user_message: types.UserMessage,
) !std.json.Value {
    var has_images = false;
    for (user_message.content) |block| {
        if (block == .image) {
            has_images = true;
            break;
        }
    }

    var supports_images = false;
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) {
            supports_images = true;
            break;
        }
    }

    if (has_images and supports_images) {
        var content = std.json.Array.init(allocator);
        errdefer content.deinit();

        for (user_message.content) |block| {
            switch (block) {
                .text => |text| {
                    var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    errdefer part.deinit(allocator);
                    try part.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "text") });
                    const sanitized = try sanitizeSurrogates(allocator, text.text);
                    defer allocator.free(sanitized);
                    try part.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, sanitized) });
                    try content.append(.{ .object = part });
                },
                .image => |image| {
                    var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    errdefer part.deinit(allocator);
                    try part.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "image_url") });

                    var image_value = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    errdefer image_value.deinit(allocator);

                    const url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ image.mime_type, image.data });
                    defer allocator.free(url);
                    try image_value.put(allocator, try allocator.dupe(u8, "url"), .{ .string = try allocator.dupe(u8, url) });
                    try part.put(allocator, try allocator.dupe(u8, "image_url"), .{ .object = image_value });
                    try content.append(.{ .object = part });
                },
                .thinking, .tool_call => {},
            }
        }

        var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        errdefer object.deinit(allocator);
        try object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "user") });
        try object.put(allocator, try allocator.dupe(u8, "content"), .{ .array = content });
        return .{ .object = object };
    }

    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);

    for (user_message.content) |block| {
        switch (block) {
            .text => |content| {
                if (text.items.len > 0) try text.appendSlice(allocator, "\n");
                try text.appendSlice(allocator, content.text);
            },
            .image => {
                if (!supports_images) {
                    if (text.items.len > 0) try text.appendSlice(allocator, "\n");
                    try text.appendSlice(allocator, "(image omitted: model does not support images)");
                }
            },
            .thinking, .tool_call => {},
        }
    }

    return .{ .object = try buildMessageObject(allocator, "user", text.items) };
}

fn buildAssistantMessage(
    allocator: std.mem.Allocator,
    assistant_message: types.AssistantMessage,
) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);

    try object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "assistant") });

    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);

    var reasoning = std.ArrayList(u8).empty;
    defer reasoning.deinit(allocator);

    for (assistant_message.content) |block| {
        switch (block) {
            .text => |content| {
                if (text.items.len > 0) try text.appendSlice(allocator, "\n");
                try text.appendSlice(allocator, content.text);
            },
            .thinking => |thinking| {
                if (reasoning.items.len > 0) try reasoning.appendSlice(allocator, "\n");
                try reasoning.appendSlice(allocator, thinking.thinking);
            },
            .image, .tool_call => {},
        }
    }

    const sanitized_text = try sanitizeSurrogates(allocator, text.items);
    defer allocator.free(sanitized_text);
    try object.put(allocator, try allocator.dupe(u8, "content"), .{ .string = try allocator.dupe(u8, sanitized_text) });

    if (reasoning.items.len > 0) {
        const sanitized_reasoning = try sanitizeSurrogates(allocator, reasoning.items);
        defer allocator.free(sanitized_reasoning);
        try object.put(allocator, try allocator.dupe(u8, "reasoning_content"), .{ .string = try allocator.dupe(u8, sanitized_reasoning) });
    }

    if (assistant_message.stop_reason == .aborted) {
        try object.put(allocator, try allocator.dupe(u8, "partial"), .{ .bool = true });
    }

    if (assistant_message.tool_calls) |tool_calls| {
        var tool_call_array = std.json.Array.init(allocator);
        errdefer tool_call_array.deinit();
        for (tool_calls) |tool_call| {
            var tool_call_object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            errdefer tool_call_object.deinit(allocator);
            try tool_call_object.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, tool_call.id) });
            try tool_call_object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "function") });

            var function_object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            errdefer function_object.deinit(allocator);
            try function_object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool_call.name) });

            const arguments_json = try std.json.Stringify.valueAlloc(allocator, tool_call.arguments, .{});
            defer allocator.free(arguments_json);
            try function_object.put(allocator, try allocator.dupe(u8, "arguments"), .{ .string = try allocator.dupe(u8, arguments_json) });

            try tool_call_object.put(allocator, try allocator.dupe(u8, "function"), .{ .object = function_object });
            try tool_call_array.append(.{ .object = tool_call_object });
        }
        try object.put(allocator, try allocator.dupe(u8, "tool_calls"), .{ .array = tool_call_array });
    }

    return .{ .object = object };
}

fn buildToolResultMessage(
    allocator: std.mem.Allocator,
    model: types.Model,
    tool_result: types.ToolResultMessage,
) !std.json.Value {
    _ = model;

    var content = std.ArrayList(u8).empty;
    defer content.deinit(allocator);

    for (tool_result.content) |block| {
        switch (block) {
            .text => |text| {
                if (content.items.len > 0) try content.appendSlice(allocator, "\n");
                try content.appendSlice(allocator, text.text);
            },
            .image, .thinking, .tool_call => {},
        }
    }

    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    try object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "tool") });
    const sanitized_content = try sanitizeSurrogates(allocator, content.items);
    defer allocator.free(sanitized_content);
    try object.put(allocator, try allocator.dupe(u8, "content"), .{ .string = try allocator.dupe(u8, sanitized_content) });
    try object.put(allocator, try allocator.dupe(u8, "tool_call_id"), .{ .string = try allocator.dupe(u8, tool_result.tool_call_id) });
    if (tool_result.tool_name.len > 0) {
        try object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool_result.tool_name) });
    }
    return .{ .object = object };
}

fn buildToolObject(allocator: std.mem.Allocator, tool: types.Tool) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "function") });

    var function_object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer function_object.deinit(allocator);
    try function_object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool.name) });
    try function_object.put(allocator, try allocator.dupe(u8, "description"), .{ .string = try allocator.dupe(u8, tool.description) });
    try function_object.put(allocator, try allocator.dupe(u8, "parameters"), try cloneJsonValue(allocator, tool.parameters));
    try object.put(allocator, try allocator.dupe(u8, "function"), .{ .object = function_object });
    return .{ .object = object };
}

fn buildMessageObject(allocator: std.mem.Allocator, role: []const u8, content: []const u8) !std.json.ObjectMap {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    try object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, role) });
    const sanitized_content = try sanitizeSurrogates(allocator, content);
    defer allocator.free(sanitized_content);
    try object.put(allocator, try allocator.dupe(u8, "content"), .{ .string = try allocator.dupe(u8, sanitized_content) });
    return object;
}

fn parseSseStreamLines(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    streaming: *http_client.StreamingResponse,
    model: types.Model,
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

    var current_block: ?CurrentBlock = null;
    defer if (current_block) |*block| deinitCurrentBlock(allocator, block);

    stream_ptr.push(.{ .event_type = .start });

    while (true) {
        const maybe_line = streaming.readLine() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try emitRuntimeFailure(allocator, stream_ptr, &output, &current_block, &content_blocks, &tool_calls, err);
                return;
            },
        };
        const line = maybe_line orelse break;
        if (isAbortRequested(options)) {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &current_block, &content_blocks, &tool_calls, error.RequestAborted);
            return;
        }

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "event:")) continue;

        const data = parseSseLine(trimmed) orelse continue;
        if (std.mem.eql(u8, data, "[DONE]")) break;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try emitRuntimeFailure(allocator, stream_ptr, &output, &current_block, &content_blocks, &tool_calls, err);
                return;
            },
        };
        defer parsed.deinit();

        if (parsed.value != .object) continue;
        const value = parsed.value;

        if (value.object.get("id")) |id_value| {
            if (id_value == .string and output.response_id == null) {
                output.response_id = try allocator.dupe(u8, id_value.string);
            }
        }

        if (value.object.get("usage")) |usage_value| {
            output.usage = parseChunkUsage(usage_value);
        }

        const choices = value.object.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;

        const choice = choices.array.items[0];
        if (choice != .object) continue;

        if (choice.object.get("usage")) |usage_value| {
            output.usage = parseChunkUsage(usage_value);
        }

        if (choice.object.get("finish_reason")) |finish_reason| {
            if (finish_reason == .string) {
                const mapped = mapStopReason(finish_reason.string);
                output.stop_reason = mapped.stop_reason;
                if (mapped.error_message) |error_message| {
                    output.error_message = error_message;
                }
            }
        }

        const delta = choice.object.get("delta") orelse continue;
        if (delta != .object) continue;

        if (delta.object.get("reasoning_content")) |reasoning_value| {
            if (reasoning_value == .string and reasoning_value.string.len > 0) {
                try appendTextDelta(allocator, &current_block, &content_blocks, &tool_calls, stream_ptr, reasoning_value.string, true);
            }
        } else if (delta.object.get("reasoning")) |reasoning_value| {
            if (reasoning_value == .string and reasoning_value.string.len > 0) {
                try appendTextDelta(allocator, &current_block, &content_blocks, &tool_calls, stream_ptr, reasoning_value.string, true);
            }
        }

        if (delta.object.get("content")) |content_value| {
            if (content_value == .string and content_value.string.len > 0) {
                try appendTextDelta(allocator, &current_block, &content_blocks, &tool_calls, stream_ptr, content_value.string, false);
            }
        }

        if (delta.object.get("tool_calls")) |tool_calls_value| {
            if (tool_calls_value == .array) {
                for (tool_calls_value.array.items) |tool_call_value| {
                    if (tool_call_value != .object) continue;

                    const tool_call_id = if (tool_call_value.object.get("id")) |id_value|
                        if (id_value == .string) id_value.string else null
                    else
                        null;

                    const tool_call_name = if (tool_call_value.object.get("function")) |function_value| blk: {
                        if (function_value == .object) {
                            if (function_value.object.get("name")) |name_value| {
                                if (name_value == .string) break :blk name_value.string;
                            }
                        }
                        break :blk null;
                    } else null;

                    const tool_call_arguments = if (tool_call_value.object.get("function")) |function_value| blk: {
                        if (function_value == .object) {
                            if (function_value.object.get("arguments")) |arguments_value| {
                                if (arguments_value == .string) break :blk arguments_value.string;
                            }
                        }
                        break :blk null;
                    } else null;

                    const needs_new_block = blk: {
                        if (current_block == null) break :blk true;
                        if (current_block.? != .tool_call) break :blk true;
                        if (tool_call_id) |id| {
                            const current_id = std.mem.trim(u8, current_block.?.tool_call.id.items, " ");
                            if (current_id.len > 0 and !std.mem.eql(u8, current_id, id)) break :blk true;
                        }
                        break :blk false;
                    };

                    if (needs_new_block) {
                        try finishCurrentBlock(allocator, &current_block, &content_blocks, &tool_calls, stream_ptr);
                        current_block = .{ .tool_call = .{
                            .event_index = content_blocks.items.len,
                            .id = std.ArrayList(u8).empty,
                            .name = std.ArrayList(u8).empty,
                            .partial_args = std.ArrayList(u8).empty,
                        } };
                        stream_ptr.push(.{
                            .event_type = .toolcall_start,
                            .content_index = @intCast(content_blocks.items.len),
                        });
                    }

                    if (current_block) |*block| {
                        if (block.* == .tool_call) {
                            if (tool_call_id) |id| {
                                block.tool_call.id.clearRetainingCapacity();
                                try block.tool_call.id.appendSlice(allocator, id);
                            }
                            if (tool_call_name) |name| {
                                block.tool_call.name.clearRetainingCapacity();
                                try block.tool_call.name.appendSlice(allocator, name);
                            }
                            const event_delta = if (tool_call_arguments) |arguments| blk: {
                                try block.tool_call.partial_args.appendSlice(allocator, arguments);
                                break :blk try allocator.dupe(u8, arguments);
                            } else null;

                            stream_ptr.push(.{
                                .event_type = .toolcall_delta,
                                .content_index = @intCast(block.tool_call.event_index),
                                .delta = event_delta,
                                .owns_delta = event_delta != null,
                            });
                        }
                    }
                }
            }
        }
    }

    try finishCurrentBlock(allocator, &current_block, &content_blocks, &tool_calls, stream_ptr);

    if (content_blocks.items.len > 0) {
        const blocks = try allocator.alloc(types.ContentBlock, content_blocks.items.len);
        for (content_blocks.items, 0..) |block, index| blocks[index] = block;
        output.content = blocks;
    }

    if (tool_calls.items.len > 0) {
        const output_tool_calls = try allocator.alloc(types.ToolCall, tool_calls.items.len);
        for (tool_calls.items, 0..) |tool_call, index| output_tool_calls[index] = tool_call;
        output.tool_calls = output_tool_calls;
    }

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

fn finalizeOutputFromPartials(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    try finishCurrentBlock(allocator, current_block, content_blocks, tool_calls, stream_ptr);
    if (output.content.len == 0 and content_blocks.items.len > 0) {
        const blocks = try allocator.alloc(types.ContentBlock, content_blocks.items.len);
        for (content_blocks.items, 0..) |block, index| blocks[index] = block;
        output.content = blocks;
        content_blocks.clearRetainingCapacity();
    }
    if (output.tool_calls == null and tool_calls.items.len > 0) {
        const output_tool_calls = try allocator.alloc(types.ToolCall, tool_calls.items.len);
        for (tool_calls.items, 0..) |tool_call, index| output_tool_calls[index] = tool_call;
        output.tool_calls = output_tool_calls;
        tool_calls.clearRetainingCapacity();
    }
}

fn emitRuntimeFailure(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    err: anyerror,
) !void {
    try finalizeOutputFromPartials(allocator, output, current_block, content_blocks, tool_calls, stream_ptr);
    output.stop_reason = provider_error.runtimeStopReason(err);
    output.error_message = provider_error.runtimeErrorMessage(err);
    provider_error.pushTerminalRuntimeError(stream_ptr, output.*);
}

fn appendTextDelta(
    allocator: std.mem.Allocator,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    delta: []const u8,
    is_thinking: bool,
) !void {
    if (current_block.* == null or !matchesCurrentBlock(current_block.*.?, is_thinking)) {
        try finishCurrentBlock(allocator, current_block, content_blocks, tool_calls, stream_ptr);
        current_block.* = if (is_thinking)
            .{ .thinking = .{ .event_index = content_blocks.items.len, .text = std.ArrayList(u8).empty } }
        else
            .{ .text = .{ .event_index = content_blocks.items.len, .text = std.ArrayList(u8).empty } };
        stream_ptr.push(.{
            .event_type = if (is_thinking) .thinking_start else .text_start,
            .content_index = @intCast(content_blocks.items.len),
        });
    }

    if (current_block.*) |*block| {
        switch (block.*) {
            .text => |*text| {
                try text.text.appendSlice(allocator, delta);
                stream_ptr.push(.{
                    .event_type = .text_delta,
                    .content_index = @intCast(text.event_index),
                    .delta = try allocator.dupe(u8, delta),
                    .owns_delta = true,
                });
            },
            .thinking => |*thinking| {
                try thinking.text.appendSlice(allocator, delta);
                stream_ptr.push(.{
                    .event_type = .thinking_delta,
                    .content_index = @intCast(thinking.event_index),
                    .delta = try allocator.dupe(u8, delta),
                    .owns_delta = true,
                });
            },
            .tool_call => unreachable,
        }
    }
}

fn matchesCurrentBlock(block: CurrentBlock, is_thinking: bool) bool {
    return switch (block) {
        .text => !is_thinking,
        .thinking => is_thinking,
        .tool_call => false,
    };
}

fn finishCurrentBlock(
    allocator: std.mem.Allocator,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    if (current_block.*) |*block| {
        switch (block.*) {
            .text => |*text| {
                const owned = try allocator.dupe(u8, text.text.items);
                try content_blocks.append(allocator, .{ .text = .{ .text = owned } });
                stream_ptr.push(.{
                    .event_type = .text_end,
                    .content_index = @intCast(text.event_index),
                    .content = owned,
                });
            },
            .thinking => |*thinking| {
                const owned = try allocator.dupe(u8, thinking.text.items);
                try content_blocks.append(allocator, .{ .thinking = .{
                    .thinking = owned,
                    .signature = null,
                    .redacted = false,
                } });
                stream_ptr.push(.{
                    .event_type = .thinking_end,
                    .content_index = @intCast(thinking.event_index),
                    .content = owned,
                });
            },
            .tool_call => |*tool_call| {
                const id = try allocator.dupe(u8, std.mem.trim(u8, tool_call.id.items, " "));
                errdefer allocator.free(id);
                const name = try allocator.dupe(u8, std.mem.trim(u8, tool_call.name.items, " "));
                errdefer allocator.free(name);
                const arguments = try parseStreamingJsonToValue(allocator, std.mem.trim(u8, tool_call.partial_args.items, " "));
                errdefer freeJsonValue(allocator, arguments);

                const placeholder = try allocator.dupe(u8, "");
                errdefer allocator.free(placeholder);
                try content_blocks.append(allocator, .{ .text = .{ .text = placeholder } });
                errdefer _ = content_blocks.pop();

                const stored_tool_call: types.ToolCall = .{
                    .id = id,
                    .name = name,
                    .arguments = arguments,
                };
                try tool_calls.append(allocator, stored_tool_call);
                errdefer _ = tool_calls.pop();
                stream_ptr.push(.{
                    .event_type = .toolcall_end,
                    .content_index = @intCast(tool_call.event_index),
                    .tool_call = stored_tool_call,
                });
            },
        }
        deinitCurrentBlock(allocator, block);
        current_block.* = null;
    }
}

fn isAbortRequested(options: ?types.StreamOptions) bool {
    if (options) |stream_options| {
        if (stream_options.signal) |signal| {
            return signal.load(.monotonic);
        }
    }
    return false;
}

pub fn parseSseLine(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "data: ")) return line[6..];
    if (std.mem.startsWith(u8, line, "data:")) return std.mem.trim(u8, line[5..], " ");
    return null;
}

pub fn parseChunk(allocator: std.mem.Allocator, data: []const u8) !?std.json.Parsed(std.json.Value) {
    if (data.len == 0 or std.mem.eql(u8, data, "[DONE]")) return null;
    return try std.json.parseFromSlice(std.json.Value, allocator, data, .{ .allocate = .alloc_always });
}

fn parseChunkUsage(value: std.json.Value) types.Usage {
    var usage = types.Usage.init();
    if (value != .object) return usage;

    const prompt_tokens = extractU32Field(value, "prompt_tokens");
    const completion_tokens = extractU32Field(value, "completion_tokens");
    const explicit_total_tokens = extractU32Field(value, "total_tokens");

    var cached_tokens = extractU32Field(value, "cached_tokens");
    var cache_write_tokens: u32 = 0;
    var reasoning_tokens: u32 = 0;

    if (value.object.get("prompt_tokens_details")) |details| {
        if (details == .object) {
            cached_tokens = @max(cached_tokens, extractU32Field(details, "cached_tokens"));
            cache_write_tokens = extractU32Field(details, "cache_write_tokens");
        }
    }

    if (value.object.get("completion_tokens_details")) |details| {
        if (details == .object) {
            reasoning_tokens = extractU32Field(details, "reasoning_tokens");
        }
    }

    const cache_read_tokens = if (cache_write_tokens > 0)
        @max(@as(u32, 0), cached_tokens - cache_write_tokens)
    else
        cached_tokens;

    usage.input = @max(@as(u32, 0), prompt_tokens - cache_read_tokens - cache_write_tokens);
    usage.output = completion_tokens + reasoning_tokens;
    usage.cache_read = cache_read_tokens;
    usage.cache_write = cache_write_tokens;
    usage.total_tokens = if (explicit_total_tokens > 0)
        explicit_total_tokens
    else
        usage.input + usage.output + usage.cache_read + usage.cache_write;
    return usage;
}

fn extractU32Field(value: std.json.Value, key: []const u8) u32 {
    if (value != .object) return 0;
    if (value.object.get(key)) |field| {
        return switch (field) {
            .integer => @intCast(field.integer),
            else => 0,
        };
    }
    return 0;
}

fn mapStopReason(reason: []const u8) struct { stop_reason: types.StopReason, error_message: ?[]const u8 } {
    if (std.mem.eql(u8, reason, "stop") or std.mem.eql(u8, reason, "end")) return .{ .stop_reason = .stop, .error_message = null };
    if (std.mem.eql(u8, reason, "length")) return .{ .stop_reason = .length, .error_message = null };
    if (std.mem.eql(u8, reason, "tool_calls") or std.mem.eql(u8, reason, "function_call")) return .{ .stop_reason = .tool_use, .error_message = null };
    if (std.mem.eql(u8, reason, "content_filter")) return .{ .stop_reason = .error_reason, .error_message = "Provider finish_reason: content_filter" };
    if (std.mem.eql(u8, reason, "network_error")) return .{ .stop_reason = .error_reason, .error_message = "Provider finish_reason: network_error" };
    return .{ .stop_reason = .error_reason, .error_message = reason };
}

fn parseStreamingJsonToValue(allocator: std.mem.Allocator, input: []const u8) !std.json.Value {
    if (input.len == 0) return .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) };
    var parsed = json_parse.parseStreamingJson(allocator, input) catch {
        return .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) };
    };
    defer parsed.deinit();
    return try cloneJsonValue(allocator, parsed.value);
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => |bool_value| return .{ .bool = bool_value },
        .integer => |integer_value| return .{ .integer = integer_value },
        .float => |float_value| return .{ .float = float_value },
        .string => |string_value| return .{ .string = try allocator.dupe(u8, string_value) },
        .number_string => |number_string| return .{ .number_string = try allocator.dupe(u8, number_string) },
        .array => |array_value| {
            var cloned = std.json.Array.init(allocator);
            errdefer cloned.deinit();
            for (array_value.items) |item| {
                try cloned.append(try cloneJsonValue(allocator, item));
            }
            return .{ .array = cloned };
        },
        .object => |object_value| {
            var cloned = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            errdefer cloned.deinit(allocator);
            var iterator = object_value.iterator();
            while (iterator.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                try cloned.put(allocator, key, try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            return .{ .object = cloned };
        },
    }
}

fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |string_value| allocator.free(string_value),
        .number_string => |number_string| allocator.free(number_string),
        .array => |array_value| {
            for (array_value.items) |item| freeJsonValue(allocator, item);
            var array_copy = array_value;
            array_copy.deinit();
        },
        .object => |object_value| {
            var iterator = object_value.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var object_copy = object_value;
            object_copy.deinit(allocator);
        },
        else => {},
    }
}

fn sanitizeSurrogates(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return try openai.sanitizeSurrogates(allocator, text);
}

fn freeEvent(allocator: std.mem.Allocator, event: types.AssistantMessageEvent) void {
    event.deinitTransient(allocator);
    if (event.error_message) |error_message| allocator.free(error_message);
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
            .image => {},
            .tool_call => |tool_call| freeToolCallOwned(allocator, tool_call),
        }
    }
    allocator.free(message.content);
    if (message.tool_calls) |tool_calls| {
        for (tool_calls) |tool_call| freeToolCallOwned(allocator, tool_call);
        allocator.free(tool_calls);
    }
    if (message.response_id) |response_id| allocator.free(response_id);
    if (message.error_message) |error_message| allocator.free(error_message);
}

test "buildRequestPayload uses kimi-specific fields" {
    const allocator = std.testing.allocator;

    var tool_schema = std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) };
    defer freeJsonValue(allocator, tool_schema);
    try tool_schema.object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });

    const tools = &[_]types.Tool{
        .{
            .name = "CodeRunner",
            .description = "Run code",
            .parameters = tool_schema,
        },
    };

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = "https://api.moonshot.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .assistant = .{
                .content = &[_]types.ContentBlock{
                    .{ .thinking = .{ .thinking = "Need to preserve reasoning." } },
                    .{ .text = .{ .text = "Partial answer" } },
                },
                .api = "kimi-completions",
                .provider = "kimi",
                .model = "kimi-k2.6",
                .usage = types.Usage.init(),
                .stop_reason = .aborted,
                .timestamp = 1,
            } },
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Please continue" } }},
                .timestamp = 2,
            } },
        },
        .tools = tools,
    };

    const options = types.StreamOptions{
        .max_tokens = 4096,
        .session_id = "session-123",
    };

    const payload = try buildRequestPayload(allocator, model, context, options);
    defer freeJsonValue(allocator, payload);

    try std.testing.expectEqualStrings("kimi-k2.6", payload.object.get("model").?.string);
    try std.testing.expect(payload.object.get("max_completion_tokens") != null);
    try std.testing.expect(payload.object.get("max_tokens") == null);
    try std.testing.expectEqualStrings("session-123", payload.object.get("prompt_cache_key").?.string);

    const thinking = payload.object.get("thinking").?;
    try std.testing.expect(thinking == .object);
    try std.testing.expectEqualStrings("enabled", thinking.object.get("type").?.string);
    try std.testing.expectEqualStrings("all", thinking.object.get("keep").?.string);

    const messages = payload.object.get("messages").?;
    try std.testing.expect(messages == .array);
    const assistant_message = messages.array.items[0];
    try std.testing.expect(assistant_message == .object);
    try std.testing.expect(assistant_message.object.get("partial").?.bool);
    try std.testing.expectEqualStrings("Need to preserve reasoning.", assistant_message.object.get("reasoning_content").?.string);

    const tools_value = payload.object.get("tools").?;
    const tool_function = tools_value.array.items[0].object.get("function").?;
    try std.testing.expect(tool_function == .object);
    try std.testing.expect(tool_function.object.get("strict") == null);
}

test "parseSseStream emits kimi thinking and text events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"id\":\"cmpl_kimi\",\"choices\":[{\"delta\":{\"reasoning_content\":\"Need tool\"},\"finish_reason\":null}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"content\":\"Done\"},\"finish_reason\":\"stop\",\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":20,\"cached_tokens\":4}}]}\n" ++
            "data: [DONE]\n",
    );

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = "https://api.moonshot.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    const event1 = stream_instance.next().?;
    defer freeEvent(allocator, event1);
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream_instance.next().?;
    defer freeEvent(allocator, event2);
    try std.testing.expectEqual(types.EventType.thinking_start, event2.event_type);

    const event3 = stream_instance.next().?;
    defer freeEvent(allocator, event3);
    try std.testing.expectEqual(types.EventType.thinking_delta, event3.event_type);
    try std.testing.expectEqualStrings("Need tool", event3.delta.?);

    const event4 = stream_instance.next().?;
    defer freeEvent(allocator, event4);
    try std.testing.expectEqual(types.EventType.thinking_end, event4.event_type);

    const event5 = stream_instance.next().?;
    defer freeEvent(allocator, event5);
    try std.testing.expectEqual(types.EventType.text_start, event5.event_type);

    const event6 = stream_instance.next().?;
    defer freeEvent(allocator, event6);
    try std.testing.expectEqual(types.EventType.text_delta, event6.event_type);
    try std.testing.expectEqualStrings("Done", event6.delta.?);

    const event7 = stream_instance.next().?;
    defer freeEvent(allocator, event7);
    try std.testing.expectEqual(types.EventType.text_end, event7.event_type);

    const event8 = stream_instance.next().?;
    defer freeEvent(allocator, event8);
    try std.testing.expectEqual(types.EventType.done, event8.event_type);
    try std.testing.expectEqualStrings("cmpl_kimi", event8.message.?.response_id.?);
    try std.testing.expectEqual(@as(u32, 6), event8.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 20), event8.message.?.usage.output);
    try std.testing.expectEqual(types.StopReason.stop, event8.message.?.stop_reason);
}

test "parseChunk rejects malformed provider control envelopes without JSON repair" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.SyntaxError, parseChunk(allocator, "{\"id\":\"chunk\" trailing"));
}

test "parseSseStream emits kimi tool call events across fragmented deltas" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_kimi\",\"function\":{\"name\":\"run_terminal\",\"arguments\":\"{\\\"command\\\":\\\"echo\"}}]},\"finish_reason\":null}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_kimi\",\"function\":{\"arguments\":\" hello\\\"}\"}}]},\"finish_reason\":\"tool_calls\",\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":5,\"cached_tokens\":2}}]}\n" ++
            "data: [DONE]\n",
    );

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = "https://api.moonshot.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    const event1 = stream_instance.next().?;
    defer freeEvent(allocator, event1);
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream_instance.next().?;
    defer freeEvent(allocator, event2);
    try std.testing.expectEqual(types.EventType.toolcall_start, event2.event_type);

    const event3 = stream_instance.next().?;
    defer freeEvent(allocator, event3);
    try std.testing.expectEqual(types.EventType.toolcall_delta, event3.event_type);
    try std.testing.expect(event3.owns_delta);
    try std.testing.expectEqualStrings("{\"command\":\"echo", event3.delta.?);

    const event4 = stream_instance.next().?;
    defer freeEvent(allocator, event4);
    try std.testing.expectEqual(types.EventType.toolcall_delta, event4.event_type);
    try std.testing.expect(event4.owns_delta);
    try std.testing.expectEqualStrings(" hello\"}", event4.delta.?);

    const event5 = stream_instance.next().?;
    defer freeEvent(allocator, event5);
    try std.testing.expectEqual(types.EventType.toolcall_end, event5.event_type);
    try std.testing.expect(event5.tool_call != null);
    try std.testing.expectEqualStrings("call_kimi", event5.tool_call.?.id);
    try std.testing.expectEqualStrings("run_terminal", event5.tool_call.?.name);
    try std.testing.expect(event5.tool_call.?.arguments == .object);
    try std.testing.expectEqualStrings("echo hello", event5.tool_call.?.arguments.object.get("command").?.string);

    const event6 = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, event6.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, event6.message.?.stop_reason);
    try std.testing.expectEqual(@as(u32, 10), event6.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 5), event6.message.?.usage.output);
    try std.testing.expect(event6.message.?.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), event6.message.?.tool_calls.?.len);
    try std.testing.expectEqualStrings("run_terminal", event6.message.?.tool_calls.?[0].name);
    try std.testing.expect(event6.message.?.tool_calls.?[0].arguments == .object);
    try std.testing.expectEqualStrings("echo hello", event6.message.?.tool_calls.?[0].arguments.object.get("command").?.string);
    try std.testing.expect(event5.tool_call.?.id.ptr == event6.message.?.tool_calls.?[0].id.ptr);
    try std.testing.expect(event5.tool_call.?.name.ptr == event6.message.?.tool_calls.?[0].name.ptr);
    try std.testing.expect(
        event5.tool_call.?.arguments.object.get("command").?.string.ptr ==
            event6.message.?.tool_calls.?[0].arguments.object.get("command").?.string.ptr,
    );

    freeAssistantMessageOwned(allocator, event6.message.?);
}

test "sanitizeSurrogates matches openai surrogate filtering" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 'A', 0xED, 0xA0, 0x80, 'B' };
    const sanitized = try sanitizeSurrogates(allocator, &input);
    defer allocator.free(sanitized);
    const openai_sanitized = try openai.sanitizeSurrogates(allocator, &input);
    defer allocator.free(openai_sanitized);
    try std.testing.expectEqualStrings("AB", sanitized);
    try std.testing.expectEqualStrings(openai_sanitized, sanitized);
}

test "stream HTTP status error is terminal sanitized event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"error\":{\"message\":\"kimi denied\",\"authorization\":\"Bearer sk-kimi-secret\",\"request_id\":\"req_kimi_random_123456\"},\"trace\":\"/Users/alice/pi/kimi.zig\"}");
    try body.appendNTimes(allocator, 'x', 900);

    var server = try provider_error.TestStatusServer.init(io, 503, "Service Unavailable", "", body.items);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try KimiProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 503: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "kimi denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "[truncated]") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "sk-kimi-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_kimi_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("kimi-completions", result.api);
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

test "parseSseStreamLines preserves partial Kimi text before malformed terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"id\":\"kimi-runtime\",\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n" ++
            "data: {not-json}\n" ++
            "data: [DONE]\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("kimi-k2", "moonshot"), null);

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
    try std.testing.expectEqualStrings("kimi-runtime", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
}

test "stream returns error_event when API key is empty" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = "https://api.moonshot.ai/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try KimiProvider.stream(allocator, io, model, context, .{ .api_key = "" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "No API key for provider: kimi") != null);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expectEqualStrings("kimi-completions", event.message.?.api);
    try std.testing.expectEqualStrings("kimi", event.message.?.provider);
    try std.testing.expectEqualStrings("kimi-k2.6", event.message.?.model);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    allocator.free(result.error_message.?);
}

test "stream returns error_event when options is null (no API key available)" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = "https://api.moonshot.ai/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    // When options is null and no KIMI_API_KEY env var is set,
    // stream() must return a stream with error_event (not throw).
    var stream = try KimiProvider.stream(allocator, io, model, context, null);
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "No API key for provider: kimi") != null);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expectEqualStrings("kimi-completions", event.message.?.api);
    try std.testing.expectEqualStrings("kimi", event.message.?.provider);
    try std.testing.expectEqualStrings("kimi-k2.6", event.message.?.model);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    allocator.free(result.error_message.?);
}
