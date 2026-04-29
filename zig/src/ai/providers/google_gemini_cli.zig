const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");
const provider_error = @import("../shared/provider_error.zig");

const DEFAULT_BASE_URL = "https://cloudcode-pa.googleapis.com";
const GEMINI_CLI_CLIENT_METADATA =
    "{\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"}";
var request_counter: usize = 0;

const AuthCredentials = struct {
    token: []const u8,
    project_id: []const u8,
};

pub const GoogleGeminiCliProvider = struct {
    pub const api = "google-gemini-cli";

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
        errdefer stream_instance.deinit();

        const auth = resolveAuthCredentials(allocator, if (options) |stream_options| stream_options.api_key else null) catch |err| {
            try emitAuthError(allocator, &stream_instance, model, authErrorMessage(err));
            return stream_instance;
        };
        defer {
            allocator.free(auth.token);
            allocator.free(auth.project_id);
        }

        var payload = try buildRequestPayload(allocator, model, context, auth.project_id, options);
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

        const url = try buildRequestUrl(allocator, model);
        defer allocator.free(url);

        var headers = std.StringHashMap([]const u8).init(allocator);
        defer headers.deinit();
        try headers.put("Authorization", try std.fmt.allocPrint(allocator, "Bearer {s}", .{auth.token}));
        try headers.put("Content-Type", "application/json");
        try headers.put("Accept", "text/event-stream");
        try headers.put("User-Agent", "google-cloud-sdk vscode_cloudshelleditor/0.1");
        try headers.put("X-Goog-Api-Client", "gl-node/22.17.0");
        try headers.put("Client-Metadata", GEMINI_CLI_CLIENT_METADATA);
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

const CurrentBlock = union(enum) {
    text: std.ArrayList(u8),
    thinking: struct {
        text: std.ArrayList(u8),
        signature: ?[]const u8,
    },
};

const CredentialError = error{
    MissingApiKey,
    InvalidApiKey,
    MissingTokenOrProjectId,
} || std.mem.Allocator.Error;

pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    project_id: []const u8,
    options: ?types.StreamOptions,
) !std.json.Value {
    var payload = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer payload.deinit(allocator);

    try payload.put(allocator, try allocator.dupe(u8, "project"), .{ .string = try allocator.dupe(u8, project_id) });
    try payload.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, model.id) });
    try payload.put(allocator, try allocator.dupe(u8, "request"), try buildInnerRequestValue(allocator, model, context, options));
    try payload.put(allocator, try allocator.dupe(u8, "userAgent"), .{ .string = try allocator.dupe(u8, "pi-coding-agent") });
    try payload.put(
        allocator,
        try allocator.dupe(u8, "requestId"),
        .{ .string = try nextRequestId(allocator) },
    );

    return .{ .object = payload };
}

fn buildInnerRequestValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    var request = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer request.deinit(allocator);

    try request.put(allocator, try allocator.dupe(u8, "contents"), try buildContentsValue(allocator, model, context.messages));

    if (options) |stream_options| {
        if (stream_options.session_id) |session_id| {
            try request.put(allocator, try allocator.dupe(u8, "sessionId"), .{ .string = try allocator.dupe(u8, session_id) });
        }
    }

    if (context.system_prompt) |system_prompt| {
        try request.put(allocator, try allocator.dupe(u8, "systemInstruction"), try buildSystemInstructionValue(allocator, system_prompt));
    }

    const generation_config = try buildGenerationConfigValue(allocator, model, options);
    errdefer freeJsonValue(allocator, generation_config);
    if (generation_config == .object and generation_config.object.count() > 0) {
        try request.put(allocator, try allocator.dupe(u8, "generationConfig"), generation_config);
    } else {
        freeJsonValue(allocator, generation_config);
    }

    if (context.tools) |tools| {
        if (tools.len > 0) {
            try request.put(allocator, try allocator.dupe(u8, "tools"), try buildToolsValue(allocator, tools));
            if (options) |stream_options| {
                if (stream_options.google_tool_choice) |tool_choice| {
                    try request.put(allocator, try allocator.dupe(u8, "toolConfig"), try buildToolConfigValue(allocator, tool_choice));
                }
            }
        }
    }

    return .{ .object = request };
}

