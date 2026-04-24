const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");

pub const GoogleProvider = struct {
    pub const api = "google-generative-ai";

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

        const url = try std.fmt.allocPrint(allocator, "{s}/models/{s}:streamGenerateContent?alt=sse", .{ model.base_url, model.id });
        defer allocator.free(url);

        var headers = std.StringHashMap([]const u8).init(allocator);
        defer headers.deinit();
        try headers.put("Content-Type", "application/json");
        try headers.put("Accept", "text/event-stream");
        if (options) |stream_options| {
            if (stream_options.api_key) |api_key| {
                try headers.put("x-goog-api-key", try allocator.dupe(u8, api_key));
            }
        }
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

    try payload.put(allocator, try allocator.dupe(u8, "contents"), try buildContentsValue(allocator, model, context.messages));

    if (context.system_prompt) |system_prompt| {
        try payload.put(allocator, try allocator.dupe(u8, "systemInstruction"), try buildSystemInstructionValue(allocator, system_prompt));
    }

    try payload.put(allocator, try allocator.dupe(u8, "generationConfig"), try buildGenerationConfigValue(allocator, model, options));

    if (context.tools) |tools| {
        if (tools.len > 0) {
            try payload.put(allocator, try allocator.dupe(u8, "tools"), try buildToolsValue(allocator, tools));
            if (options) |stream_options| {
                if (stream_options.google_tool_choice) |tool_choice| {
                    try payload.put(allocator, try allocator.dupe(u8, "toolConfig"), try buildToolConfigValue(allocator, tool_choice));
                }
            }
        }
    }

    return .{ .object = payload };
}

