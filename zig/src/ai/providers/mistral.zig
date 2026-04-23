const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");
const env_api_keys = @import("../env_api_keys.zig");

const MISTRAL_TOOL_CALL_ID_LENGTH: usize = 9;
const IMAGE_OMITTED_TEXT = "(image omitted: model does not support images)";
const TOOL_IMAGE_OMITTED_TEXT = "(tool image omitted: model does not support images)";

const ToolCallIdMapping = struct {
    original: []const u8,
    normalized: []const u8,
};

const CurrentBlock = union(enum) {
    text: struct {
        event_index: usize,
        text: std.ArrayList(u8),
    },
    thinking: struct {
        event_index: usize,
        text: std.ArrayList(u8),
    },
};

const StreamingToolCall = struct {
    event_index: usize,
    index: usize,
    id: std.ArrayList(u8),
    name: std.ArrayList(u8),
    partial_args: std.ArrayList(u8),

    fn deinit(self: *StreamingToolCall, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.name.deinit(allocator);
        self.partial_args.deinit(allocator);
    }
};

const ToolCallIdNormalizer = struct {
    allocator: std.mem.Allocator,
    mappings: std.ArrayList(ToolCallIdMapping),

    fn init(allocator: std.mem.Allocator) ToolCallIdNormalizer {
        return .{
            .allocator = allocator,
            .mappings = std.ArrayList(ToolCallIdMapping).empty,
        };
    }

    fn deinit(self: *ToolCallIdNormalizer) void {
        for (self.mappings.items) |entry| {
            self.allocator.free(entry.normalized);
        }
        self.mappings.deinit(self.allocator);
    }

    fn normalize(self: *ToolCallIdNormalizer, original: []const u8) ![]const u8 {
        for (self.mappings.items) |entry| {
            if (std.mem.eql(u8, entry.original, original)) return entry.normalized;
        }

        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const candidate = try deriveMistralToolCallId(self.allocator, original, attempt);
            var collision = false;
            for (self.mappings.items) |entry| {
                if (std.mem.eql(u8, entry.normalized, candidate) and !std.mem.eql(u8, entry.original, original)) {
                    collision = true;
                    break;
                }
            }
            if (!collision) {
                try self.mappings.append(self.allocator, .{
                    .original = original,
                    .normalized = candidate,
                });
                return candidate;
            }
            self.allocator.free(candidate);
        }
    }
};

pub const MistralProvider = struct {
    pub const api = "mistral-conversations";

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
            const error_message = try allocator.dupe(u8, "No API key for provider: mistral");
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

        const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{model.base_url});
        defer allocator.free(url);

        var headers = std.StringHashMap([]const u8).empty;
        defer headers.deinit(allocator);
        try headers.put(allocator, "Content-Type", "application/json");
        try headers.put(allocator, "Accept", "text/event-stream");
        try headers.put(allocator, "Authorization", try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key.?}));
        try mergeHeaders(allocator, &headers, model.headers);
        if (options) |stream_options| {
            try mergeHeaders(allocator, &headers, stream_options.headers);
            if (stream_options.session_id) |session_id| {
                if (!headerExists(&headers, "x-affinity")) {
                    try headers.put(allocator, "x-affinity", try allocator.dupe(u8, session_id));
                }
            }
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
    var payload = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer payload.deinit(allocator);

    try payload.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, model.id) });
    try payload.put(allocator, try allocator.dupe(u8, "stream"), .{ .bool = true });

    var normalizer = ToolCallIdNormalizer.init(allocator);
    defer normalizer.deinit();

    const messages = try buildMessagesValue(allocator, model, context, &normalizer);
    try payload.put(allocator, try allocator.dupe(u8, "messages"), messages);

    if (context.tools) |tools| {
        if (tools.len > 0) {
            try payload.put(allocator, try allocator.dupe(u8, "tools"), try buildToolsValue(allocator, tools));
        }
    }

    if (options) |stream_options| {
        if (stream_options.temperature) |temperature| {
            try payload.put(allocator, try allocator.dupe(u8, "temperature"), .{ .float = temperature });
        }
        if (stream_options.max_tokens) |max_tokens| {
            try payload.put(allocator, try allocator.dupe(u8, "max_tokens"), .{ .integer = @intCast(max_tokens) });
        }
        if (stream_options.metadata) |metadata| {
            try payload.put(allocator, try allocator.dupe(u8, "metadata"), try cloneJsonValue(allocator, metadata));
        }
        if (stream_options.mistral_reasoning_effort) |effort| {
            try payload.put(allocator, try allocator.dupe(u8, "reasoning_effort"), .{ .string = try allocator.dupe(u8, effort) });
        }
        if (stream_options.mistral_prompt_mode) |mode| {
            try payload.put(allocator, try allocator.dupe(u8, "prompt_mode"), .{ .string = try allocator.dupe(u8, mode) });
        }
    }

    return .{ .object = payload };
}

