const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");
const env_api_keys = @import("../env_api_keys.zig");
const provider_error = @import("../shared/provider_error.zig");
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
                if (response.response_headers) |response_headers| {
                    callback(response.status, response_headers, model);
                } else {
                    var response_headers = std.StringHashMap([]const u8).init(allocator);
                    defer response_headers.deinit();
                    callback(response.status, response_headers, model);
                }
            }
        }

        if (response.status != 200) {
            const response_body = try response.readAllBounded(allocator, provider_error.MAX_PROVIDER_ERROR_BODY_READ_BYTES);
            defer allocator.free(response_body);
            try provider_error.pushHttpStatusError(allocator, &stream_instance, model, response.status, response_body);
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
        if (tools.len > 0) {
            var tools_array = std.json.Array.init(allocator);
            errdefer tools_array.deinit();
            for (tools) |tool| {
                try tools_array.append(try buildToolObject(allocator, tool));
            }
            try payload.put(allocator, try allocator.dupe(u8, "tools"), .{ .array = tools_array });
        }
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
                            .owns_delta = true,
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
                                .owns_delta = true,
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
                            .owns_delta = true,
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
                            .owns_delta = true,
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
                                    .owns_delta = true,
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
            try finalizeOutputFromPartials(allocator, &output, &current_block, &content_blocks, &tool_calls, stream_ptr);
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
            try finalizeOutputFromPartials(allocator, &output, &current_block, &content_blocks, &tool_calls, stream_ptr);
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

fn finalizeOutputFromPartials(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    try finalizeCurrentBlock(allocator, null, current_block, content_blocks, tool_calls, stream_ptr);
    if (output.content.len == 0 and content_blocks.items.len > 0) {
        output.content = try content_blocks.toOwnedSlice(allocator);
    }
    if (output.tool_calls == null and tool_calls.items.len > 0) {
        output.tool_calls = try tool_calls.toOwnedSlice(allocator);
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
                const owned = if (try extractMessageText(allocator, maybe_item_value)) |final_text|
                    final_text
                else
                    try allocator.dupe(u8, text.text.items);
                try content_blocks.append(allocator, .{ .text = .{ .text = owned } });
                stream_ptr.push(.{
                    .event_type = .text_end,
                    .content_index = @intCast(text.event_index),
                    .content = owned,
                });
            },
            .thinking => |*thinking| {
                const owned = if (try extractReasoningSummary(allocator, maybe_item_value)) |final_text|
                    final_text
                else
                    try allocator.dupe(u8, thinking.text.items);
                const signature = if (maybe_item_value) |item_value| blk: {
                    if (item_value == .object) {
                        if (item_value.object.get("encrypted_content")) |encrypted| {
                            if (encrypted == .string) break :blk try allocator.dupe(u8, encrypted.string);
                        }
                    }
                    break :blk null;
                } else if (thinking.signature) |existing|
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
                try content_blocks.append(allocator, .{ .tool_call = .{
                    .id = try allocator.dupe(u8, stored_tool_call.id),
                    .name = try allocator.dupe(u8, stored_tool_call.name),
                    .arguments = try cloneJsonValue(allocator, stored_tool_call.arguments),
                } });
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
    const sanitized = try openai.sanitizeSurrogates(allocator, system_prompt);
    defer allocator.free(sanitized);
    try object.put(allocator, try allocator.dupe(u8, "content"), .{ .string = try allocator.dupe(u8, sanitized) });
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
                const sanitized = try openai.sanitizeSurrogates(allocator, text.text);
                defer allocator.free(sanitized);
                try part.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, sanitized) });
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
            .thinking, .tool_call => {},
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
                if (types.thinkingSignature(thinking)) |signature| {
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
                const sanitized = try openai.sanitizeSurrogates(allocator, text.text);
                defer allocator.free(sanitized);
                try text_object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, sanitized) });
                try text_object.put(allocator, try allocator.dupe(u8, "annotations"), .{ .array = std.json.Array.init(allocator) });
                try content.append(.{ .object = text_object });
                try message_object.put(allocator, try allocator.dupe(u8, "content"), .{ .array = content });
                try input.append(.{ .object = message_object });
            },
            .image => {},
            .tool_call => {},
        }
    }

    const tool_calls_source = if (types.hasInlineToolCalls(assistant))
        try types.collectAssistantToolCalls(allocator, assistant)
    else
        null;
    defer if (tool_calls_source) |calls| allocator.free(calls);

    if (tool_calls_source orelse assistant.tool_calls) |tool_calls| {
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
            .thinking, .tool_call => {},
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
            const sanitized = try openai.sanitizeSurrogates(allocator, text_parts.items);
            defer allocator.free(sanitized);
            try text_object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, sanitized) });
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
            try openai.sanitizeSurrogates(allocator, text_parts.items)
        else if (image_count > 0)
            try allocator.dupe(u8, "(see attached image)")
        else
            try allocator.dupe(u8, "");
        defer allocator.free(output_text);
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

fn extractMessageText(allocator: std.mem.Allocator, maybe_item_value: ?std.json.Value) !?[]const u8 {
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

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    for (content_value.array.items) |part| {
        if (part != .object) continue;
        const part_type = extractStringField(part, "type") orelse continue;
        if (std.mem.eql(u8, part_type, "output_text")) {
            if (extractStringField(part, "text")) |text| try buffer.appendSlice(allocator, text);
        } else if (std.mem.eql(u8, part_type, "refusal")) {
            if (extractStringField(part, "refusal")) |text| try buffer.appendSlice(allocator, text);
        }
    }
    return try buffer.toOwnedSlice(allocator);
}