fn buildRequestUrl(allocator: std.mem.Allocator, model: types.Model) ![]const u8 {
    const base_url = std.mem.trim(u8, model.base_url, " \t\r\n");
    const resolved_base_url = if (base_url.len > 0) base_url else DEFAULT_BASE_URL;
    return try std.fmt.allocPrint(allocator, "{s}/v1internal:streamGenerateContent?alt=sse", .{resolved_base_url});
}

fn resolveAuthCredentials(allocator: std.mem.Allocator, api_key: ?[]const u8) CredentialError!AuthCredentials {
    const raw = api_key orelse return error.MissingApiKey;
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return error.MissingApiKey;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return error.InvalidApiKey;
    defer parsed.deinit();
    const value = parsed.value;
    if (value != .object) return error.InvalidApiKey;

    const token_value = value.object.get("token") orelse return error.MissingTokenOrProjectId;
    const project_value = value.object.get("projectId") orelse return error.MissingTokenOrProjectId;
    if (token_value != .string or project_value != .string) return error.MissingTokenOrProjectId;
    if (token_value.string.len == 0 or project_value.string.len == 0) return error.MissingTokenOrProjectId;

    return .{
        .token = try allocator.dupe(u8, token_value.string),
        .project_id = try allocator.dupe(u8, project_value.string),
    };
}

fn authErrorMessage(err: CredentialError) []const u8 {
    return switch (err) {
        error.MissingApiKey => "Google Cloud Code Assist requires OAuth authentication. Use /login to authenticate.",
        error.InvalidApiKey => "Invalid Google Cloud Code Assist credentials. Use /login to re-authenticate.",
        error.MissingTokenOrProjectId => "Missing token or projectId in Google Cloud credentials. Use /login to re-authenticate.",
        error.OutOfMemory => "Out of memory while preparing Google Cloud Code Assist credentials.",
    };
}

fn emitAuthError(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
    message_text: []const u8,
) !void {
    const error_message = try allocator.dupe(u8, message_text);
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
    stream_ptr.push(.{
        .event_type = .error_event,
        .error_message = error_message,
        .message = message,
    });
    stream_ptr.end(message);
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

    var generated_tool_call_count: usize = 0;

    stream_ptr.push(.{ .event_type = .start });

    while (true) {
        const maybe_line = streaming.readLine() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try emitRuntimeFailure(allocator, stream_ptr, &output, &current_block, &content_blocks, &tool_calls, model, err);
                return;
            },
        };
        const line = maybe_line orelse break;
        if (isAbortRequested(options)) {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &current_block, &content_blocks, &tool_calls, model, error.RequestAborted);
            return;
        }

        const data = parseSseLine(std.mem.trim(u8, line, " \t\r")) orelse continue;
        if (std.mem.eql(u8, data, "[DONE]")) break;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try emitRuntimeFailure(allocator, stream_ptr, &output, &current_block, &content_blocks, &tool_calls, model, err);
                return;
            },
        };
        defer parsed.deinit();
        const value = parsed.value;
        if (value != .object) continue;

        const response_value = if (value.object.get("response")) |response|
            if (response == .object) response else continue
        else
            value;

        if (response_value.object.get("responseId")) |response_id| {
            if (response_id == .string and output.response_id == null) {
                output.response_id = try allocator.dupe(u8, response_id.string);
            }
        }

        if (response_value.object.get("usageMetadata")) |usage_metadata| {
            updateUsage(&output.usage, usage_metadata);
            calculateCost(model, &output.usage);
        }

        const candidates_value = response_value.object.get("candidates") orelse continue;
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

                                    const thought_signature = if (part.object.get("thoughtSignature")) |signature_value|
                                        if (signature_value == .string and signature_value.string.len > 0) try allocator.dupe(u8, signature_value.string) else null
                                    else
                                        null;

                                    const tool_call = types.ToolCall{
                                        .id = tool_call_id,
                                        .name = try allocator.dupe(u8, name_value.?.string),
                                        .arguments = args,
                                        .thought_signature = thought_signature,
                                    };
                                    try tool_calls.append(allocator, tool_call);
                                    try content_blocks.append(allocator, .{ .tool_call = .{
                                        .id = try allocator.dupe(u8, tool_call.id),
                                        .name = try allocator.dupe(u8, tool_call.name),
                                        .arguments = try cloneJsonValue(allocator, tool_call.arguments),
                                        .thought_signature = if (tool_call.thought_signature) |signature| try allocator.dupe(u8, signature) else null,
                                    } });

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

