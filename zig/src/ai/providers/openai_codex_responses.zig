const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");
const env_api_keys = @import("../env_api_keys.zig");
const provider_error = @import("../shared/provider_error.zig");
const openai = @import("openai.zig");

const DEFAULT_CODEX_BASE_URL = "https://chatgpt.com/backend-api";
const CODEX_AUTH_CLAIM = "https://api.openai.com/auth";

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

pub const OpenAICodexResponsesProvider = struct {
    pub const api = "openai-codex-responses";

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

        if (api_key == null or std.mem.trim(u8, api_key.?, " \t\r\n").len == 0) {
            const error_message = try std.fmt.allocPrint(allocator, "No API key for provider: {s}", .{model.provider});
            return emitErrorMessage(allocator, &stream_instance, model, error_message);
        }

        const normalized_token = stripBearerPrefix(std.mem.trim(u8, api_key.?, " \t\r\n"));
        const account_id = extractAccountId(allocator, normalized_token) catch |err| {
            const error_message = try std.fmt.allocPrint(allocator, "Invalid Codex API key: {s}", .{@errorName(err)});
            return emitErrorMessage(allocator, &stream_instance, model, error_message);
        };
        defer allocator.free(account_id);

        const url = try resolveCodexUrl(allocator, model.base_url);
        defer allocator.free(url);

        var headers = std.StringHashMap([]const u8).init(allocator);
        defer deinitOwnedHeaders(allocator, &headers);
        try putOwnedHeader(allocator, &headers, "Content-Type", "application/json");
        try putOwnedHeader(allocator, &headers, "Accept", "text/event-stream");
        try putOwnedHeader(allocator, &headers, "OpenAI-Beta", "responses=experimental");
        try putOwnedHeader(allocator, &headers, "originator", "pi");
        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{normalized_token});
        defer allocator.free(auth_header);
        try putOwnedHeader(allocator, &headers, "Authorization", auth_header);
        try putOwnedHeader(allocator, &headers, "chatgpt-account-id", account_id);
        try mergeHeaders(allocator, &headers, model.headers);
        if (options) |stream_options| {
            try mergeHeaders(allocator, &headers, stream_options.headers);
            if (stream_options.session_id) |session_id| {
                try putOwnedHeader(allocator, &headers, "session_id", session_id);
                try putOwnedHeader(allocator, &headers, "x-client-request-id", session_id);
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
            const response_body = try response.readAll(allocator);
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
        return try stream(allocator, io, model, context, options);
    }
};

fn emitErrorMessage(
    allocator: std.mem.Allocator,
    stream_instance: *event_stream.AssistantMessageEventStream,
    model: types.Model,
    error_message: []const u8,
) !event_stream.AssistantMessageEventStream {
    _ = allocator;
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
    return stream_instance.*;
}

pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    var input = std.json.Array.init(allocator);
    errdefer input.deinit();

    for (context.messages, 0..) |message, message_index| {
        try appendInputItemsForMessage(allocator, &input, model, message, message_index);
    }

    var payload = try initObject(allocator);
    errdefer payload.deinit(allocator);

    try payload.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, model.id) });
    try payload.put(allocator, try allocator.dupe(u8, "input"), .{ .array = input });
    try payload.put(allocator, try allocator.dupe(u8, "store"), .{ .bool = false });
    try payload.put(allocator, try allocator.dupe(u8, "stream"), .{ .bool = true });
    try payload.put(allocator, try allocator.dupe(u8, "tool_choice"), .{ .string = try allocator.dupe(u8, "auto") });
    try payload.put(allocator, try allocator.dupe(u8, "parallel_tool_calls"), .{ .bool = true });

    var text_config = try initObject(allocator);
    errdefer text_config.deinit(allocator);
    try text_config.put(allocator, try allocator.dupe(u8, "verbosity"), .{ .string = try allocator.dupe(u8, "medium") });
    try payload.put(allocator, try allocator.dupe(u8, "text"), .{ .object = text_config });

    var include = std.json.Array.init(allocator);
    errdefer include.deinit();
    try include.append(.{ .string = try allocator.dupe(u8, "reasoning.encrypted_content") });
    try payload.put(allocator, try allocator.dupe(u8, "include"), .{ .array = include });

    const instructions = if (context.system_prompt) |system_prompt|
        try openai.sanitizeSurrogates(allocator, system_prompt)
    else
        try allocator.dupe(u8, "");
    defer allocator.free(instructions);
    try payload.put(allocator, try allocator.dupe(u8, "instructions"), .{ .string = try allocator.dupe(u8, instructions) });

    if (options) |stream_options| {
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
            if (stream_options.cache_retention == .long) {
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
                const sanitized = try openai.sanitizeSurrogates(allocator, text.text);
                defer allocator.free(sanitized);
                try text_object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, sanitized) });
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

        const event_type = extractStringField(value, "type") orelse continue;

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

        if (std.mem.eql(u8, event_type, "response.done") or std.mem.eql(u8, event_type, "response.completed") or std.mem.eql(u8, event_type, "response.incomplete")) {
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
    const item_type = extractStringField(item_value, "type") orelse return;

    if (std.mem.eql(u8, item_type, "reasoning")) {
        if (current_block.* != null) return;
        current_block.* = .{ .thinking = .{
            .event_index = content_blocks.items.len,
            .text = std.ArrayList(u8).empty,
            .signature = null,
        } };
        stream_ptr.push(.{ .event_type = .thinking_start, .content_index = @intCast(content_blocks.items.len) });
        return;
    }

    if (std.mem.eql(u8, item_type, "message")) {
        if (current_block.* != null) return;
        current_block.* = .{ .text = .{
            .event_index = content_blocks.items.len,
            .text = std.ArrayList(u8).empty,
            .part_kind = .output_text,
        } };
        stream_ptr.push(.{ .event_type = .text_start, .content_index = @intCast(content_blocks.items.len) });
        return;
    }

    if (std.mem.eql(u8, item_type, "function_call")) {
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
    const part_type = extractStringField(item_value, "type") orelse return;

    if (current_block.*) |*block| {
        switch (block.*) {
            .text => |*text| {
                text.part_kind = if (std.mem.eql(u8, part_type, "refusal")) .refusal else .output_text;
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
                const final_text = if (extractFinalTextFromItem(maybe_item_value, text.part_kind)) |value|
                    if (value.len > 0 or text.text.items.len == 0) value else text.text.items
                else
                    text.text.items;
                const owned = try allocator.dupe(u8, final_text);
                try content_blocks.append(allocator, .{ .text = .{ .text = owned } });
                stream_ptr.push(.{
                    .event_type = .text_end,
                    .content_index = @intCast(text.event_index),
                    .content = owned,
                });
            },
            .thinking => |*thinking| {
                const owned = try allocator.dupe(u8, thinking.text.items);
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

fn thinkingLevelString(level: types.ThinkingLevel) []const u8 {
    return switch (level) {
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn stripBearerPrefix(token: []const u8) []const u8 {
    if (std.mem.startsWith(u8, token, "Bearer ")) {
        return std.mem.trim(u8, token["Bearer ".len..], " \t\r\n");
    }
    return token;
}

fn extractAccountId(allocator: std.mem.Allocator, token: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return error.InvalidJwt;
    const payload_segment = parts.next() orelse return error.InvalidJwt;
    if (payload_segment.len == 0) return error.InvalidJwt;

    const decoded_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_segment);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, payload_segment);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, decoded, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJwtPayload;
    const auth_value = parsed.value.object.get(CODEX_AUTH_CLAIM) orelse return error.MissingAccountId;
    if (auth_value != .object) return error.MissingAccountId;
    const account_id_value = auth_value.object.get("chatgpt_account_id") orelse return error.MissingAccountId;
    if (account_id_value != .string or account_id_value.string.len == 0) return error.MissingAccountId;

    return try allocator.dupe(u8, account_id_value.string);
}

fn resolveCodexUrl(allocator: std.mem.Allocator, raw_base_url: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, raw_base_url, " \t\r\n"), "/");
    const base_url = if (trimmed.len > 0) trimmed else DEFAULT_CODEX_BASE_URL;

    if (std.mem.endsWith(u8, base_url, "/codex/responses")) return try allocator.dupe(u8, base_url);
    if (std.mem.endsWith(u8, base_url, "/codex")) return try std.fmt.allocPrint(allocator, "{s}/responses", .{base_url});
    return try std.fmt.allocPrint(allocator, "{s}/codex/responses", .{base_url});
}

fn updateResponseIdFromResponseObject(allocator: std.mem.Allocator, output: *types.AssistantMessage, response_value: std.json.Value) !void {
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

fn extractFinalTextFromItem(maybe_item_value: ?std.json.Value, part_kind: MessagePartKind) ?[]const u8 {
    const item_value = maybe_item_value orelse return null;
    if (item_value != .object) return null;
    const content = item_value.object.get("content") orelse return null;
    if (content != .array) return null;

    const expected_type: []const u8 = switch (part_kind) {
        .output_text => "output_text",
        .refusal => "refusal",
    };
    for (content.array.items) |part| {
        if (part != .object) continue;
        const part_type = extractStringField(part, "type") orelse continue;
        if (!std.mem.eql(u8, part_type, expected_type)) continue;
        return extractStringField(part, "text");
    }
    return null;
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

fn parseStreamingJsonToValue(allocator: std.mem.Allocator, input: []const u8) !std.json.Value {
    if (input.len == 0) return .{ .object = try initObject(allocator) };
    const parsed = json_parse.parseStreamingJson(allocator, input) catch {
        return .{ .object = try initObject(allocator) };
    };
    defer parsed.deinit();
    return try cloneJsonValue(allocator, parsed.value);
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

test "buildRequestPayload uses Codex-specific request shape" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    const context = types.Context{
        .system_prompt = "You are a helpful assistant.",
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Say hello" } }},
                .timestamp = 1,
            } },
        },
    };

    const payload = try buildRequestPayload(allocator, model, context, .{
        .session_id = "session-123",
        .cache_retention = .short,
    });
    defer freeJsonValue(allocator, payload);

    try std.testing.expect(payload == .object);
    try std.testing.expectEqualStrings("gpt-5.1-codex", payload.object.get("model").?.string);
    try std.testing.expectEqualStrings("You are a helpful assistant.", payload.object.get("instructions").?.string);
    try std.testing.expectEqualStrings("session-123", payload.object.get("prompt_cache_key").?.string);
    try std.testing.expectEqualStrings("auto", payload.object.get("tool_choice").?.string);
    try std.testing.expectEqual(payload.object.get("parallel_tool_calls").?.bool, true);
    try std.testing.expect(payload.object.get("max_output_tokens") == null);

    const text_config = payload.object.get("text").?;
    try std.testing.expect(text_config == .object);
    try std.testing.expectEqualStrings("medium", text_config.object.get("verbosity").?.string);

    const include = payload.object.get("include").?;
    try std.testing.expect(include == .array);
    try std.testing.expectEqualStrings("reasoning.encrypted_content", include.array.items[0].string);

    const input = payload.object.get("input").?;
    try std.testing.expect(input == .array);
    try std.testing.expectEqual(@as(usize, 1), input.array.items.len);
    try std.testing.expectEqualStrings("user", input.array.items[0].object.get("role").?.string);
}

test "parseSseStreamLines handles response.done terminal events" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_codex\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello Codex\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello Codex\"}]}}\n" ++
            "data: {\"type\":\"response.done\",\"response\":{\"id\":\"resp_codex\",\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":3,\"total_tokens\":8}}}\n",
    );

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);

    const delta = stream_instance.next().?;
    defer freeEventOwned(allocator, delta);
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("Hello Codex", delta.delta.?);

    const text_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("Hello Codex", text_end.content.?);

    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expect(done.message != null);
    try std.testing.expectEqualStrings("resp_codex", done.message.?.response_id.?);
    try std.testing.expectEqual(types.StopReason.stop, done.message.?.stop_reason);
    try std.testing.expectEqualStrings("Hello Codex", done.message.?.content[0].text.text);
    freeAssistantMessageOwned(allocator, done.message.?);
}