pub fn mapStopReason(reason: []const u8) types.StopReason {
    if (std.mem.eql(u8, reason, "stop")) return .stop;
    if (std.mem.eql(u8, reason, "length") or std.mem.eql(u8, reason, "model_length")) return .length;
    if (std.mem.eql(u8, reason, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, reason, "error")) return .error_reason;
    return .stop;
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

    var content_slots = std.ArrayList(?types.ContentBlock).empty;
    defer content_slots.deinit(allocator);

    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);

    var active_tool_calls = std.ArrayList(StreamingToolCall).empty;
    defer {
        for (active_tool_calls.items) |*tool_call| tool_call.deinit(allocator);
        active_tool_calls.deinit(allocator);
    }

    var current_block: ?CurrentBlock = null;
    defer if (current_block) |*block| deinitCurrentBlock(allocator, block);

    var next_content_index: usize = 0;

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

        const data = parseSseLine(std.mem.trim(u8, line, " \t\r")) orelse continue;
        if (std.mem.eql(u8, data, "[DONE]")) break;

        var parsed = try json_parse.parseStreamingJson(allocator, data);
        defer parsed.deinit();
        const value = parsed.value;
        if (value != .object) continue;

        if (value.object.get("id")) |id_value| {
            if (id_value == .string and output.response_id == null) {
                output.response_id = try allocator.dupe(u8, id_value.string);
            }
        }

        if (value.object.get("usage")) |usage_value| {
            updateUsage(&output.usage, usage_value);
        }

        const choices_value = value.object.get("choices") orelse continue;
        if (choices_value != .array or choices_value.array.items.len == 0) continue;

        const choice = choices_value.array.items[0];
        if (choice != .object) continue;

        if (choice.object.get("finish_reason")) |finish_reason| {
            if (finish_reason == .string) {
                output.stop_reason = mapStopReason(finish_reason.string);
            }
        }

        const delta_value = choice.object.get("delta") orelse continue;
        if (delta_value != .object) continue;

        if (delta_value.object.get("content")) |content_value| {
            switch (content_value) {
                .string => |text_delta| {
                    if (text_delta.len > 0) {
                        try appendTextDelta(allocator, &current_block, &content_slots, stream_ptr, &next_content_index, text_delta, false);
                    }
                },
                .array => |content_array| {
                    for (content_array.items) |item| {
                        if (item != .object) continue;
                        const chunk_type = item.object.get("type") orelse continue;
                        if (chunk_type != .string) continue;

                        if (std.mem.eql(u8, chunk_type.string, "text")) {
                            if (item.object.get("text")) |text_value| {
                                if (text_value == .string and text_value.string.len > 0) {
                                    try appendTextDelta(allocator, &current_block, &content_slots, stream_ptr, &next_content_index, text_value.string, false);
                                }
                            }
                            continue;
                        }

                        if (std.mem.eql(u8, chunk_type.string, "thinking")) {
                            if (try extractThinkingText(allocator, item)) |thinking_delta| {
                                defer allocator.free(thinking_delta);
                                try appendTextDelta(allocator, &current_block, &content_slots, stream_ptr, &next_content_index, thinking_delta, true);
                            }
                        }
                    }
                },
                else => {},
            }
        }

        if (delta_value.object.get("tool_calls")) |tool_calls_value| {
            if (tool_calls_value == .array) {
                try finishCurrentBlock(allocator, &current_block, &content_slots, stream_ptr);
                for (tool_calls_value.array.items) |tool_call_value| {
                    if (tool_call_value != .object) continue;
                    const call_index = getJsonUsize(tool_call_value.object.get("index"));
                    const raw_call_id = if (tool_call_value.object.get("id")) |id_value|
                        if (id_value == .string and !std.mem.eql(u8, id_value.string, "null")) id_value.string else null
                    else
                        null;
                    const normalized_call_id = if (raw_call_id) |call_id|
                        try deriveMistralToolCallId(allocator, call_id, 0)
                    else blk: {
                        const generated_id = try std.fmt.allocPrint(allocator, "toolcall:{d}", .{call_index});
                        defer allocator.free(generated_id);
                        break :blk try deriveMistralToolCallId(allocator, generated_id, 0);
                    };
                    defer allocator.free(normalized_call_id);

                    const tool_call = if (findStreamingToolCall(&active_tool_calls, normalized_call_id, call_index)) |existing|
                        existing
                    else blk: {
                        try active_tool_calls.append(allocator, .{
                            .event_index = next_content_index,
                            .index = call_index,
                            .id = std.ArrayList(u8).empty,
                            .name = std.ArrayList(u8).empty,
                            .partial_args = std.ArrayList(u8).empty,
                        });
                        try active_tool_calls.items[active_tool_calls.items.len - 1].id.appendSlice(allocator, normalized_call_id);
                        stream_ptr.push(.{
                            .event_type = .toolcall_start,
                            .content_index = @intCast(next_content_index),
                        });
                        next_content_index += 1;
                        break :blk &active_tool_calls.items[active_tool_calls.items.len - 1];
                    };

                    if (tool_call_value.object.get("function")) |function_value| {
                        if (function_value == .object) {
                            if (function_value.object.get("name")) |name_value| {
                                if (name_value == .string and name_value.string.len > 0) {
                                    tool_call.name.clearRetainingCapacity();
                                    try tool_call.name.appendSlice(allocator, name_value.string);
                                }
                            }
                            if (function_value.object.get("arguments")) |arguments_value| {
                                const arguments_delta = try stringifyArgumentsDelta(allocator, arguments_value);
                                defer allocator.free(arguments_delta);
                                try tool_call.partial_args.appendSlice(allocator, arguments_delta);
                                stream_ptr.push(.{
                                    .event_type = .toolcall_delta,
                                    .content_index = @intCast(tool_call.event_index),
                                    .delta = try allocator.dupe(u8, arguments_delta),
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    try finishCurrentBlock(allocator, &current_block, &content_slots, stream_ptr);

    for (active_tool_calls.items) |*tool_call| {
        const arguments = try parseStreamingJsonToValue(allocator, tool_call.partial_args.items);
        const final_tool_call = types.ToolCall{
            .id = try allocator.dupe(u8, tool_call.id.items),
            .name = try allocator.dupe(u8, std.mem.trim(u8, tool_call.name.items, " ")),
            .arguments = arguments,
        };
        try ensureContentSlotCapacity(allocator, &content_slots, tool_call.event_index);
        content_slots.items[tool_call.event_index] = null;
        try tool_calls.append(allocator, final_tool_call);
        stream_ptr.push(.{
            .event_type = .toolcall_end,
            .content_index = @intCast(tool_call.event_index),
            .tool_call = final_tool_call,
        });
    }

    calculateCost(model, &output.usage);
    output.content = try materializeContent(allocator, content_slots.items);
    output.tool_calls = if (tool_calls.items.len > 0) try cloneToolCallsSlice(allocator, tool_calls.items) else null;

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

fn buildMessagesValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    normalizer: *ToolCallIdNormalizer,
) !std.json.Value {
    var messages = std.json.Array.init(allocator);
    errdefer messages.deinit();

    if (context.system_prompt) |system_prompt| {
        try messages.append(try buildRoleMessage(allocator, "system", .{ .string = try allocator.dupe(u8, system_prompt) }));
    }

    for (context.messages) |message| {
        switch (message) {
            .user => |user| try messages.append(try buildUserMessageValue(allocator, model, user)),
            .assistant => |assistant| {
                if (try buildAssistantMessageValue(allocator, assistant, normalizer)) |assistant_value| {
                    try messages.append(assistant_value);
                }
            },
            .tool_result => |tool_result| try messages.append(try buildToolResultMessageValue(allocator, model, tool_result, normalizer)),
        }
    }

    return .{ .array = messages };
}

fn buildUserMessageValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    user: types.UserMessage,
) !std.json.Value {
    const supports_images = modelSupportsImages(model);
    var content = std.json.Array.init(allocator);
    errdefer content.deinit();

    var inserted_image_placeholder = false;
    for (user.content) |block| {
        switch (block) {
            .text => |text| {
                try content.append(try buildTextChunkValue(allocator, text.text));
                inserted_image_placeholder = false;
            },
            .image => |image| {
                if (supports_images) {
                    try content.append(try buildImageChunkValue(allocator, image.mime_type, image.data));
                } else if (!inserted_image_placeholder) {
                    try content.append(try buildTextChunkValue(allocator, IMAGE_OMITTED_TEXT));
                    inserted_image_placeholder = true;
                }
            },
            .thinking => {},
        }
    }

    if (content.items.len == 0) {
        try content.append(try buildTextChunkValue(allocator, ""));
    }
    return try buildRoleMessage(allocator, "user", .{ .array = content });
}

fn buildAssistantMessageValue(
    allocator: std.mem.Allocator,
    assistant: types.AssistantMessage,
    normalizer: *ToolCallIdNormalizer,
) !?std.json.Value {
    var content = std.json.Array.init(allocator);
    errdefer content.deinit();

    for (assistant.content) |block| {
        switch (block) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) continue;
                try content.append(try buildTextChunkValue(allocator, text.text));
            },
            .thinking => |thinking| {
                if (std.mem.trim(u8, thinking.thinking, " \t\r\n").len == 0) continue;
                try content.append(try buildThinkingChunkValue(allocator, thinking.thinking));
            },
            .image => {},
        }
    }

    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    try object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "assistant") });

    if (content.items.len > 0) {
        try object.put(allocator, try allocator.dupe(u8, "content"), .{ .array = content });
    } else {
        content.deinit();
    }

    if (assistant.tool_calls) |tool_calls| {
        if (tool_calls.len > 0) {
            var tool_calls_array = std.json.Array.init(allocator);
            errdefer tool_calls_array.deinit();
            for (tool_calls, 0..) |tool_call, index| {
                const normalized_id = try normalizer.normalize(tool_call.id);
                try tool_calls_array.append(try buildToolCallValue(allocator, normalized_id, tool_call.name, tool_call.arguments, index));
            }
            try object.put(allocator, try allocator.dupe(u8, "tool_calls"), .{ .array = tool_calls_array });
        }
    }

    if (object.count() == 1) {
        return null;
    }
    return .{ .object = object };
}

