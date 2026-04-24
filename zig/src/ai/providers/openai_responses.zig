const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");
const env_api_keys = @import("../env_api_keys.zig");
const openai = @import("openai.zig");

const MessagePartKind = enum {
    output_text,
    refusal,
};

const CurrentBlock = union(enum) {
    text: struct {
        event_index: usize,
        text: std.ArrayList(u8),
        part_kind: MessagePartKind,
    },
    thinking: struct {
        event_index: usize,
        text: std.ArrayList(u8),
        signature: ?[]const u8,
    },
    tool_call: struct {
        event_index: usize,
        id: ?[]const u8,
        name: ?[]const u8,
        partial_json: std.ArrayList(u8),
    },
};

const ContinuationAnchor = struct {
    response_id: []const u8,
    message_start_index: usize,
};

const ResponsesCompat = struct {
    send_session_id_header: bool = true,
    supports_long_cache_retention: bool = true,
};

pub const OpenAIResponsesProvider = struct {
    pub const api = "openai-responses";

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

        var env_api_key: ?[]u8 = null;
        defer if (env_api_key) |key| allocator.free(key);

        const provided_api_key = if (options) |stream_options| stream_options.api_key else null;
        const api_key = blk: {
            if (provided_api_key) |key| break :blk key;
            env_api_key = try env_api_keys.getEnvApiKey(allocator, model.provider);
            break :blk env_api_key;
        };

        if (api_key == null or api_key.?.len == 0) {
            const error_message = try std.fmt.allocPrint(allocator, "No API key for provider: {s}", .{model.provider});
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

        const url = try std.fmt.allocPrint(allocator, "{s}/responses", .{model.base_url});
        defer allocator.free(url);

        var resolved_options = if (options) |stream_options| stream_options else types.StreamOptions{};
        resolved_options.api_key = api_key.?;

        var headers = try buildRequestHeaders(allocator, model, resolved_options);
        defer deinitOwnedHeaders(allocator, &headers);

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

        try parseSseStreamLines(allocator, &stream_instance, &response, model, options);
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
    const anchor = findContinuationAnchor(context, model);
    const compat = getCompat(model);
    const start_index = if (anchor) |value| value.message_start_index else 0;
    const include_system_prompt = anchor == null;

    var input = std.json.Array.init(allocator);
    errdefer input.deinit();

    if (include_system_prompt) {
        if (context.system_prompt) |system_prompt| {
            try input.append(try buildSystemInputItem(allocator, model, system_prompt));
        }
    }

    for (context.messages[start_index..], start_index..) |message, message_index| {
        try appendInputItemsForMessage(allocator, &input, model, message, message_index);
    }

    var payload = try initObject(allocator);
    errdefer payload.deinit(allocator);

    try payload.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, model.id) });
    try payload.put(allocator, try allocator.dupe(u8, "input"), .{ .array = input });
    try payload.put(allocator, try allocator.dupe(u8, "stream"), .{ .bool = true });
    try payload.put(allocator, try allocator.dupe(u8, "store"), .{ .bool = false });

    if (anchor) |value| {
        try payload.put(allocator, try allocator.dupe(u8, "previous_response_id"), .{ .string = try allocator.dupe(u8, value.response_id) });
    }

    if (options) |stream_options| {
        if (stream_options.max_tokens) |max_tokens| {
            try payload.put(allocator, try allocator.dupe(u8, "max_output_tokens"), .{ .integer = @intCast(max_tokens) });
        }
        if (stream_options.temperature) |temperature| {
            try payload.put(allocator, try allocator.dupe(u8, "temperature"), .{ .float = temperature });
        }
        if (stream_options.metadata) |metadata| {
            try payload.put(allocator, try allocator.dupe(u8, "metadata"), try cloneJsonValue(allocator, metadata));
        }
        if (stream_options.session_id) |session_id| {
            if (stream_options.cache_retention != .none) {
                try payload.put(allocator, try allocator.dupe(u8, "prompt_cache_key"), .{ .string = try allocator.dupe(u8, session_id) });
            }
            if (stream_options.cache_retention == .long and compat.supports_long_cache_retention) {
                try payload.put(allocator, try allocator.dupe(u8, "prompt_cache_retention"), .{ .string = try allocator.dupe(u8, "24h") });
            }
        }
        if (model.reasoning) {
            if (stream_options.responses_reasoning_effort) |reasoning_effort| {
                var reasoning = try initObject(allocator);
                errdefer reasoning.deinit(allocator);
                try reasoning.put(allocator, try allocator.dupe(u8, "effort"), .{ .string = try allocator.dupe(u8, thinkingLevelString(reasoning_effort)) });
                try reasoning.put(allocator, try allocator.dupe(u8, "summary"), .{ .string = try allocator.dupe(u8, "auto") });
                try payload.put(allocator, try allocator.dupe(u8, "reasoning"), .{ .object = reasoning });

                var include = std.json.Array.init(allocator);
                errdefer include.deinit();
                try include.append(.{ .string = try allocator.dupe(u8, "reasoning.encrypted_content") });
                try payload.put(allocator, try allocator.dupe(u8, "include"), .{ .array = include });
            }
        }
    }

    if (context.tools) |tools| {
        var tools_array = std.json.Array.init(allocator);
        errdefer tools_array.deinit();
        for (tools) |tool| {
            try tools_array.append(try buildToolObject(allocator, tool));
        }
        try payload.put(allocator, try allocator.dupe(u8, "tools"), .{ .array = tools_array });
    }

    return .{ .object = payload };
}