test "parseSseStreamLines uses final output item text when delta stream is incomplete" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"What would you like to work\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"What would you like to work on?\"}]}}\n" ++
            "data: {\"type\":\"response.done\",\"response\":{\"id\":\"resp_codex\",\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":7,\"total_tokens\":12}}}\n",
    );

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    const model = types.Model{
        .id = "gpt-5.5",
        .name = "Codex GPT-5.5",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);
    _ = stream_instance.next();
    _ = stream_instance.next();

    const delta = stream_instance.next().?;
    defer freeEventOwned(allocator, delta);
    const text_end = stream_instance.next().?;
    try std.testing.expectEqualStrings("What would you like to work on?", text_end.content.?);

    const done = stream_instance.next().?;
    try std.testing.expect(done.message != null);
    try std.testing.expectEqualStrings("What would you like to work on?", done.message.?.content[0].text.text);
    freeAssistantMessageOwned(allocator, done.message.?);
}

test "parseSseStreamLines maps incomplete Codex responses to length" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Partial\"}]}}\n" ++
            "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"usage\":{\"input_tokens\":2,\"output_tokens\":1,\"total_tokens\":3}}}\n",
    );

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);
    _ = stream_instance.next();
    _ = stream_instance.next();

    const delta = stream_instance.next().?;
    defer freeEventOwned(allocator, delta);
    _ = stream_instance.next();

    const done = stream_instance.next().?;
    try std.testing.expect(done.message != null);
    try std.testing.expectEqual(types.StopReason.length, done.message.?.stop_reason);
    freeAssistantMessageOwned(allocator, done.message.?);
}