fn buildToolResultMessageValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    tool_result: types.ToolResultMessage,
    normalizer: *ToolCallIdNormalizer,
) !std.json.Value {
    const supports_images = modelSupportsImages(model);
    const normalized_id = try normalizer.normalize(tool_result.tool_call_id);

    var content = std.json.Array.init(allocator);
    errdefer content.deinit();

    const tool_text = try buildToolResultText(allocator, tool_result.content, supports_images, tool_result.is_error);
    defer allocator.free(tool_text);
    try content.append(try buildTextChunkValue(allocator, tool_text));

    if (supports_images) {
        for (tool_result.content) |block| {
            switch (block) {
                .image => |image| try content.append(try buildImageChunkValue(allocator, image.mime_type, image.data)),
                else => {},
            }
        }
    }

    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    try object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "tool") });
    try object.put(allocator, try allocator.dupe(u8, "tool_call_id"), .{ .string = try allocator.dupe(u8, normalized_id) });
    try object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool_result.tool_name) });
    try object.put(allocator, try allocator.dupe(u8, "content"), .{ .array = content });
    return .{ .object = object };
}

fn buildToolsValue(allocator: std.mem.Allocator, tools: []const types.Tool) !std.json.Value {
    var tools_array = std.json.Array.init(allocator);
    errdefer tools_array.deinit();

    for (tools) |tool| {
        var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        var function_object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "function") });
        try function_object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool.name) });
        try function_object.put(allocator, try allocator.dupe(u8, "description"), .{ .string = try allocator.dupe(u8, tool.description) });
        try function_object.put(allocator, try allocator.dupe(u8, "parameters"), try cloneJsonValue(allocator, tool.parameters));
        try function_object.put(allocator, try allocator.dupe(u8, "strict"), .{ .bool = false });
        try object.put(allocator, try allocator.dupe(u8, "function"), .{ .object = function_object });
        try tools_array.append(.{ .object = object });
    }

    return .{ .array = tools_array };
}