fn buildRequestHeaders(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: types.StreamOptions,
) !std.StringHashMap([]const u8) {
    const api_key = options.api_key orelse return error.MissingApiKey;
    const compat = getCompat(model);

    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitOwnedHeaders(allocator, &headers);

    try putOwnedHeader(allocator, &headers, "Content-Type", "application/json");
    try putOwnedHeader(allocator, &headers, "Accept", "text/event-stream");
    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(authorization);
    try putOwnedHeader(allocator, &headers, "Authorization", authorization);
    try mergeHeaders(allocator, &headers, model.headers);
    try mergeHeaders(allocator, &headers, options.headers);

    if (options.session_id) |session_id| {
        if (options.cache_retention != .none) {
            try putOwnedHeader(allocator, &headers, "x-client-request-id", session_id);
            if (compat.send_session_id_header) {
                try putOwnedHeader(allocator, &headers, "session_id", session_id);
            }
        }
    }

    return headers;
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
        if (value != .object) continue;

        const event_type_value = value.object.get("type") orelse continue;
        if (event_type_value != .string) continue;
        const event_type = event_type_value.string;

        if (std.mem.eql(u8, event_type, "response.created")) {
            if (value.object.get("response")) |response_value| {
                updateResponseIdFromResponseObject(allocator, &output, response_value) catch {};
            }
            continue;
        }

        if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            const item_value = value.object.get("item") orelse continue;
            try handleOutputItemAdded(allocator, item_value, &current_block, &content_blocks, stream_ptr);
            continue;
        }

        if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.added")) {
            continue;
        }

        if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta")) {
            const delta_value = value.object.get("delta") orelse continue;
            if (delta_value != .string) continue;
            if (current_block) |*block| {
                switch (block.*) {
                    .thinking => |*thinking| {
                        try thinking.text.appendSlice(allocator, delta_value.string);
                        stream_ptr.push(.{
                            .event_type = .thinking_delta,
                            .content_index = @intCast(thinking.event_index),
                            .delta = try allocator.dupe(u8, delta_value.string),
                        });
                    },
                    else => {},
                }
            }
            continue;
        }

        if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.done")) {
            if (current_block) |*block| {
                switch (block.*) {
                    .thinking => |*thinking| {
                        if (thinking.text.items.len > 0) {
                            try thinking.text.appendSlice(allocator, "\n\n");
                            stream_ptr.push(.{
                                .event_type = .thinking_delta,
                                .content_index = @intCast(thinking.event_index),
                                .delta = try allocator.dupe(u8, "\n\n"),
                            });
                        }
                    },
                    else => {},
                }
            }
            continue;
        }

        if (std.mem.eql(u8, event_type, "response.content_part.added")) {
            const part_value = value.object.get("part") orelse continue;
            updateCurrentMessagePart(part_value, &current_block);
            continue;
        }

        if (std.mem.eql(u8, event_type, "response.output_text.delta") or std.mem.eql(u8, event_type, "response.refusal.delta")) {
            const delta_value = value.object.get("delta") orelse continue;
            if (delta_value != .string) continue;
            if (current_block) |*block| {
                switch (block.*) {
                    .text => |*text| {
                        try text.text.appendSlice(allocator, delta_value.string);
                        stream_ptr.push(.{
                            .event_type = .text_delta,
                            .content_index = @intCast(text.event_index),
                            .delta = try allocator.dupe(u8, delta_value.string),
                        });
                    },
                    else => {},
                }
            }
            continue;
        }

        if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            const delta_value = value.object.get("delta") orelse continue;
            if (delta_value != .string) continue;
            if (current_block) |*block| {
                switch (block.*) {
                    .tool_call => |*tool_call| {
                        try tool_call.partial_json.appendSlice(allocator, delta_value.string);
                        stream_ptr.push(.{
                            .event_type = .toolcall_delta,
                            .content_index = @intCast(tool_call.event_index),
                            .delta = try allocator.dupe(u8, delta_value.string),
                        });
                    },
                    else => {},
                }
            }
            continue;
        }

        if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
            const arguments_value = value.object.get("arguments") orelse continue;
            if (arguments_value != .string) continue;
            if (current_block) |*block| {
                switch (block.*) {
                    .tool_call => |*tool_call| {
                        const previous = tool_call.partial_json.items;
                        if (std.mem.startsWith(u8, arguments_value.string, previous)) {
                            const delta = arguments_value.string[previous.len..];
                            if (delta.len > 0) {
                                tool_call.partial_json.clearRetainingCapacity();
                                try tool_call.partial_json.appendSlice(allocator, arguments_value.string);
                                stream_ptr.push(.{
                                    .event_type = .toolcall_delta,
                                    .content_index = @intCast(tool_call.event_index),
                                    .delta = try allocator.dupe(u8, delta),
                                });
                            }
                        } else {
                            tool_call.partial_json.clearRetainingCapacity();
                            try tool_call.partial_json.appendSlice(allocator, arguments_value.string);
                        }
                    },
                    else => {},
                }
            }
            continue;
        }

        if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            const item_value = value.object.get("item") orelse continue;
            try finalizeCurrentBlock(allocator, item_value, &current_block, &content_blocks, &tool_calls, stream_ptr);
            continue;
        }

        if (std.mem.eql(u8, event_type, "response.completed") or std.mem.eql(u8, event_type, "response.incomplete")) {
            if (value.object.get("response")) |response_value| {
                try updateCompletedResponse(allocator, &output, response_value, model);
            }
            break;
        }

        if (std.mem.eql(u8, event_type, "response.failed")) {
            const error_message = try extractFailureMessage(allocator, value.object.get("response"));
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

        if (std.mem.eql(u8, event_type, "error")) {
            const error_message = try extractTopLevelErrorMessage(allocator, value);
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
    }

    try finalizeCurrentBlock(allocator, null, &current_block, &content_blocks, &tool_calls, stream_ptr);
    output.content = try content_blocks.toOwnedSlice(allocator);
    output.tool_calls = if (tool_calls.items.len > 0) try tool_calls.toOwnedSlice(allocator) else null;

    if (output.tool_calls != null and output.stop_reason == .stop) {
        output.stop_reason = .tool_use;
    }
    if (output.usage.total_tokens == 0) {
        output.usage.total_tokens = output.usage.input + output.usage.output + output.usage.cache_read + output.usage.cache_write;
    }
    calculateCost(model, &output.usage);

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

fn handleOutputItemAdded(
    allocator: std.mem.Allocator,
    item_value: std.json.Value,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    if (item_value != .object) return;
    const item_type_value = item_value.object.get("type") orelse return;
    if (item_type_value != .string) return;

    if (std.mem.eql(u8, item_type_value.string, "reasoning")) {
        if (current_block.* != null) return;
        current_block.* = .{ .thinking = .{
            .event_index = content_blocks.items.len,
            .text = std.ArrayList(u8).empty,
            .signature = null,
        } };
        stream_ptr.push(.{ .event_type = .thinking_start, .content_index = @intCast(content_blocks.items.len) });
        return;
    }

    if (std.mem.eql(u8, item_type_value.string, "message")) {
        if (current_block.* != null) return;
        current_block.* = .{ .text = .{
            .event_index = content_blocks.items.len,
            .text = std.ArrayList(u8).empty,
            .part_kind = .output_text,
        } };
        stream_ptr.push(.{ .event_type = .text_start, .content_index = @intCast(content_blocks.items.len) });
        return;
    }

    if (std.mem.eql(u8, item_type_value.string, "function_call")) {
        if (current_block.* != null) return;
        current_block.* = .{ .tool_call = .{
            .event_index = content_blocks.items.len,
            .id = try extractCombinedToolCallId(allocator, item_value),
            .name = try extractOwnedStringField(allocator, item_value, "name"),
            .partial_json = std.ArrayList(u8).empty,
        } };

        if (current_block.*) |*block| {
            switch (block.*) {
                .tool_call => |*tool_call| {
                    if (item_value.object.get("arguments")) |arguments_value| {
                        if (arguments_value == .string and arguments_value.string.len > 0) {
                            try tool_call.partial_json.appendSlice(allocator, arguments_value.string);
                        }
                    }
                },
                else => {},
            }
        }

        stream_ptr.push(.{ .event_type = .toolcall_start, .content_index = @intCast(content_blocks.items.len) });
    }
}

fn updateCurrentMessagePart(item_value: std.json.Value, current_block: *?CurrentBlock) void {
    if (item_value != .object) return;
    const part_type_value = item_value.object.get("type") orelse return;
    if (part_type_value != .string) return;

    if (current_block.*) |*block| {
        switch (block.*) {
            .text => |*text| {
                if (std.mem.eql(u8, part_type_value.string, "refusal")) {
                    text.part_kind = .refusal;
                } else {
                    text.part_kind = .output_text;
                }
            },
            else => {},
        }
    }
}

fn finalizeCurrentBlock(
    allocator: std.mem.Allocator,
    maybe_item_value: ?std.json.Value,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    if (current_block.*) |*block| {
        switch (block.*) {
            .text => |*text| {
                const final_text = extractMessageText(maybe_item_value) orelse text.text.items;
                const owned = try allocator.dupe(u8, final_text);
                try content_blocks.append(allocator, .{ .text = .{ .text = owned } });
                stream_ptr.push(.{
                    .event_type = .text_end,
                    .content_index = @intCast(text.event_index),
                    .content = owned,
                });
            },
            .thinking => |*thinking| {
                const final_text = extractReasoningSummary(maybe_item_value) orelse thinking.text.items;
                const owned = try allocator.dupe(u8, final_text);
                const signature = if (maybe_item_value) |item_value|
                    try std.json.Stringify.valueAlloc(allocator, item_value, .{})
                else if (thinking.signature) |existing|
                    try allocator.dupe(u8, existing)
                else
                    null;
                try content_blocks.append(allocator, .{ .thinking = .{
                    .thinking = owned,
                    .signature = signature,
                    .redacted = false,
                } });
                stream_ptr.push(.{
                    .event_type = .thinking_end,
                    .content_index = @intCast(thinking.event_index),
                    .content = owned,
                });
            },
            .tool_call => |*tool_call| {
                const item_id_owned = if (tool_call.id == null and maybe_item_value != null)
                    try extractCombinedToolCallId(allocator, maybe_item_value.?)
                else
                    null;
                defer if (item_id_owned) |value| allocator.free(value);
                const final_id = item_id_owned orelse tool_call.id orelse "";

                const item_name_owned = if (tool_call.name == null and maybe_item_value != null)
                    try extractOwnedStringField(allocator, maybe_item_value.?, "name")
                else
                    null;
                defer if (item_name_owned) |value| allocator.free(value);
                const final_name = item_name_owned orelse tool_call.name orelse "";

                const arguments_source = if (maybe_item_value) |item_value|
                    extractStringField(item_value, "arguments") orelse tool_call.partial_json.items
                else
                    tool_call.partial_json.items;
                const arguments = try parseStreamingJsonToValue(allocator, arguments_source);
                const stored_tool_call = types.ToolCall{
                    .id = try allocator.dupe(u8, final_id),
                    .name = try allocator.dupe(u8, final_name),
                    .arguments = arguments,
                };
                try tool_calls.append(allocator, stored_tool_call);
                try content_blocks.append(allocator, .{ .text = .{ .text = "" } });
                stream_ptr.push(.{
                    .event_type = .toolcall_end,
                    .content_index = @intCast(tool_call.event_index),
                    .tool_call = .{
                        .id = try allocator.dupe(u8, stored_tool_call.id),
                        .name = try allocator.dupe(u8, stored_tool_call.name),
                        .arguments = try cloneJsonValue(allocator, stored_tool_call.arguments),
                    },
                });
            },
        }

        deinitCurrentBlock(allocator, block);
        current_block.* = null;
    }
}

fn findContinuationAnchor(context: types.Context, model: types.Model) ?ContinuationAnchor {
    if (context.messages.len < 2) return null;

    var index = context.messages.len;
    while (index > 0) {
        index -= 1;
        const message = context.messages[index];
        switch (message) {
            .assistant => |assistant| {
                if (assistant.response_id == null) continue;
                if (!std.mem.eql(u8, assistant.provider, model.provider)) continue;
                if (!std.mem.eql(u8, assistant.api, model.api)) continue;
                if (index + 1 >= context.messages.len) continue;
                if (!continuationMessagesAreCompatible(context.messages[index + 1 ..])) continue;
                return .{
                    .response_id = assistant.response_id.?,
                    .message_start_index = index + 1,
                };
            },
            else => {},
        }
    }

    return null;
}

fn continuationMessagesAreCompatible(messages: []const types.Message) bool {
    if (messages.len == 0) return false;
    for (messages) |message| {
        if (message == .assistant) return false;
    }
    return true;
}

fn buildSystemInputItem(allocator: std.mem.Allocator, model: types.Model, system_prompt: []const u8) !std.json.Value {
    var object = try initObject(allocator);
    errdefer object.deinit(allocator);
    const role = if (model.reasoning) "developer" else "system";
    try object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, role) });
    try object.put(allocator, try allocator.dupe(u8, "content"), .{ .string = try allocator.dupe(u8, openai.sanitizeSurrogates(system_prompt)) });
    return .{ .object = object };
}