const CurrentBlock = union(enum) {
    text: std.ArrayList(u8),
    thinking: struct {
        text: std.ArrayList(u8),
        signature: ?[]const u8,
    },
};

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

    var generated_tool_call_count: usize = 0;

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

        if (value.object.get("responseId")) |response_id| {
            if (response_id == .string and output.response_id == null) {
                output.response_id = try allocator.dupe(u8, response_id.string);
            }
        }

        if (value.object.get("usageMetadata")) |usage_metadata| {
            updateUsage(&output.usage, usage_metadata);
            calculateCost(model, &output.usage);
        }

        const candidates_value = value.object.get("candidates") orelse continue;
        if (candidates_value != .array or candidates_value.array.items.len == 0) continue;

        const candidate = candidates_value.array.items[0];
        if (candidate != .object) continue;

        if (candidate.object.get("content")) |content_value| {
            if (content_value == .object) {
                if (content_value.object.get("parts")) |parts_value| {
                    if (parts_value == .array) {
                        for (parts_value.array.items) |part| {
                            if (part != .object) continue;

                            if (part.object.get("text")) |text_value| {
                                if (text_value == .string and text_value.string.len > 0) {
                                    const is_thinking = if (part.object.get("thought")) |thought_value|
                                        thought_value == .bool and thought_value.bool
                                    else
                                        false;

                                    if (current_block == null or !matchesCurrentBlock(current_block.?, is_thinking)) {
                                        try finishCurrentBlock(allocator, &current_block, &content_blocks, stream_ptr);
                                        current_block = if (is_thinking)
                                            .{ .thinking = .{ .text = std.ArrayList(u8).empty, .signature = null } }
                                        else
                                            .{ .text = std.ArrayList(u8).empty };
                                        stream_ptr.push(.{
                                            .event_type = if (is_thinking) .thinking_start else .text_start,
                                            .content_index = @intCast(content_blocks.items.len),
                                        });
                                    }

                                    if (current_block) |*block| {
                                        switch (block.*) {
                                            .text => |*text| try text.appendSlice(allocator, text_value.string),
                                            .thinking => |*thinking| {
                                                try thinking.text.appendSlice(allocator, text_value.string);
                                                if (part.object.get("thoughtSignature")) |signature_value| {
                                                    if (signature_value == .string and signature_value.string.len > 0) {
                                                        if (thinking.signature) |existing| allocator.free(existing);
                                                        thinking.signature = try allocator.dupe(u8, signature_value.string);
                                                    }
                                                }
                                            },
                                        }
                                    }

                                    stream_ptr.push(.{
                                        .event_type = if (is_thinking) .thinking_delta else .text_delta,
                                        .content_index = @intCast(content_blocks.items.len),
                                        .delta = try allocator.dupe(u8, text_value.string),
                                        .owns_delta = true,
                                    });
                                }
                            }

                            if (part.object.get("functionCall")) |function_call_value| {
                                if (function_call_value == .object) {
                                    try finishCurrentBlock(allocator, &current_block, &content_blocks, stream_ptr);
                                    const name_value = function_call_value.object.get("name");
                                    if (name_value == null or name_value.? != .string) continue;

                                    const args = if (function_call_value.object.get("args")) |args_value|
                                        try cloneJsonValue(allocator, args_value)
                                    else
                                        try emptyJsonObject(allocator);

                                    const tool_call_id = if (function_call_value.object.get("id")) |id_value|
                                        if (id_value == .string and id_value.string.len > 0) try allocator.dupe(u8, id_value.string) else try generateToolCallId(allocator, &generated_tool_call_count)
                                    else
                                        try generateToolCallId(allocator, &generated_tool_call_count);

                                    const tool_call = types.ToolCall{
                                        .id = tool_call_id,
                                        .name = try allocator.dupe(u8, name_value.?.string),
                                        .arguments = args,
                                    };
                                    try tool_calls.append(allocator, tool_call);
                                    try content_blocks.append(allocator, .{ .text = .{ .text = "" } });

                                    stream_ptr.push(.{
                                        .event_type = .toolcall_start,
                                        .content_index = @intCast(content_blocks.items.len - 1),
                                    });

                                    const args_json = try std.json.Stringify.valueAlloc(allocator, args, .{});
                                    defer allocator.free(args_json);
                                    stream_ptr.push(.{
                                        .event_type = .toolcall_delta,
                                        .content_index = @intCast(content_blocks.items.len - 1),
                                        .delta = try allocator.dupe(u8, args_json),
                                        .owns_delta = true,
                                    });
                                    stream_ptr.push(.{
                                        .event_type = .toolcall_end,
                                        .content_index = @intCast(content_blocks.items.len - 1),
                                        .tool_call = tool_call,
                                    });
                                }
                            }
                        }
                    }
                }
            }
        }

        if (candidate.object.get("finishReason")) |finish_reason| {
            if (finish_reason == .string) {
                output.stop_reason = if (tool_calls.items.len > 0) .tool_use else mapStopReason(finish_reason.string);
            }
        }
    }

    try finishCurrentBlock(allocator, &current_block, &content_blocks, stream_ptr);
    calculateCost(model, &output.usage);
    output.content = try content_blocks.toOwnedSlice(allocator);
    output.tool_calls = if (tool_calls.items.len > 0) try tool_calls.toOwnedSlice(allocator) else null;

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

fn matchesCurrentBlock(block: CurrentBlock, is_thinking: bool) bool {
    return switch (block) {
        .text => !is_thinking,
        .thinking => is_thinking,
    };
}

fn finishCurrentBlock(
    allocator: std.mem.Allocator,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    if (current_block.*) |*block| {
        switch (block.*) {
            .text => |text| {
                const owned = try allocator.dupe(u8, text.items);
                try content_blocks.append(allocator, .{ .text = .{ .text = owned } });
                stream_ptr.push(.{
                    .event_type = .text_end,
                    .content_index = @intCast(content_blocks.items.len - 1),
                    .content = owned,
                });
            },
            .thinking => |thinking| {
                const owned = try allocator.dupe(u8, thinking.text.items);
                const signature = if (thinking.signature) |value| try allocator.dupe(u8, value) else null;
                try content_blocks.append(allocator, .{ .thinking = .{
                    .thinking = owned,
                    .signature = signature,
                    .redacted = false,
                } });
                stream_ptr.push(.{
                    .event_type = .thinking_end,
                    .content_index = @intCast(content_blocks.items.len - 1),
                    .content = owned,
                });
            },
        }
        deinitCurrentBlock(allocator, block);
        current_block.* = null;
    }
}