fn buildRoleMessage(allocator: std.mem.Allocator, role: []const u8, content: std.json.Value) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, role) });
    try object.put(allocator, try allocator.dupe(u8, "content"), content);
    return .{ .object = object };
}

fn buildTextChunkValue(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "text") });
    try object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text) });
    return .{ .object = object };
}

fn buildImageChunkValue(allocator: std.mem.Allocator, mime_type: []const u8, data: []const u8) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "image_url") });
    try object.put(allocator, try allocator.dupe(u8, "image_url"), .{ .string = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ mime_type, data }) });
    return .{ .object = object };
}

fn buildThinkingChunkValue(allocator: std.mem.Allocator, thinking: []const u8) !std.json.Value {
    var text_part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try text_part.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "text") });
    try text_part.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, thinking) });

    var thinking_array = std.json.Array.init(allocator);
    try thinking_array.append(.{ .object = text_part });

    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "thinking") });
    try object.put(allocator, try allocator.dupe(u8, "thinking"), .{ .array = thinking_array });
    return .{ .object = object };
}

fn buildToolCallValue(
    allocator: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    arguments: std.json.Value,
    index: usize,
) !std.json.Value {
    var function_object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try function_object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, name) });
    try function_object.put(allocator, try allocator.dupe(u8, "arguments"), try cloneJsonValue(allocator, arguments));

    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, id) });
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "function") });
    try object.put(allocator, try allocator.dupe(u8, "function"), .{ .object = function_object });
    try object.put(allocator, try allocator.dupe(u8, "index"), .{ .integer = @intCast(index) });
    return .{ .object = object };
}