fn appendInputItemsForMessage(
    allocator: std.mem.Allocator,
    input: *std.json.Array,
    model: types.Model,
    message: types.Message,
    message_index: usize,
) !void {
    switch (message) {
        .user => |user| try input.append(try buildUserInputItem(allocator, model, user)),
        .assistant => |assistant| try appendAssistantInputItems(allocator, input, assistant, message_index),
        .tool_result => |tool_result| try input.append(try buildToolResultInputItem(allocator, model, tool_result)),
    }
}

fn buildUserInputItem(allocator: std.mem.Allocator, model: types.Model, user: types.UserMessage) !std.json.Value {
    var content = std.json.Array.init(allocator);
    errdefer content.deinit();

    const supports_images = modelSupportsImages(model);

    for (user.content) |block| {
        switch (block) {
            .text => |text| {
                var part = try initObject(allocator);
                errdefer part.deinit(allocator);
                try part.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "input_text") });
                try part.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, openai.sanitizeSurrogates(text.text)) });
                try content.append(.{ .object = part });
            },
            .image => |image| {
                if (!supports_images) continue;
                var part = try initObject(allocator);
                errdefer part.deinit(allocator);
                try part.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "input_image") });
                try part.put(allocator, try allocator.dupe(u8, "detail"), .{ .string = try allocator.dupe(u8, "auto") });
                const image_url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ image.mime_type, image.data });
                defer allocator.free(image_url);
                try part.put(allocator, try allocator.dupe(u8, "image_url"), .{ .string = try allocator.dupe(u8, image_url) });
                try content.append(.{ .object = part });
            },
            .thinking => {},
        }
    }

    var object = try initObject(allocator);
    errdefer object.deinit(allocator);
    try object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "user") });
    try object.put(allocator, try allocator.dupe(u8, "content"), .{ .array = content });
    return .{ .object = object };
}