fn deinitCurrentBlock(allocator: std.mem.Allocator, block: *CurrentBlock) void {
    switch (block.*) {
        .text => |*text| text.deinit(allocator),
        .thinking => |*thinking| {
            thinking.text.deinit(allocator);
            if (thinking.signature) |signature| allocator.free(signature);
        },
    }
}

fn buildContentsValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    messages: []const types.Message,
) !std.json.Value {
    var contents = std.json.Array.init(allocator);
    errdefer contents.deinit();

    var index: usize = 0;
    while (index < messages.len) : (index += 1) {
        switch (messages[index]) {
            .user => |user| try contents.append(try buildUserMessageValue(allocator, model, user)),
            .assistant => |assistant| {
                if (try buildAssistantMessageValue(allocator, assistant)) |assistant_value| {
                    try contents.append(assistant_value);
                }
            },
            .tool_result => {
                const grouped = try buildToolResultMessageValue(allocator, model, messages[index..]);
                try contents.append(grouped.value);
                index += grouped.consumed - 1;
            },
        }
    }

    return .{ .array = contents };
}

fn buildSystemInstructionValue(allocator: std.mem.Allocator, system_prompt: []const u8) !std.json.Value {
    var parts = std.json.Array.init(allocator);
    try parts.append(try buildTextPartValue(allocator, system_prompt));

    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "parts"), .{ .array = parts });
    return .{ .object = object };
}

fn buildGenerationConfigValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
) !std.json.Value {
    var generation_config = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer generation_config.deinit(allocator);

    if (options) |stream_options| {
        if (stream_options.temperature) |temperature| {
            try generation_config.put(allocator, try allocator.dupe(u8, "temperature"), .{ .float = temperature });
        }
        if (stream_options.max_tokens) |max_tokens| {
            try generation_config.put(allocator, try allocator.dupe(u8, "maxOutputTokens"), .{ .integer = @intCast(max_tokens) });
        }
        if (stream_options.google_thinking) |thinking| {
            if (model.reasoning) {
                var thinking_config = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                if (thinking.enabled) {
                    try thinking_config.put(allocator, try allocator.dupe(u8, "includeThoughts"), .{ .bool = true });
                    if (thinking.budget_tokens) |budget_tokens| {
                        try thinking_config.put(allocator, try allocator.dupe(u8, "thinkingBudget"), .{ .integer = @intCast(budget_tokens) });
                    }
                    if (thinking.level) |level| {
                        try thinking_config.put(allocator, try allocator.dupe(u8, "thinkingLevel"), .{ .string = try allocator.dupe(u8, level) });
                    }
                } else {
                    try thinking_config.put(allocator, try allocator.dupe(u8, "thinkingBudget"), .{ .integer = 0 });
                }
                try generation_config.put(allocator, try allocator.dupe(u8, "thinkingConfig"), .{ .object = thinking_config });
            }
        }
    }

    return .{ .object = generation_config };
}

fn buildToolsValue(allocator: std.mem.Allocator, tools: []const types.Tool) !std.json.Value {
    var function_declarations = std.json.Array.init(allocator);
    errdefer function_declarations.deinit();

    for (tools) |tool| {
        var declaration = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try declaration.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool.name) });
        try declaration.put(allocator, try allocator.dupe(u8, "description"), .{ .string = try allocator.dupe(u8, tool.description) });
        try declaration.put(allocator, try allocator.dupe(u8, "parametersJsonSchema"), try cloneJsonValue(allocator, tool.parameters));
        try function_declarations.append(.{ .object = declaration });
    }

    var tool_entry = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_entry.put(allocator, try allocator.dupe(u8, "functionDeclarations"), .{ .array = function_declarations });

    var tools_array = std.json.Array.init(allocator);
    try tools_array.append(.{ .object = tool_entry });
    return .{ .array = tools_array };
}