fn buildToolResultText(
    allocator: std.mem.Allocator,
    content: []const types.ContentBlock,
    supports_images: bool,
    is_error: bool,
) ![]const u8 {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);

    var has_text = false;
    var has_images = false;
    for (content) |block| {
        switch (block) {
            .text => |text_block| {
                const trimmed = std.mem.trim(u8, text_block.text, " \t\r\n");
                if (trimmed.len == 0) continue;
                if (has_text) try text.append(allocator, '\n');
                try text.appendSlice(allocator, text_block.text);
                has_text = true;
            },
            .image => has_images = true,
            .thinking => |thinking| {
                const trimmed = std.mem.trim(u8, thinking.thinking, " \t\r\n");
                if (trimmed.len == 0) continue;
                if (has_text) try text.append(allocator, '\n');
                try text.appendSlice(allocator, thinking.thinking);
                has_text = true;
            },
        }
    }

    if (has_text) {
        var final = std.ArrayList(u8).empty;
        defer final.deinit(allocator);
        if (is_error) try final.appendSlice(allocator, "[tool error] ");
        try final.appendSlice(allocator, text.items);
        if (has_images and !supports_images) {
            try final.appendSlice(allocator, "\n");
            try final.appendSlice(allocator, TOOL_IMAGE_OMITTED_TEXT);
        }
        return final.toOwnedSlice(allocator);
    }

    if (has_images) {
        if (supports_images) {
            return allocator.dupe(u8, if (is_error) "[tool error] (see attached image)" else "(see attached image)");
        }
        return allocator.dupe(u8, if (is_error) "[tool error] (image omitted: model does not support images)" else TOOL_IMAGE_OMITTED_TEXT);
    }

    return allocator.dupe(u8, if (is_error) "[tool error] (no tool output)" else "(no tool output)");
}

fn appendTextDelta(
    allocator: std.mem.Allocator,
    current_block: *?CurrentBlock,
    content_slots: *std.ArrayList(?types.ContentBlock),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    next_content_index: *usize,
    delta: []const u8,
    is_thinking: bool,
) !void {
    if (current_block.* == null or !matchesCurrentBlock(current_block.*.?, is_thinking)) {
        try finishCurrentBlock(allocator, current_block, content_slots, stream_ptr);
        current_block.* = if (is_thinking)
            .{ .thinking = .{ .event_index = next_content_index.*, .text = std.ArrayList(u8).empty } }
        else
            .{ .text = .{ .event_index = next_content_index.*, .text = std.ArrayList(u8).empty } };
        stream_ptr.push(.{
            .event_type = if (is_thinking) .thinking_start else .text_start,
            .content_index = @intCast(next_content_index.*),
        });
        next_content_index.* += 1;
    }

    if (current_block.*) |*block| {
        switch (block.*) {
            .text => |*text_block| {
                try text_block.text.appendSlice(allocator, delta);
                stream_ptr.push(.{
                    .event_type = .text_delta,
                    .content_index = @intCast(text_block.event_index),
                    .delta = try allocator.dupe(u8, delta),
                });
            },
            .thinking => |*thinking_block| {
                try thinking_block.text.appendSlice(allocator, delta);
                stream_ptr.push(.{
                    .event_type = .thinking_delta,
                    .content_index = @intCast(thinking_block.event_index),
                    .delta = try allocator.dupe(u8, delta),
                });
            },
        }
    }
}

fn finishCurrentBlock(
    allocator: std.mem.Allocator,
    current_block: *?CurrentBlock,
    content_slots: *std.ArrayList(?types.ContentBlock),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    if (current_block.*) |*block| {
        switch (block.*) {
            .text => |*text_block| {
                const owned = try allocator.dupe(u8, text_block.text.items);
                try ensureContentSlotCapacity(allocator, content_slots, text_block.event_index);
                content_slots.items[text_block.event_index] = types.ContentBlock{ .text = .{ .text = owned } };
                stream_ptr.push(.{
                    .event_type = .text_end,
                    .content_index = @intCast(text_block.event_index),
                    .content = owned,
                });
            },
            .thinking => |*thinking_block| {
                const owned = try allocator.dupe(u8, thinking_block.text.items);
                try ensureContentSlotCapacity(allocator, content_slots, thinking_block.event_index);
                content_slots.items[thinking_block.event_index] = types.ContentBlock{ .thinking = .{
                    .thinking = owned,
                    .signature = null,
                    .redacted = false,
                } };
                stream_ptr.push(.{
                    .event_type = .thinking_end,
                    .content_index = @intCast(thinking_block.event_index),
                    .content = owned,
                });
            },
        }
        deinitCurrentBlock(allocator, block);
        current_block.* = null;
    }
}