fn appendAssistantInputItems(
    allocator: std.mem.Allocator,
    input: *std.json.Array,
    assistant: types.AssistantMessage,
    message_index: usize,
) !void {
    for (assistant.content) |block| {
        switch (block) {
            .thinking => |thinking| {
                if (thinking.signature) |signature| {
                    var parsed = std.json.parseFromSlice(std.json.Value, allocator, signature, .{}) catch continue;
                    defer parsed.deinit();
                    try input.append(try cloneJsonValue(allocator, parsed.value));
                }
            },
            .text => |text| {
                var message_object = try initObject(allocator);
                errdefer message_object.deinit(allocator);
                try message_object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "message") });
                try message_object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "assistant") });
                try message_object.put(allocator, try allocator.dupe(u8, "status"), .{ .string = try allocator.dupe(u8, "completed") });
                const message_id = try std.fmt.allocPrint(allocator, "msg_{d}", .{message_index});
                defer allocator.free(message_id);
                try message_object.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, message_id) });

                var content = std.json.Array.init(allocator);
                errdefer content.deinit();
                var text_object = try initObject(allocator);
                errdefer text_object.deinit(allocator);
                try text_object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "output_text") });
                try text_object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, openai.sanitizeSurrogates(text.text)) });
                try text_object.put(allocator, try allocator.dupe(u8, "annotations"), .{ .array = std.json.Array.init(allocator) });
                try content.append(.{ .object = text_object });
                try message_object.put(allocator, try allocator.dupe(u8, "content"), .{ .array = content });
                try input.append(.{ .object = message_object });
            },
            .image => {},
        }
    }

    if (assistant.tool_calls) |tool_calls| {
        for (tool_calls) |tool_call| {
            const split = splitToolCallId(tool_call.id);
            var tool_call_object = try initObject(allocator);
            errdefer tool_call_object.deinit(allocator);
            try tool_call_object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "function_call") });
            try tool_call_object.put(allocator, try allocator.dupe(u8, "call_id"), .{ .string = try allocator.dupe(u8, split.call_id) });
            if (split.item_id) |item_id| {
                try tool_call_object.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, item_id) });
            }
            try tool_call_object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool_call.name) });
            const arguments_json = try std.json.Stringify.valueAlloc(allocator, tool_call.arguments, .{});
            defer allocator.free(arguments_json);
            try tool_call_object.put(allocator, try allocator.dupe(u8, "arguments"), .{ .string = try allocator.dupe(u8, arguments_json) });
            try input.append(.{ .object = tool_call_object });
        }
    }
}