fn buildToolConfigValue(allocator: std.mem.Allocator, tool_choice: []const u8) !std.json.Value {
    var function_calling_config = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try function_calling_config.put(allocator, try allocator.dupe(u8, "mode"), .{ .string = try allocator.dupe(u8, mapToolChoice(tool_choice)) });

    var tool_config = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_config.put(allocator, try allocator.dupe(u8, "functionCallingConfig"), .{ .object = function_calling_config });
    return .{ .object = tool_config };
}

fn buildUserMessageValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    user: types.UserMessage,
) !std.json.Value {
    const parts = try buildPartsArray(allocator, user.content, modelSupportsImages(model));
    return try buildRoleMessageValue(allocator, "user", .{ .array = parts });
}

fn buildAssistantMessageValue(
    allocator: std.mem.Allocator,
    assistant: types.AssistantMessage,
) !?std.json.Value {
    var parts = std.json.Array.init(allocator);
    errdefer parts.deinit();

    for (assistant.content) |block| {
        switch (block) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) continue;
                try parts.append(try buildTextPartValue(allocator, text.text));
            },
            .thinking => |thinking| {
                if (std.mem.trim(u8, thinking.thinking, " \t\r\n").len == 0) continue;
                var thought_part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try thought_part.put(allocator, try allocator.dupe(u8, "thought"), .{ .bool = true });
                try thought_part.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, thinking.thinking) });
                if (thinking.signature) |signature| {
                    try thought_part.put(allocator, try allocator.dupe(u8, "thoughtSignature"), .{ .string = try allocator.dupe(u8, signature) });
                }
                try parts.append(.{ .object = thought_part });
            },
            .image => {},
        }
    }

    if (assistant.tool_calls) |tool_calls| {
        for (tool_calls) |tool_call| {
            var function_call = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            try function_call.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool_call.name) });
            try function_call.put(allocator, try allocator.dupe(u8, "args"), try cloneJsonValue(allocator, tool_call.arguments));

            var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            try part.put(allocator, try allocator.dupe(u8, "functionCall"), .{ .object = function_call });
            try parts.append(.{ .object = part });
        }
    }

    if (parts.items.len == 0) return null;
    return try buildRoleMessageValue(allocator, "model", .{ .array = parts });
}

fn buildToolResultMessageValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    messages: []const types.Message,
) !struct { value: std.json.Value, consumed: usize } {
    var parts = std.json.Array.init(allocator);
    errdefer parts.deinit();

    var consumed: usize = 0;
    while (consumed < messages.len) : (consumed += 1) {
        switch (messages[consumed]) {
            .tool_result => |tool_result| {
                var function_response = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try function_response.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool_result.tool_name) });

                var response = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                const text_response = try buildToolResultText(allocator, model, tool_result.content);
                defer allocator.free(text_response);
                try response.put(
                    allocator,
                    try allocator.dupe(u8, if (tool_result.is_error) "error" else "output"),
                    .{ .string = try allocator.dupe(u8, text_response) },
                );
                try function_response.put(allocator, try allocator.dupe(u8, "response"), .{ .object = response });

                if (modelSupportsImages(model)) {
                    if (try buildToolResultImageParts(allocator, tool_result.content)) |image_parts| {
                        try function_response.put(allocator, try allocator.dupe(u8, "parts"), .{ .array = image_parts });
                    }
                }

                var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try part.put(allocator, try allocator.dupe(u8, "functionResponse"), .{ .object = function_response });
                try parts.append(.{ .object = part });
            },
            else => break,
        }
    }

    return .{
        .value = try buildRoleMessageValue(allocator, "user", .{ .array = parts }),
        .consumed = consumed,
    };
}