fn matchesCurrentBlock(block: CurrentBlock, is_thinking: bool) bool {
    return switch (block) {
        .text => !is_thinking,
        .thinking => is_thinking,
    };
}

fn deinitCurrentBlock(allocator: std.mem.Allocator, block: *CurrentBlock) void {
    switch (block.*) {
        .text => |*text_block| text_block.text.deinit(allocator),
        .thinking => |*thinking_block| thinking_block.text.deinit(allocator),
    }
}

fn findStreamingToolCall(
    tool_calls: *std.ArrayList(StreamingToolCall),
    id: []const u8,
    index: usize,
) ?*StreamingToolCall {
    for (tool_calls.items) |*tool_call| {
        if (tool_call.index == index and std.mem.eql(u8, tool_call.id.items, id)) return tool_call;
    }
    return null;
}

fn stringifyArgumentsDelta(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |string| allocator.dupe(u8, string),
        else => std.json.Stringify.valueAlloc(allocator, value, .{}),
    };
}

fn extractThinkingText(allocator: std.mem.Allocator, item: std.json.Value) !?[]const u8 {
    const thinking_value = item.object.get("thinking") orelse return null;
    if (thinking_value != .array) return null;

    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);

    for (thinking_value.array.items) |entry| {
        if (entry != .object) continue;
        if (entry.object.get("text")) |text_value| {
            if (text_value == .string) {
                try text.appendSlice(allocator, text_value.string);
            }
        }
    }

    if (text.items.len == 0) return null;
    return try allocator.dupe(u8, text.items);
}

fn parseStreamingJsonToValue(allocator: std.mem.Allocator, input: []const u8) !std.json.Value {
    if (std.mem.trim(u8, input, " \t\r\n").len == 0) {
        return emptyJsonObject(allocator);
    }

    var parsed = json_parse.parseStreamingJson(allocator, input) catch {
        return emptyJsonObject(allocator);
    };
    defer parsed.deinit();
    return cloneJsonValue(allocator, parsed.value);
}

fn deriveMistralToolCallId(allocator: std.mem.Allocator, id: []const u8, attempt: usize) ![]const u8 {
    var normalized = std.ArrayList(u8).empty;
    defer normalized.deinit(allocator);
    for (id) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            try normalized.append(allocator, char);
        }
    }

    if (attempt == 0 and normalized.items.len == MISTRAL_TOOL_CALL_ID_LENGTH) {
        return allocator.dupe(u8, normalized.items);
    }

    const seed = if (attempt == 0)
        try allocator.dupe(u8, if (normalized.items.len > 0) normalized.items else id)
    else
        try std.fmt.allocPrint(allocator, "{s}:{d}", .{ if (normalized.items.len > 0) normalized.items else id, attempt });
    defer allocator.free(seed);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(seed, &digest, .{});
    var hex: [64]u8 = undefined;
    for (digest, 0..) |byte, index| {
        hex[index * 2] = hexDigitLower(byte >> 4);
        hex[index * 2 + 1] = hexDigitLower(byte & 0x0f);
    }
    return allocator.dupe(u8, hex[0..MISTRAL_TOOL_CALL_ID_LENGTH]);
}

fn hexDigitLower(nibble: u8) u8 {
    return "0123456789abcdef"[nibble & 0x0f];
}

fn ensureContentSlotCapacity(
    allocator: std.mem.Allocator,
    content_slots: *std.ArrayList(?types.ContentBlock),
    index: usize,
) !void {
    while (content_slots.items.len <= index) {
        try content_slots.append(allocator, null);
    }
}

fn materializeContent(
    allocator: std.mem.Allocator,
    content_slots: []const ?types.ContentBlock,
) ![]const types.ContentBlock {
    const blocks = try allocator.alloc(types.ContentBlock, content_slots.len);
    for (content_slots, 0..) |maybe_block, index| {
        blocks[index] = if (maybe_block) |block| try cloneContentBlock(allocator, block) else .{ .text = .{ .text = "" } };
    }
    return blocks;
}

fn cloneContentBlock(allocator: std.mem.Allocator, block: types.ContentBlock) !types.ContentBlock {
    return switch (block) {
        .text => |text| .{ .text = .{ .text = try allocator.dupe(u8, text.text) } },
        .image => |image| .{ .image = .{
            .data = try allocator.dupe(u8, image.data),
            .mime_type = try allocator.dupe(u8, image.mime_type),
        } },
        .thinking => |thinking| .{ .thinking = .{
            .thinking = try allocator.dupe(u8, thinking.thinking),
            .signature = if (thinking.signature) |signature| try allocator.dupe(u8, signature) else null,
            .redacted = thinking.redacted,
        } },
    };
}