fn buildToolResultInputItem(
    allocator: std.mem.Allocator,
    model: types.Model,
    tool_result: types.ToolResultMessage,
) !std.json.Value {
    const supports_images = modelSupportsImages(model);

    var text_parts = std.ArrayList(u8).empty;
    defer text_parts.deinit(allocator);
    var image_count: usize = 0;
    for (tool_result.content) |block| {
        switch (block) {
            .text => |text| {
                if (text_parts.items.len > 0) try text_parts.appendSlice(allocator, "\n");
                try text_parts.appendSlice(allocator, text.text);
            },
            .image => {
                image_count += 1;
            },
            .thinking => {},
        }
    }

    var object = try initObject(allocator);
    errdefer object.deinit(allocator);
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "function_call_output") });
    try object.put(allocator, try allocator.dupe(u8, "call_id"), .{ .string = try allocator.dupe(u8, splitToolCallId(tool_result.tool_call_id).call_id) });

    if (supports_images and image_count > 0) {
        var output_parts = std.json.Array.init(allocator);
        errdefer output_parts.deinit();
        if (text_parts.items.len > 0) {
            var text_object = try initObject(allocator);
            errdefer text_object.deinit(allocator);
            try text_object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "input_text") });
            try text_object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, openai.sanitizeSurrogates(text_parts.items)) });
            try output_parts.append(.{ .object = text_object });
        }
        for (tool_result.content) |block| {
            switch (block) {
                .image => |image| {
                    var image_object = try initObject(allocator);
                    errdefer image_object.deinit(allocator);
                    try image_object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "input_image") });
                    try image_object.put(allocator, try allocator.dupe(u8, "detail"), .{ .string = try allocator.dupe(u8, "auto") });
                    const image_url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ image.mime_type, image.data });
                    defer allocator.free(image_url);
                    try image_object.put(allocator, try allocator.dupe(u8, "image_url"), .{ .string = try allocator.dupe(u8, image_url) });
                    try output_parts.append(.{ .object = image_object });
                },
                else => {},
            }
        }
        try object.put(allocator, try allocator.dupe(u8, "output"), .{ .array = output_parts });
    } else {
        const output_text = if (text_parts.items.len > 0)
            openai.sanitizeSurrogates(text_parts.items)
        else if (image_count > 0)
            "(see attached image)"
        else
            "";
        try object.put(allocator, try allocator.dupe(u8, "output"), .{ .string = try allocator.dupe(u8, output_text) });
    }

    return .{ .object = object };
}

fn buildToolObject(allocator: std.mem.Allocator, tool: types.Tool) !std.json.Value {
    var object = try initObject(allocator);
    errdefer object.deinit(allocator);
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "function") });
    try object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool.name) });
    try object.put(allocator, try allocator.dupe(u8, "description"), .{ .string = try allocator.dupe(u8, tool.description) });
    try object.put(allocator, try allocator.dupe(u8, "parameters"), try cloneJsonValue(allocator, tool.parameters));
    try object.put(allocator, try allocator.dupe(u8, "strict"), .{ .bool = false });
    return .{ .object = object };
}

fn modelSupportsImages(model: types.Model) bool {
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) return true;
    }
    return false;
}

fn splitToolCallId(id: []const u8) struct { call_id: []const u8, item_id: ?[]const u8 } {
    if (std.mem.indexOfScalar(u8, id, '|')) |separator_index| {
        const item_id = id[separator_index + 1 ..];
        return .{
            .call_id = id[0..separator_index],
            .item_id = if (item_id.len > 0) item_id else null,
        };
    }
    return .{ .call_id = id, .item_id = null };
}

fn extractCombinedToolCallId(allocator: std.mem.Allocator, item_value: std.json.Value) !?[]const u8 {
    if (item_value != .object) return null;
    const call_id = extractStringField(item_value, "call_id") orelse return null;
    const item_id = extractStringField(item_value, "id");
    if (item_id) |value| {
        return try std.fmt.allocPrint(allocator, "{s}|{s}", .{ call_id, value });
    }
    return try allocator.dupe(u8, call_id);
}

fn extractOwnedStringField(allocator: std.mem.Allocator, value: std.json.Value, key: []const u8) !?[]const u8 {
    const string = extractStringField(value, key) orelse return null;
    return try allocator.dupe(u8, string);
}