fn buildPartsArray(
    allocator: std.mem.Allocator,
    content: []const types.ContentBlock,
    supports_images: bool,
) !std.json.Array {
    var parts = std.json.Array.init(allocator);
    errdefer parts.deinit();

    var inserted_placeholder = false;
    for (content) |block| {
        switch (block) {
            .text => |text| {
                try parts.append(try buildTextPartValue(allocator, text.text));
                inserted_placeholder = false;
            },
            .image => |image| {
                if (supports_images) {
                    try parts.append(try buildImagePartValue(allocator, image.mime_type, image.data));
                } else if (!inserted_placeholder) {
                    try parts.append(try buildTextPartValue(allocator, "(image omitted: model does not support images)"));
                    inserted_placeholder = true;
                }
            },
            .thinking => {},
        }
    }

    if (parts.items.len == 0) {
        try parts.append(try buildTextPartValue(allocator, ""));
    }
    return parts;
}

fn buildTextPartValue(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try part.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text) });
    return .{ .object = part };
}

fn buildImagePartValue(allocator: std.mem.Allocator, mime_type: []const u8, data: []const u8) !std.json.Value {
    var inline_data = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try inline_data.put(allocator, try allocator.dupe(u8, "mimeType"), .{ .string = try allocator.dupe(u8, mime_type) });
    try inline_data.put(allocator, try allocator.dupe(u8, "data"), .{ .string = try allocator.dupe(u8, data) });

    var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try part.put(allocator, try allocator.dupe(u8, "inlineData"), .{ .object = inline_data });
    return .{ .object = part };
}

fn buildRoleMessageValue(allocator: std.mem.Allocator, role: []const u8, parts: std.json.Value) !std.json.Value {
    var message = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try message.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, role) });
    try message.put(allocator, try allocator.dupe(u8, "parts"), parts);
    return .{ .object = message };
}

fn buildToolResultText(
    allocator: std.mem.Allocator,
    model: types.Model,
    content: []const types.ContentBlock,
) ![]const u8 {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);

    var has_images = false;
    var has_text = false;
    for (content) |block| {
        switch (block) {
            .text => |text_block| {
                if (has_text) try text.append(allocator, '\n');
                try text.appendSlice(allocator, text_block.text);
                has_text = true;
            },
            .image => has_images = true,
            .thinking => |thinking| {
                if (has_text) try text.append(allocator, '\n');
                try text.appendSlice(allocator, thinking.thinking);
                has_text = true;
            },
        }
    }

    if (!has_text and has_images and modelSupportsImages(model)) {
        try text.appendSlice(allocator, "(see attached image)");
    }

    return try allocator.dupe(u8, text.items);
}

fn buildToolResultImageParts(allocator: std.mem.Allocator, content: []const types.ContentBlock) !?std.json.Array {
    var parts = std.json.Array.init(allocator);
    errdefer parts.deinit();

    for (content) |block| {
        switch (block) {
            .image => |image| try parts.append(try buildImagePartValue(allocator, image.mime_type, image.data)),
            else => {},
        }
    }

    if (parts.items.len == 0) return null;
    return parts;
}

fn parseSseLine(line: []const u8) ?[]const u8 {
    const prefix = "data: ";
    if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    return null;
}

fn mapToolChoice(tool_choice: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(tool_choice, "none")) return "NONE";
    if (std.ascii.eqlIgnoreCase(tool_choice, "any")) return "ANY";
    return "AUTO";
}

fn mapStopReason(reason: []const u8) types.StopReason {
    if (std.mem.eql(u8, reason, "STOP")) return .stop;
    if (std.mem.eql(u8, reason, "MAX_TOKENS")) return .length;
    return .error_reason;
}

fn generateToolCallId(allocator: std.mem.Allocator, counter: *usize) ![]const u8 {
    counter.* += 1;
    return try std.fmt.allocPrint(allocator, "google-call-{d}", .{counter.*});
}

fn modelSupportsImages(model: types.Model) bool {
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) return true;
    }
    return false;
}

fn emptyJsonObject(allocator: std.mem.Allocator) !std.json.Value {
    return .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) };
}