fn cloneToolCallsSlice(allocator: std.mem.Allocator, tool_calls: []const types.ToolCall) ![]const types.ToolCall {
    const owned = try allocator.alloc(types.ToolCall, tool_calls.len);
    for (tool_calls, 0..) |tool_call, index| {
        owned[index] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try cloneJsonValue(allocator, tool_call.arguments),
        };
    }
    return owned;
}

fn updateUsage(usage: *types.Usage, usage_value: std.json.Value) void {
    if (usage_value != .object) return;
    const pt = getJsonU32(usage_value.object.get("prompt_tokens"));
    const ct = getJsonU32(usage_value.object.get("completion_tokens"));
    const tt = getJsonU32(usage_value.object.get("total_tokens"));

    usage.input = pt;
    usage.output = ct;
    usage.cache_read = 0;
    usage.cache_write = 0;
    usage.total_tokens = if (tt > 0) tt else pt + ct;
}

fn calculateCost(model: types.Model, usage: *types.Usage) void {
    usage.cost.input = (@as(f64, @floatFromInt(usage.input)) / 1_000_000.0) * model.cost.input;
    usage.cost.output = (@as(f64, @floatFromInt(usage.output)) / 1_000_000.0) * model.cost.output;
    usage.cost.cache_read = (@as(f64, @floatFromInt(usage.cache_read)) / 1_000_000.0) * model.cost.cache_read;
    usage.cost.cache_write = (@as(f64, @floatFromInt(usage.cache_write)) / 1_000_000.0) * model.cost.cache_write;
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
}

fn modelSupportsImages(model: types.Model) bool {
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) return true;
    }
    return false;
}

fn getJsonU32(value: ?std.json.Value) u32 {
    if (value) |json_value| {
        if (json_value == .integer and json_value.integer >= 0) {
            return @intCast(json_value.integer);
        }
    }
    return 0;
}

fn getJsonUsize(value: ?std.json.Value) usize {
    if (value) |json_value| {
        if (json_value == .integer and json_value.integer >= 0) {
            return @intCast(json_value.integer);
        }
    }
    return 0;
}

fn parseSseLine(line: []const u8) ?[]const u8 {
    const prefix = "data: ";
    if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    return null;
}

fn mergeHeaders(
    allocator: std.mem.Allocator,
    target: *std.StringHashMap([]const u8),
    source: ?std.StringHashMap([]const u8),
) !void {
    if (source) |headers| {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            try target.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.*));
        }
    }
}

fn headerExists(headers: *const std.StringHashMap([]const u8), key: []const u8) bool {
    return headers.contains(key);
}

fn isAbortRequested(options: ?types.StreamOptions) bool {
    if (options) |stream_options| {
        if (stream_options.signal) |signal| {
            return signal.load(.seq_cst);
        }
    }
    return false;
}

fn emptyJsonObject(allocator: std.mem.Allocator) !std.json.Value {
    return .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) };
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
            var iterator = obj.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var owned = obj;
            owned.deinit(allocator);
        },
        else => {},
    }
}