fn extractStringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field_value = value.object.get(key) orelse return null;
    if (field_value != .string) return null;
    return field_value.string;
}

fn extractMessageText(maybe_item_value: ?std.json.Value) ?[]const u8 {
    const item_value = maybe_item_value orelse return null;
    if (item_value != .object) return null;
    const content_value = item_value.object.get("content") orelse return null;
    if (content_value != .array) return null;

    var total_len: usize = 0;
    for (content_value.array.items) |part| {
        if (part != .object) continue;
        const part_type = extractStringField(part, "type") orelse continue;
        if (std.mem.eql(u8, part_type, "output_text")) {
            if (extractStringField(part, "text")) |text| total_len += text.len;
        } else if (std.mem.eql(u8, part_type, "refusal")) {
            if (extractStringField(part, "refusal")) |text| total_len += text.len;
        }
    }
    if (total_len == 0) return null;

    const allocator = std.heap.page_allocator;
    var buffer = std.ArrayList(u8).empty;
    for (content_value.array.items) |part| {
        if (part != .object) continue;
        const part_type = extractStringField(part, "type") orelse continue;
        if (std.mem.eql(u8, part_type, "output_text")) {
            if (extractStringField(part, "text")) |text| buffer.appendSlice(allocator, text) catch {};
        } else if (std.mem.eql(u8, part_type, "refusal")) {
            if (extractStringField(part, "refusal")) |text| buffer.appendSlice(allocator, text) catch {};
        }
    }
    return buffer.toOwnedSlice(allocator) catch null;
}

fn extractReasoningSummary(maybe_item_value: ?std.json.Value) ?[]const u8 {
    const item_value = maybe_item_value orelse return null;
    if (item_value != .object) return null;
    const summary_value = item_value.object.get("summary") orelse return null;
    if (summary_value != .array or summary_value.array.items.len == 0) return null;

    const allocator = std.heap.page_allocator;
    var buffer = std.ArrayList(u8).empty;
    for (summary_value.array.items, 0..) |part, index| {
        if (part != .object) continue;
        const text = extractStringField(part, "text") orelse continue;
        if (buffer.items.len > 0 and index > 0) buffer.appendSlice(allocator, "\n\n") catch {};
        buffer.appendSlice(allocator, text) catch {};
    }
    return buffer.toOwnedSlice(allocator) catch null;
}

fn updateResponseIdFromResponseObject(allocator: std.mem.Allocator, output: *types.AssistantMessage, response_value: std.json.Value) !void {
    if (response_value != .object) return;
    const response_id = extractStringField(response_value, "id") orelse return;
    if (output.response_id == null) {
        output.response_id = try allocator.dupe(u8, response_id);
    }
}

fn updateCompletedResponse(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    response_value: std.json.Value,
    model: types.Model,
) !void {
    if (response_value != .object) return;
    try updateResponseIdFromResponseObject(allocator, output, response_value);

    if (response_value.object.get("usage")) |usage_value| {
        output.usage = parseUsage(usage_value);
        calculateCost(model, &output.usage);
    }

    if (extractStringField(response_value, "status")) |status| {
        output.stop_reason = mapStopReason(status);
    }
}

fn parseUsage(value: std.json.Value) types.Usage {
    var usage = types.Usage.init();
    if (value != .object) return usage;

    const input_tokens = jsonIntegerToU32(value.object.get("input_tokens"));
    const output_tokens = jsonIntegerToU32(value.object.get("output_tokens"));
    const total_tokens = jsonIntegerToU32(value.object.get("total_tokens"));

    var cached_tokens: u32 = 0;
    if (value.object.get("input_tokens_details")) |details| {
        if (details == .object) {
            cached_tokens = jsonIntegerToU32(details.object.get("cached_tokens"));
        }
    }

    usage.input = if (input_tokens >= cached_tokens) input_tokens - cached_tokens else 0;
    usage.output = output_tokens;
    usage.cache_read = cached_tokens;
    usage.cache_write = 0;
    usage.total_tokens = if (total_tokens > 0)
        total_tokens
    else
        usage.input + usage.output + usage.cache_read + usage.cache_write;
    return usage;
}

fn extractFailureMessage(allocator: std.mem.Allocator, response_value: ?std.json.Value) ![]const u8 {
    const response = response_value orelse return try allocator.dupe(u8, "Unknown error (no error details in response)");
    if (response != .object) return try allocator.dupe(u8, "Unknown error (no error details in response)");

    if (response.object.get("error")) |error_value| {
        if (error_value == .object) {
            const code = extractStringField(error_value, "code") orelse "unknown";
            const message = extractStringField(error_value, "message") orelse "no message";
            return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ code, message });
        }
    }

    if (response.object.get("incomplete_details")) |details_value| {
        if (details_value == .object) {
            if (extractStringField(details_value, "reason")) |reason| {
                return try std.fmt.allocPrint(allocator, "incomplete: {s}", .{reason});
            }
        }
    }

    return try allocator.dupe(u8, "Unknown error (no error details in response)");
}

fn extractTopLevelErrorMessage(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    if (extractStringField(value, "code")) |code| {
        const message = extractStringField(value, "message") orelse "Unknown error";
        return try std.fmt.allocPrint(allocator, "Error Code {s}: {s}", .{ code, message });
    }
    if (extractStringField(value, "message")) |message| {
        return try allocator.dupe(u8, message);
    }
    return try allocator.dupe(u8, "Unknown error");
}