test "extractAccountId reads ChatGPT account ID from JWT payload" {
    const allocator = std.testing.allocator;
    const account_id = try extractAccountId(
        allocator,
        "aaa.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOiB7ImNoYXRncHRfYWNjb3VudF9pZCI6ICJhY2NfdGVzdCJ9fQ.bbb",
    );
    defer allocator.free(account_id);

    try std.testing.expectEqualStrings("acc_test", account_id);
}

test "resolveCodexUrl appends codex responses path" {
    const allocator = std.testing.allocator;
    const url = try resolveCodexUrl(allocator, "https://chatgpt.com/backend-api/");
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", url);
}

test "stream HTTP status error is terminal sanitized event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"error\":{\"message\":\"codex denied\",\"authorization\":\"Bearer sk-codex-secret\",\"request_id\":\"req_codex_random_123456\"},\"trace\":\"/Users/alice/pi/openai_codex_responses.zig\"}");
    try body.appendNTimes(allocator, 'x', 900);

    var server = try provider_error.TestStatusServer.init(io, 429, "Too Many Requests", "", body.items);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const payload_json = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acc_test\"}}";
    var encoded_payload: [std.base64.url_safe_no_pad.Encoder.calcSize(payload_json.len)]u8 = undefined;
    const payload_segment = std.base64.url_safe_no_pad.Encoder.encode(&encoded_payload, payload_json);
    const api_key = try std.fmt.allocPrint(allocator, "aaa.{s}.sig", .{payload_segment});
    defer allocator.free(api_key);

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = url,
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
    };

    var stream = try OpenAICodexResponsesProvider.stream(allocator, io, model, context, .{ .api_key = api_key });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 429: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "codex denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "[truncated]") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "sk-codex-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_codex_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("openai-codex-responses", result.api);
}

test "buildRequestPayload includes empty instructions when no system prompt is provided" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-5.5",
        .name = "Codex GPT-5.5",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &[_]types.Message{} }, null);
    defer freeJsonValue(allocator, payload);

    try std.testing.expectEqualStrings("", payload.object.get("instructions").?.string);
}

test "buildRequestPayload preserves xhigh reasoning for GPT-5.5" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-5.5",
        .name = "Codex GPT-5.5",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &[_]types.Message{} }, .{
        .responses_reasoning_effort = .xhigh,
    });
    defer freeJsonValue(allocator, payload);

    const reasoning = payload.object.get("reasoning").?;
    try std.testing.expect(reasoning == .object);
    try std.testing.expectEqualStrings("xhigh", reasoning.object.get("effort").?.string);
    try std.testing.expectEqualStrings("auto", reasoning.object.get("summary").?.string);
}

test "buildRequestPayload omits empty tools array" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "codex-mini",
        .name = "Codex Mini",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 65536,
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