test "buildRequestPayload includes tools and normalized tool ids" {
    const allocator = std.testing.allocator;

    var tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_schema.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });
    try tool_schema.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) });
    const tool_schema_value = std.json.Value{ .object = tool_schema };
    defer freeJsonValue(allocator, tool_schema_value);

    var tool_args = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_args.put(allocator, try allocator.dupe(u8, "city"), .{ .string = try allocator.dupe(u8, "Berlin") });
    const tool_args_value = std.json.Value{ .object = tool_args };
    defer freeJsonValue(allocator, tool_args_value);

    const context = types.Context{
        .system_prompt = "Use tools if needed.",
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{
                    .{ .text = .{ .text = "Inspect this image" } },
                    .{ .image = .{ .data = "aGVsbG8=", .mime_type = "image/png" } },
                },
                .timestamp = 1,
            } },
            .{ .assistant = .{
                .content = &[_]types.ContentBlock{
                    .{ .text = .{ .text = "Calling tool" } },
                    .{ .thinking = .{ .thinking = "Need weather data", .signature = null, .redacted = false } },
                },
                .tool_calls = &[_]types.ToolCall{.{
                    .id = "call_with_very_long_non_mistral_id",
                    .name = "get_weather",
                    .arguments = tool_args_value,
                }},
                .api = "mistral-conversations",
                .provider = "mistral",
                .model = "mistral-medium-latest",
                .usage = types.Usage.init(),
                .stop_reason = .tool_use,
                .timestamp = 2,
            } },
            .{ .tool_result = .{
                .tool_call_id = "call_with_very_long_non_mistral_id",
                .tool_name = "get_weather",
                .content = &[_]types.ContentBlock{
                    .{ .text = .{ .text = "Sunny" } },
                },
                .timestamp = 3,
            } },
        },
        .tools = &[_]types.Tool{.{
            .name = "get_weather",
            .description = "Get weather",
            .parameters = tool_schema_value,
        }},
    };

    const model = types.Model{
        .id = "mistral-medium-latest",
        .name = "Mistral Medium",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 131072,
        .max_tokens = 32768,
    };

    const payload = try buildRequestPayload(allocator, model, context, .{
        .temperature = 0.4,
        .max_tokens = 2048,
        .mistral_prompt_mode = "reasoning",
    });
    defer freeJsonValue(allocator, payload);

    try std.testing.expectEqualStrings("mistral-medium-latest", payload.object.get("model").?.string);
    try std.testing.expect(payload.object.get("messages").? == .array);
    try std.testing.expect(payload.object.get("tools").? == .array);
    try std.testing.expectEqualStrings("reasoning", payload.object.get("prompt_mode").?.string);

    const messages = payload.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 4), messages.items.len);
    const assistant_message = messages.items[2].object;
    const assistant_tool_call = assistant_message.get("tool_calls").?.array.items[0].object;
    const normalized_id = assistant_tool_call.get("id").?.string;
    try std.testing.expectEqual(@as(usize, MISTRAL_TOOL_CALL_ID_LENGTH), normalized_id.len);
    const tool_message = messages.items[3].object;
    try std.testing.expectEqualStrings(normalized_id, tool_message.get("tool_call_id").?.string);
}

test "buildRequestPayload preserves reasoning_effort and unsupported image placeholder" {
    const allocator = std.testing.allocator;

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{
                    .{ .image = .{ .data = "aGVsbG8=", .mime_type = "image/png" } },
                },
                .timestamp = 1,
            } },
        },
    };

    const model = types.Model{
        .id = "mistral-small-latest",
        .name = "Mistral Small",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
        .max_tokens = 32768,
    };

    const payload = try buildRequestPayload(allocator, model, context, .{
        .mistral_reasoning_effort = "high",
    });
    defer freeJsonValue(allocator, payload);

    try std.testing.expectEqualStrings("high", payload.object.get("reasoning_effort").?.string);
    const user_message = payload.object.get("messages").?.array.items[0].object;
    const content = user_message.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings(IMAGE_OMITTED_TEXT, content.get("text").?.string);
}

test "parse stream emits text events and usage" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"id\":\"resp_1\",\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}\n" ++
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n" ++
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
        .id = "mistral-medium-latest",
        .name = "Mistral Medium",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);
    const delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("Hello", delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream_instance.next().?.event_type);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.stop, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(u32, 10), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 5), done.message.?.usage.output);
    try std.testing.expectEqualStrings("resp_1", done.message.?.response_id.?);
}

test "parse stream emits thinking and tool call events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"choices\":[{\"delta\":{\"content\":[{\"type\":\"thinking\",\"thinking\":[{\"type\":\"text\",\"text\":\"Need tool\"}]}]},\"finish_reason\":null}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call-tool-1\",\"index\":0,\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\"}}]},\"finish_reason\":null}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call-tool-1\",\"index\":0,\"function\":{\"arguments\":\"\\\"Berlin\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":12,\"total_tokens\":32}}\n" ++
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
        .id = "mistral-small-latest",
        .name = "Mistral Small",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream_instance.next().?.event_type);
    const thinking_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.thinking_delta, thinking_delta.event_type);
    try std.testing.expectEqualStrings("Need tool", thinking_delta.delta.?);
    try std.testing.expectEqual(types.EventType.thinking_end, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream_instance.next().?.event_type);
    _ = stream_instance.next().?;
    _ = stream_instance.next().?;
    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqualStrings("get_weather", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("Berlin", tool_end.tool_call.?.arguments.object.get("city").?.string);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(u32, 20), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 12), done.message.?.usage.output);
}

test "mapStopReason handles tool calls and length" {
    try std.testing.expectEqual(types.StopReason.stop, mapStopReason("stop"));
    try std.testing.expectEqual(types.StopReason.length, mapStopReason("model_length"));
    try std.testing.expectEqual(types.StopReason.tool_use, mapStopReason("tool_calls"));
    try std.testing.expectEqual(types.StopReason.error_reason, mapStopReason("error"));
}