fn parseStreamingJsonToValue(allocator: std.mem.Allocator, input: []const u8) !std.json.Value {
    if (input.len == 0) return .{ .object = try initObject(allocator) };
    const parsed = json_parse.parseStreamingJson(allocator, input) catch {
        return .{ .object = try initObject(allocator) };
    };
    defer parsed.deinit();
    return try cloneJsonValue(allocator, parsed.value);
}

fn mapStopReason(status: []const u8) types.StopReason {
    if (std.mem.eql(u8, status, "completed")) return .stop;
    if (std.mem.eql(u8, status, "incomplete")) return .length;
    if (std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "cancelled")) return .error_reason;
    if (std.mem.eql(u8, status, "queued") or std.mem.eql(u8, status, "in_progress")) return .stop;
    return .error_reason;
}

fn jsonIntegerToU32(maybe_value: ?std.json.Value) u32 {
    const value = maybe_value orelse return 0;
    return switch (value) {
        .integer => |integer| @intCast(@max(@as(i64, 0), integer)),
        else => 0,
    };
}

fn calculateCost(model: types.Model, usage: *types.Usage) void {
    usage.cost.input = (@as(f64, @floatFromInt(usage.input)) / 1_000_000.0) * model.cost.input;
    usage.cost.output = (@as(f64, @floatFromInt(usage.output)) / 1_000_000.0) * model.cost.output;
    usage.cost.cache_read = (@as(f64, @floatFromInt(usage.cache_read)) / 1_000_000.0) * model.cost.cache_read;
    usage.cost.cache_write = (@as(f64, @floatFromInt(usage.cache_write)) / 1_000_000.0) * model.cost.cache_write;
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
}

fn parseSseLine(line: []const u8) ?[]const u8 {
    const prefix = "data: ";
    if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    return null;
}

fn deinitCurrentBlock(allocator: std.mem.Allocator, block: *CurrentBlock) void {
    switch (block.*) {
        .text => |*text| text.text.deinit(allocator),
        .thinking => |*thinking| {
            thinking.text.deinit(allocator);
            if (thinking.signature) |signature| allocator.free(signature);
        },
        .tool_call => |*tool_call| {
            if (tool_call.id) |id| allocator.free(id);
            if (tool_call.name) |name| allocator.free(name);
            tool_call.partial_json.deinit(allocator);
        },
    }
}

fn getCompat(model: types.Model) ResponsesCompat {
    return .{
        .send_session_id_header = compatBoolField(model.compat, "sendSessionIdHeader") orelse true,
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

fn thinkingLevelString(level: types.ThinkingLevel) []const u8 {
    return switch (level) {
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn putOwnedHeader(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    name: []const u8,
    value: []const u8,
) !void {
    try headers.put(try allocator.dupe(u8, name), try allocator.dupe(u8, value));
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

fn deinitOwnedHeaders(allocator: std.mem.Allocator, headers: *std.StringHashMap([]const u8)) void {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    headers.deinit();
}

fn isAbortRequested(options: ?types.StreamOptions) bool {
    if (options) |stream_options| {
        if (stream_options.signal) |signal| return signal.load(.seq_cst);
    }
    return false;
}

fn initObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
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
            var cloned = std.json.Array.init(allocator);
            errdefer cloned.deinit();
            for (array.items) |item| {
                try cloned.append(try cloneJsonValue(allocator, item));
            }
            return .{ .array = cloned };
        },
        .object => |object| {
            var cloned = try initObject(allocator);
            errdefer cloned.deinit(allocator);
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try cloned.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            return .{ .object = cloned };
        },
    }
}

fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |string| allocator.free(string),
        .number_string => |number_string| allocator.free(number_string),
        .array => |array| {
            for (array.items) |item| freeJsonValue(allocator, item);
            var mutable = array;
            mutable.deinit();
        },
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var mutable = object;
            mutable.deinit(allocator);
        },
        else => {},
    }
}

fn freeToolCallOwned(allocator: std.mem.Allocator, tool_call: types.ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    freeJsonValue(allocator, tool_call.arguments);
}