fn finalizeOutputFromPartials(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
) !void {
    try finishCurrentBlock(allocator, current_block, content_blocks, stream_ptr);
    calculateCost(model, &output.usage);
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
    model: types.Model,
    err: anyerror,
) !void {
    try finalizeOutputFromPartials(allocator, output, current_block, content_blocks, tool_calls, stream_ptr, model);
    output.stop_reason = provider_error.runtimeStopReason(err);
    output.error_message = provider_error.runtimeErrorMessage(err);
    provider_error.pushTerminalRuntimeError(stream_ptr, output.*);
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
                if (types.thinkingSignature(thinking)) |signature| {
                    try thought_part.put(allocator, try allocator.dupe(u8, "thoughtSignature"), .{ .string = try allocator.dupe(u8, signature) });
                }
                try parts.append(.{ .object = thought_part });
            },
            .image => {},
            .tool_call => |tool_call| {
                var function_call = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try function_call.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool_call.name) });
                try function_call.put(allocator, try allocator.dupe(u8, "args"), try cloneJsonValue(allocator, tool_call.arguments));

                var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                if (tool_call.thought_signature) |signature| {
                    try part.put(allocator, try allocator.dupe(u8, "thoughtSignature"), .{ .string = try allocator.dupe(u8, signature) });
                }
                try part.put(allocator, try allocator.dupe(u8, "functionCall"), .{ .object = function_call });
                try parts.append(.{ .object = part });
            },
        }
    }

    if (!types.hasInlineToolCalls(assistant)) {
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
            .thinking, .tool_call => {},
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
            .tool_call => {},
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
    return try std.fmt.allocPrint(allocator, "google-cli-call-{d}", .{counter.*});
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

fn extractErrorMessage(body: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    return if (trimmed.len == 0) body else trimmed;
}

fn nextRequestId(allocator: std.mem.Allocator) ![]const u8 {
    request_counter += 1;
    return try std.fmt.allocPrint(allocator, "pi-zig-{d}", .{request_counter});
}

test "buildRequestPayload wraps Gemini CLI request envelope and session auth fields" {
    const allocator = std.testing.allocator;

    const context = types.Context{
        .system_prompt = "You are helpful.",
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{
                    .{ .text = .{ .text = "Hello from user" } },
                },
                .timestamp = 1,
            } },
        },
    };

    const model = types.Model{
        .id = "gemini-2.5-flash",
        .name = "Gemini 2.5 Flash",
        .api = "google-gemini-cli",
        .provider = "google-gemini-cli",
        .base_url = "https://cloudcode-pa.googleapis.com",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    const payload = try buildRequestPayload(allocator, model, context, "project-123", .{
        .session_id = "session-42",
        .temperature = 0.25,
        .max_tokens = 2048,
        .google_tool_choice = "none",
        .google_thinking = .{
            .enabled = true,
            .budget_tokens = 512,
        },
    });
    defer freeJsonValue(allocator, payload);

    try std.testing.expectEqualStrings("project-123", payload.object.get("project").?.string);
    try std.testing.expectEqualStrings("gemini-2.5-flash", payload.object.get("model").?.string);
    try std.testing.expectEqualStrings("pi-coding-agent", payload.object.get("userAgent").?.string);
    try std.testing.expect(payload.object.get("requestId") != null);

    const request = payload.object.get("request").?;
    try std.testing.expect(request == .object);
    try std.testing.expectEqualStrings("session-42", request.object.get("sessionId").?.string);
    try std.testing.expect(request.object.get("contents") != null);
    try std.testing.expect(request.object.get("systemInstruction") != null);

    const generation_config = request.object.get("generationConfig").?;
    try std.testing.expect(generation_config == .object);
    try std.testing.expectEqual(@as(i64, 2048), generation_config.object.get("maxOutputTokens").?.integer);
    try std.testing.expect(generation_config.object.get("thinkingConfig") != null);
}