fn updateUsage(usage: *types.Usage, usage_value: std.json.Value) void {
    if (usage_value != .object) return;

    const prompt_tokens = getJsonU32(usage_value.object.get("promptTokenCount"));
    const cached_tokens = getJsonU32(usage_value.object.get("cachedContentTokenCount"));
    const candidate_tokens = getJsonU32(usage_value.object.get("candidatesTokenCount"));
    const thought_tokens = getJsonU32(usage_value.object.get("thoughtsTokenCount"));
    const total_tokens = getJsonU32(usage_value.object.get("totalTokenCount"));

    usage.input = prompt_tokens -| cached_tokens;
    usage.output = candidate_tokens + thought_tokens;
    usage.cache_read = cached_tokens;
    usage.cache_write = 0;
    usage.total_tokens = if (total_tokens > 0) total_tokens else usage.input + usage.output + usage.cache_read;
}

fn getJsonU32(value: ?std.json.Value) u32 {
    if (value) |json_value| {
        if (json_value == .integer and json_value.integer >= 0) {
            return @intCast(json_value.integer);
        }
    }
    return 0;
}

fn calculateCost(model: types.Model, usage: *types.Usage) void {
    usage.cost.input = (@as(f64, @floatFromInt(usage.input)) / 1_000_000.0) * model.cost.input;
    usage.cost.output = (@as(f64, @floatFromInt(usage.output)) / 1_000_000.0) * model.cost.output;
    usage.cost.cache_read = (@as(f64, @floatFromInt(usage.cache_read)) / 1_000_000.0) * model.cost.cache_read;
    usage.cost.cache_write = (@as(f64, @floatFromInt(usage.cache_write)) / 1_000_000.0) * model.cost.cache_write;
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
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

fn isAbortRequested(options: ?types.StreamOptions) bool {
    if (options) |stream_options| {
        if (stream_options.signal) |signal| return signal.load(.seq_cst);
    }
    return false;
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

test "buildRequestPayload includes contents, tools, generation config, and thinking config" {
    const allocator = std.testing.allocator;

    var tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_schema.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });
    try tool_schema.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) });
    const tool_schema_value = std.json.Value{ .object = tool_schema };
    defer freeJsonValue(allocator, tool_schema_value);

    const tools = &[_]types.Tool{.{
        .name = "get_weather",
        .description = "Get the weather",
        .parameters = tool_schema_value,
    }};

    const context = types.Context{
        .system_prompt = "You are helpful.",
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{
                    .{ .text = .{ .text = "Describe this image" } },
                    .{ .image = .{ .data = "aGVsbG8=", .mime_type = "image/png" } },
                },
                .timestamp = 1,
            } },
        },
        .tools = tools,
    };

    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Gemini 2.5 Pro",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    const payload = try buildRequestPayload(allocator, model, context, .{
        .temperature = 0.5,
        .max_tokens = 2048,
        .google_tool_choice = "any",
        .google_thinking = .{
            .enabled = true,
            .budget_tokens = 8192,
        },
    });
    defer freeJsonValue(allocator, payload);

    const contents = payload.object.get("contents").?;
    try std.testing.expect(contents == .array);
    try std.testing.expectEqual(@as(usize, 1), contents.array.items.len);

    const user_message = contents.array.items[0];
    try std.testing.expect(user_message == .object);
    try std.testing.expectEqualStrings("user", user_message.object.get("role").?.string);

    const parts = user_message.object.get("parts").?;
    try std.testing.expect(parts == .array);
    try std.testing.expectEqual(@as(usize, 2), parts.array.items.len);
    try std.testing.expect(parts.array.items[1].object.get("inlineData") != null);

    const system_instruction = payload.object.get("systemInstruction").?;
    try std.testing.expect(system_instruction == .object);
    try std.testing.expect(system_instruction.object.get("parts") != null);

    const generation_config = payload.object.get("generationConfig").?;
    try std.testing.expect(generation_config == .object);
    try std.testing.expectEqual(@as(i64, 2048), generation_config.object.get("maxOutputTokens").?.integer);
    try std.testing.expect(generation_config.object.get("thinkingConfig") != null);

    const tool_config = payload.object.get("toolConfig").?;
    try std.testing.expect(tool_config == .object);
    try std.testing.expectEqualStrings("ANY", tool_config.object.get("functionCallingConfig").?.object.get("mode").?.string);

    const payload_tools = payload.object.get("tools").?;
    try std.testing.expect(payload_tools == .array);
    try std.testing.expectEqual(@as(usize, 1), payload_tools.array.items.len);
}