fn extractReasoningSummary(allocator: std.mem.Allocator, maybe_item_value: ?std.json.Value) !?[]const u8 {
    const item_value = maybe_item_value orelse return null;
    if (item_value != .object) return null;
    const summary_value = item_value.object.get("summary") orelse return null;
    if (summary_value != .array or summary_value.array.items.len == 0) return null;

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    for (summary_value.array.items, 0..) |part, index| {
        if (part != .object) continue;
        const text = extractStringField(part, "text") orelse continue;
        if (buffer.items.len > 0 and index > 0) try buffer.appendSlice(allocator, "\n\n");
        try buffer.appendSlice(allocator, text);
    }
    return try buffer.toOwnedSlice(allocator);
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
            errdefer {
                for (cloned.items) |item| freeJsonValue(allocator, item);
                cloned.deinit();
            }
            for (array.items) |item| {
                try cloned.append(try cloneJsonValue(allocator, item));
            }
            return .{ .array = cloned };
        },
        .object => |object| {
            var cloned = try initObject(allocator);
            errdefer {
                var iter = cloned.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    freeJsonValue(allocator, entry.value_ptr.*);
                }
                cloned.deinit(allocator);
            }
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

    fn callback(callback_status: u16, headers: std.StringHashMap([]const u8), model: types.Model) void {
        called = true;
        status = callback_status;
        std.testing.expectEqualStrings("openai-responses", model.api) catch unreachable;
        std.testing.expectEqualStrings("text/event-stream", headers.get("Content-Type").?) catch unreachable;
        std.testing.expectEqualStrings("req_123", headers.get("x-request-id").?) catch unreachable;
        std.testing.expectEqualStrings("17", headers.get("openai-processing-ms").?) catch unreachable;
    }
};

fn drainStreamAndFreeDoneMessage(
    allocator: std.mem.Allocator,
    stream: *event_stream.AssistantMessageEventStream,
) !void {
    while (stream.next()) |event| {
        if (event.delta != null or event.tool_call != null) {
            freeEventOwned(allocator, event);
        }
        if (event.message) |message| {
            freeAssistantMessageOwned(allocator, message);
        }
    }
}

test "extractMessageText uses caller allocator" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"},{\"type\":\"refusal\",\"refusal\":\" no\"}]}",
        .{},
    );
    defer parsed.deinit();

    const text = (try extractMessageText(allocator, parsed.value)).?;
    defer allocator.free(text);

    try std.testing.expectEqualStrings("Hello no", text);
}

test "extractReasoningSummary uses caller allocator" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"summary\":[{\"text\":\"first\"},{\"text\":\"second\"}]}",
        .{},
    );
    defer parsed.deinit();

    const text = (try extractReasoningSummary(allocator, parsed.value)).?;
    defer allocator.free(text);

    try std.testing.expectEqualStrings("first\n\nsecond", text);
}

test "stream on_response receives actual response headers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const body =
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_headers\"}}\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
        "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}}\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_headers\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}\n" ++
        "data: [DONE]\n";

    var server = try ResponseHeaderServer.init(
        io,
        "x-request-id: req_123\r\nopenai-processing-ms: 17\r\n",
        body,
    );
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = url,
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
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

    var stream = try OpenAIResponsesProvider.stream(allocator, io, model, context, .{
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

    const body = "{\"error\":{\"message\":\"bad gateway\",\"api_key\":\"sk-response-secret\",\"request_id\":\"req_response_random_123456\"},\"trace\":\"/Users/alice/pi/openai_responses.zig\"}";
    var server = try provider_error.TestStatusServer.init(io, 502, "Bad Gateway", "", body);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try OpenAIResponsesProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 502: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "bad gateway") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "sk-response-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_response_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expect(stream.next() == null);
    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("openai-responses", result.api);
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
    try std.testing.expectEqual(@as(usize, 1), event6.message.?.content.len);
    try std.testing.expect(event6.message.?.content[0] == .tool_call);
    try std.testing.expectEqualStrings("call_1|fc_1", event6.message.?.content[0].tool_call.id);
    try std.testing.expectEqualStrings("Berlin", event6.message.?.content[0].tool_call.arguments.object.get("city").?.string);
    try std.testing.expectEqual(types.StopReason.tool_use, event6.message.?.stop_reason);
    try std.testing.expectEqualStrings("resp_tool", event6.message.?.response_id.?);

    freeAssistantMessageOwned(allocator, event6.message.?);
}

test "parseSseStreamLines preserves partial text before malformed response event terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_bad\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n" ++
            "data: {not-json}\n" ++
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
    try std.testing.expectEqualStrings(terminal.error_message.?, terminal.message.?.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("resp_bad", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
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

test "buildRequestPayload omits empty tools array" {
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

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
        .tools = &[_]types.Tool{},
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer freeJsonValue(allocator, payload);

    try std.testing.expect(payload.object.get("tools") == null);
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

test "parseSseStreamLines finalizes partial text before response.failed terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_failed\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n" ++
            "data: {\"type\":\"response.failed\",\"response\":{\"id\":\"resp_failed\",\"error\":{\"message\":\"provider failed\"}}}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
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
    try std.testing.expectEqualStrings("unknown: provider failed", terminal.error_message.?);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("resp_failed", terminal.message.?.response_id.?);
    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
}

test "parseSseStreamLines finalizes partial text before top-level error terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_top_error\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n" ++
            "data: {\"type\":\"error\",\"message\":\"top-level failed\"}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
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
    try std.testing.expectEqualStrings("top-level failed", terminal.error_message.?);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("resp_top_error", terminal.message.?.response_id.?);
    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
}