test "buildRequestUrl uses Gemini CLI endpoint format" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "gemini-2.5-flash",
        .name = "Gemini 2.5 Flash",
        .api = "google-gemini-cli",
        .provider = "google-gemini-cli",
        .base_url = "https://cloudcode-pa.googleapis.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    const url = try buildRequestUrl(allocator, model);
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse", url);
}

test "parse stream unwraps response envelope and emits Gemini CLI events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"response\":{\"responseId\":\"resp-123\",\"candidates\":[{\"content\":{\"parts\":[{\"thought\":true,\"text\":\"Need tool\",\"thoughtSignature\":\"c2ln\"},{\"functionCall\":{\"name\":\"get_weather\",\"args\":{\"city\":\"Berlin\"}}},{\"text\":\"It is sunny.\"}],\"role\":\"model\"},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":20,\"cachedContentTokenCount\":2,\"candidatesTokenCount\":7,\"thoughtsTokenCount\":3,\"totalTokenCount\":30}}}\n" ++
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
        .api = "google-gemini-cli",
        .provider = "google-gemini-cli",
        .base_url = "https://cloudcode-pa.googleapis.com",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_delta, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_end, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_delta, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_end, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);
    const text_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, text_delta.event_type);
    try std.testing.expectEqualStrings("It is sunny.", text_delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream_instance.next().?.event_type);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqualStrings("resp-123", done.message.?.response_id.?);
    try std.testing.expectEqual(@as(u32, 18), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 10), done.message.?.usage.output);
}

test "stream returns auth error when Gemini CLI credentials are missing or invalid" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const model = types.Model{
        .id = "gemini-2.5-flash",
        .name = "Gemini 2.5 Flash",
        .api = "google-gemini-cli",
        .provider = "google-gemini-cli",
        .base_url = "https://cloudcode-pa.googleapis.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    var missing = try GoogleGeminiCliProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, null);
    defer missing.deinit();
    const missing_error = missing.next().?;
    try std.testing.expectEqual(types.EventType.error_event, missing_error.event_type);
    try std.testing.expect(std.mem.indexOf(u8, missing_error.error_message.?, "OAuth authentication") != null);

    var invalid = try GoogleGeminiCliProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = "not-json",
    });
    defer invalid.deinit();
    const invalid_error = invalid.next().?;
    try std.testing.expectEqual(types.EventType.error_event, invalid_error.event_type);
    try std.testing.expect(std.mem.indexOf(u8, invalid_error.error_message.?, "Invalid Google Cloud Code Assist credentials") != null);
}

test "stream HTTP status error is terminal sanitized event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"error\":{\"message\":\"gemini cli denied\",\"authorization\":\"Bearer sk-gemini-cli-secret\",\"request_id\":\"req_gemini_cli_random_123456\"},\"trace\":\"/Users/alice/pi/google_gemini_cli.zig\"}");
    try body.appendNTimes(allocator, 'x', 900);

    var server = try provider_error.TestStatusServer.init(io, 401, "Unauthorized", "", body.items);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "gemini-2.5-flash",
        .name = "Gemini 2.5 Flash",
        .api = "google-gemini-cli",
        .provider = "google-gemini-cli",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try GoogleGeminiCliProvider.stream(allocator, io, model, context, .{
        .api_key = "{\"token\":\"cli-token\",\"projectId\":\"test-project\"}",
    });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 401: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "gemini cli denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "[truncated]") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "sk-gemini-cli-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_gemini_cli_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("google-gemini-cli", result.api);
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

test "parseSseStreamLines preserves partial Gemini CLI text before malformed terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"response\":{\"responseId\":\"gemini-cli-runtime\",\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"partial\"}]}}]}}\n" ++
            "data: {not-json}\n" ++
            "data: [DONE]\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("google-gemini-cli", "google"), null);

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
    try std.testing.expectEqualStrings("gemini-cli-runtime", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
}