test "buildRequestPayload converts assistant tool calls and tool results" {
    const allocator = std.testing.allocator;

    var tool_args = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_args.put(allocator, try allocator.dupe(u8, "city"), .{ .string = try allocator.dupe(u8, "Berlin") });
    const tool_args_value = std.json.Value{ .object = tool_args };
    defer freeJsonValue(allocator, tool_args_value);

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .assistant = .{
                .content = &[_]types.ContentBlock{
                    .{ .thinking = .{ .thinking = "Need weather data", .signature = "c2ln", .redacted = false } },
                    .{ .text = .{ .text = "Calling tool" } },
                },
                .tool_calls = &[_]types.ToolCall{.{
                    .id = "tool-1",
                    .name = "get_weather",
                    .arguments = tool_args_value,
                }},
                .api = "google-generative-ai",
                .provider = "google",
                .model = "gemini-2.5-pro",
                .usage = types.Usage.init(),
                .stop_reason = .tool_use,
                .timestamp = 2,
            } },
            .{ .tool_result = .{
                .tool_call_id = "tool-1",
                .tool_name = "get_weather",
                .content = &[_]types.ContentBlock{
                    .{ .text = .{ .text = "Sunny" } },
                    .{ .image = .{ .data = "aGVsbG8=", .mime_type = "image/png" } },
                },
                .timestamp = 3,
            } },
        },
    };

    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Gemini 2.5 Pro",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer freeJsonValue(allocator, payload);

    const contents = payload.object.get("contents").?;
    try std.testing.expect(contents == .array);
    try std.testing.expectEqual(@as(usize, 2), contents.array.items.len);

    const assistant_message = contents.array.items[0];
    try std.testing.expectEqualStrings("model", assistant_message.object.get("role").?.string);
    const assistant_parts = assistant_message.object.get("parts").?.array;
    try std.testing.expectEqual(@as(usize, 3), assistant_parts.items.len);
    try std.testing.expect(assistant_parts.items[0].object.get("thought") != null);
    try std.testing.expect(assistant_parts.items[2].object.get("functionCall") != null);

    const tool_result_message = contents.array.items[1];
    try std.testing.expectEqualStrings("user", tool_result_message.object.get("role").?.string);
    const tool_result_parts = tool_result_message.object.get("parts").?.array;
    try std.testing.expectEqual(@as(usize, 1), tool_result_parts.items.len);
    const function_response = tool_result_parts.items[0].object.get("functionResponse").?;
    try std.testing.expect(function_response == .object);
    try std.testing.expect(function_response.object.get("parts") != null);
}

test "parse stream emits text events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hello\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":5,\"totalTokenCount\":15}}\n" ++
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
        .id = "gemini-2.5-flash",
        .name = "Gemini 2.5 Flash",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
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
}

test "parse stream emits thinking and tool call events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"thought\":true,\"text\":\"Need tool\"},{\"functionCall\":{\"name\":\"get_weather\",\"args\":{\"city\":\"Berlin\"}}}],\"role\":\"model\"},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":20,\"cachedContentTokenCount\":2,\"candidatesTokenCount\":7,\"thoughtsTokenCount\":3,\"totalTokenCount\":30}}\n" ++
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
        .id = "gemini-2.5-pro",
        .name = "Gemini 2.5 Pro",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream_instance.next().?.event_type);
    const thinking_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.thinking_delta, thinking_delta.event_type);
    try std.testing.expectEqualStrings("Need tool", thinking_delta.delta.?);
    try std.testing.expectEqual(types.EventType.thinking_end, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream_instance.next().?.event_type);
    const tool_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta.event_type);
    try std.testing.expect(std.mem.indexOf(u8, tool_delta.delta.?, "Berlin") != null);
    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqualStrings("get_weather", tool_end.tool_call.?.name);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(u32, 18), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 10), done.message.?.usage.output);
}