fn freeAssistantMessageOwned(allocator: std.mem.Allocator, message: types.AssistantMessage) void {
    for (message.content) |block| {
        switch (block) {
            .text => |text| allocator.free(text.text),
            .thinking => |thinking| {
                allocator.free(thinking.thinking);
                if (thinking.signature) |signature| allocator.free(signature);
            },
            .image => |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            },
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

fn freeEventOwned(allocator: std.mem.Allocator, event: types.AssistantMessageEvent) void {
    if (event.delta) |delta| allocator.free(delta);
    if (event.tool_call) |tool_call| freeToolCallOwned(allocator, tool_call);
}

test "buildRequestPayload uses previous_response_id for continuation" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    const assistant_content = [_]types.ContentBlock{.{ .text = .{ .text = "First answer" } }};
    const user_content = [_]types.ContentBlock{.{ .text = .{ .text = "Follow up" } }};
    const context = types.Context{
        .system_prompt = "You are a helpful assistant.",
        .messages = &[_]types.Message{
            .{ .assistant = .{
                .content = &assistant_content,
                .api = "openai-responses",
                .provider = "openai",
                .model = "gpt-5-mini",
                .response_id = "resp_prev",
                .usage = types.Usage.init(),
                .stop_reason = .stop,
                .timestamp = 1,
            } },
            .{ .user = .{
                .content = &user_content,
                .timestamp = 2,
            } },
        },
    };

    const payload = try buildRequestPayload(allocator, model, context, .{ .session_id = "sess-1" });
    defer freeJsonValue(allocator, payload);

    try std.testing.expect(payload == .object);
    try std.testing.expectEqualStrings("resp_prev", payload.object.get("previous_response_id").?.string);
    try std.testing.expectEqualStrings("sess-1", payload.object.get("prompt_cache_key").?.string);

    const input = payload.object.get("input").?;
    try std.testing.expect(input == .array);
    try std.testing.expectEqual(@as(usize, 1), input.array.items.len);

    const user_item = input.array.items[0];
    try std.testing.expect(user_item == .object);
    try std.testing.expectEqualStrings("user", user_item.object.get("role").?.string);
    try std.testing.expect(user_item.object.get("content").? == .array);
}

test "parseSseStreamLines streams text and captures response_id" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":3,\"total_tokens\":8,\"input_tokens_details\":{\"cached_tokens\":1}}}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ignored\"}\n" ++
            "data: [DONE]\n",
    );

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    const event1 = stream.next().?;
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_start, event2.event_type);

    const event3 = stream.next().?;
    defer freeEventOwned(allocator, event3);
    try std.testing.expectEqual(types.EventType.text_delta, event3.event_type);
    try std.testing.expectEqualStrings("Hello", event3.delta.?);

    const event4 = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, event4.event_type);
    try std.testing.expectEqualStrings("Hello", event4.content.?);

    const event5 = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, event5.event_type);
    try std.testing.expect(event5.message != null);
    try std.testing.expectEqualStrings("resp_1", event5.message.?.response_id.?);
    try std.testing.expectEqual(@as(u32, 4), event5.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 3), event5.message.?.usage.output);
    try std.testing.expectEqual(@as(u32, 8), event5.message.?.usage.total_tokens);
    try std.testing.expectEqualStrings("Hello", event5.message.?.content[0].text.text);

    freeAssistantMessageOwned(allocator, event5.message.?);
}

test "parseSseStreamLines streams tool calls and finalizes arguments" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_tool\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"get_weather\",\"arguments\":\"\"}}\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"city\\\":\\\"Ber\"}\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"lin\\\"}\"}\n" ++
            "data: {\"type\":\"response.function_call_arguments.done\",\"arguments\":\"{\\\"city\\\":\\\"Berlin\\\"}\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Berlin\\\"}\"}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_tool\",\"status\":\"completed\",\"usage\":{\"input_tokens\":2,\"output_tokens\":1,\"total_tokens\":3}}}\n" ++
            "data: [DONE]\n",
    );

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    const event1 = stream.next().?;
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, event2.event_type);

    const event3 = stream.next().?;
    defer freeEventOwned(allocator, event3);
    try std.testing.expectEqual(types.EventType.toolcall_delta, event3.event_type);
    try std.testing.expectEqualStrings("{\"city\":\"Ber", event3.delta.?);

    const event4 = stream.next().?;
    defer freeEventOwned(allocator, event4);
    try std.testing.expectEqual(types.EventType.toolcall_delta, event4.event_type);
    try std.testing.expectEqualStrings("lin\"}", event4.delta.?);

    const event5 = stream.next().?;
    defer freeEventOwned(allocator, event5);
    try std.testing.expectEqual(types.EventType.toolcall_end, event5.event_type);
    try std.testing.expect(event5.tool_call != null);
    try std.testing.expectEqualStrings("call_1|fc_1", event5.tool_call.?.id);
    try std.testing.expectEqualStrings("get_weather", event5.tool_call.?.name);

    const event6 = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, event6.event_type);
    try std.testing.expect(event6.message != null);
    try std.testing.expect(event6.message.?.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), event6.message.?.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1|fc_1", event6.message.?.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("Berlin", event6.message.?.tool_calls.?[0].arguments.object.get("city").?.string);
    try std.testing.expectEqual(types.StopReason.tool_use, event6.message.?.stop_reason);
    try std.testing.expectEqualStrings("resp_tool", event6.message.?.response_id.?);

    freeAssistantMessageOwned(allocator, event6.message.?);
}

test "buildRequestPayload omits long cache retention when compat disables it" {
    const allocator = std.testing.allocator;

    var compat = try initObject(allocator);
    try compat.put(allocator, try allocator.dupe(u8, "supportsLongCacheRetention"), .{ .bool = false });
    const compat_value = std.json.Value{ .object = compat };
    defer freeJsonValue(allocator, compat_value);

    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
        .compat = compat_value,
    };

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &[_]types.Message{} }, .{
        .session_id = "sess-1",
        .cache_retention = .long,
    });
    defer freeJsonValue(allocator, payload);

    try std.testing.expect(payload.object.get("prompt_cache_key") != null);
    try std.testing.expect(payload.object.get("prompt_cache_retention") == null);
}

test "buildRequestHeaders omits session_id when compat disables it" {
    const allocator = std.testing.allocator;

    var compat = try initObject(allocator);
    try compat.put(allocator, try allocator.dupe(u8, "sendSessionIdHeader"), .{ .bool = false });
    const compat_value = std.json.Value{ .object = compat };
    defer freeJsonValue(allocator, compat_value);

    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
        .compat = compat_value,
    };

    var headers = try buildRequestHeaders(allocator, model, .{
        .api_key = "test-key",
        .session_id = "sess-1",
        .cache_retention = .short,
    });
    defer deinitOwnedHeaders(allocator, &headers);

    try std.testing.expectEqualStrings("Bearer test-key", headers.get("Authorization").?);
    try std.testing.expectEqualStrings("sess-1", headers.get("x-client-request-id").?);
    try std.testing.expect(headers.get("session_id") == null);
}
