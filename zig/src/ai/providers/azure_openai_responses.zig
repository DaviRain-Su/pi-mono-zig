const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");
const env_api_keys = @import("../env_api_keys.zig");
const provider_error = @import("../shared/provider_error.zig");
const openai = @import("openai.zig");
const openai_responses = @import("openai_responses.zig");

const DEFAULT_AZURE_API_VERSION = "v1";
const AZURE_BASE_URL_ENV = "AZURE_OPENAI_BASE_URL";
const AZURE_RESOURCE_NAME_ENV = "AZURE_OPENAI_RESOURCE_NAME";
const AZURE_API_VERSION_ENV = "AZURE_OPENAI_API_VERSION";
const AZURE_DEPLOYMENT_MAP_ENV = "AZURE_OPENAI_DEPLOYMENT_NAME_MAP";

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

const OwnedHeader = struct {
    name: []const u8,
    value: []const u8,

    fn deinit(self: OwnedHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

pub const AzureOpenAIResponsesProvider = struct {
    pub const api = "azure-openai-responses";

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
        errdefer stream_instance.deinit();

        const deployment_name = resolveDeploymentName(allocator, model.id, options) catch |err| {
            return emitProviderError(allocator, &stream_instance, model, err);
        };
        defer allocator.free(deployment_name);

        var request_model = model;
        request_model.id = deployment_name;

        var payload = buildAzureRequestPayload(allocator, request_model, context, options) catch |err| {
            return emitProviderError(allocator, &stream_instance, model, err);
        };
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

        const base_url = resolveAzureBaseUrl(allocator, model, options) catch |err| {
            return emitProviderError(allocator, &stream_instance, model, err);
        };
        defer allocator.free(base_url);

        const api_version = resolveAzureApiVersion(allocator, options) catch |err| {
            return emitProviderError(allocator, &stream_instance, model, err);
        };
        defer if (api_version.owned) allocator.free(api_version.value);

        const url = buildRequestUrl(allocator, base_url, api_version.value) catch |err| {
            return emitProviderError(allocator, &stream_instance, model, err);
        };
        defer allocator.free(url);

        var headers = std.StringHashMap([]const u8).init(allocator);
        defer deinitOwnedHeaders(allocator, &headers);
        try putOwnedHeader(allocator, &headers, "Content-Type", "application/json");
        try putOwnedHeader(allocator, &headers, "Accept", "application/json");
        try mergeHeaders(allocator, &headers, model.headers);
        if (options) |stream_options| {
            try mergeHeaders(allocator, &headers, stream_options.headers);
        }

        const auth = resolveAzureAuthHeader(allocator, options) catch |err| {
            return emitProviderError(allocator, &stream_instance, model, err);
        };
        defer auth.deinit(allocator);
        try putOwnedHeader(allocator, &headers, auth.name, auth.value);

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
                    try callback(response.status, response_headers, model);
                } else {
                    var response_headers = std.StringHashMap([]const u8).init(allocator);
                    defer response_headers.deinit();
                    try callback(response.status, response_headers, model);
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

fn buildAzureRequestPayload(
    allocator: std.mem.Allocator,
    request_model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    var payload = try openai_responses.buildRequestPayload(allocator, request_model, context, options);
    errdefer freeJsonValue(allocator, payload);

    try removeObjectField(allocator, &payload, "store");
    try removeObjectField(allocator, &payload, "prompt_cache_retention");
    try removeObjectField(allocator, &payload, "service_tier");
    try removeObjectField(allocator, &payload, "metadata");

    if (options) |stream_options| {
        if (stream_options.session_id) |session_id| {
            try removeObjectField(allocator, &payload, "prompt_cache_key");
            if (payload == .object) {
                try payload.object.put(
                    allocator,
                    try allocator.dupe(u8, "prompt_cache_key"),
                    .{ .string = try allocator.dupe(u8, session_id) },
                );
            }
        }
    }

    return payload;
}

const ResolvedApiVersion = struct {
    value: []const u8,
    owned: bool,
};

fn emitProviderError(
    allocator: std.mem.Allocator,
    stream_instance: *event_stream.AssistantMessageEventStream,
    model: types.Model,
    err: anyerror,
) !event_stream.AssistantMessageEventStream {
    const error_message = try allocator.dupe(u8, @errorName(err));
    return emitErrorMessage(allocator, stream_instance, model, error_message);
}

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

fn resolveDeploymentName(allocator: std.mem.Allocator, model_id: []const u8, options: ?types.StreamOptions) ![]const u8 {
    if (options) |stream_options| {
        if (stream_options.azure_deployment_name) |deployment_name| {
            if (deployment_name.len > 0) return try allocator.dupe(u8, deployment_name);
        }
    }

    const env_value = try loadEnvOptional(allocator, AZURE_DEPLOYMENT_MAP_ENV);
    defer if (env_value) |value| allocator.free(value);

    if (env_value) |value| {
        var entries = std.mem.splitScalar(u8, value, ',');
        while (entries.next()) |entry| {
            const trimmed = std.mem.trim(u8, entry, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |separator_index| {
                const lhs = std.mem.trim(u8, trimmed[0..separator_index], " \t\r\n");
                const rhs = std.mem.trim(u8, trimmed[separator_index + 1 ..], " \t\r\n");
                if (lhs.len == 0 or rhs.len == 0) continue;
                if (std.mem.eql(u8, lhs, model_id)) return try allocator.dupe(u8, rhs);
            }
        }
    }

    return try allocator.dupe(u8, model_id);
}

fn resolveAzureBaseUrl(allocator: std.mem.Allocator, model: types.Model, options: ?types.StreamOptions) ![]const u8 {
    if (options) |stream_options| {
        if (stream_options.azure_base_url) |value| {
            if (std.mem.trim(u8, value, " \t\r\n").len > 0) {
                return try normalizeAzureBaseUrl(allocator, value);
            }
        }
    }

    const env_base_url = try loadEnvOptional(allocator, AZURE_BASE_URL_ENV);
    defer if (env_base_url) |value| allocator.free(value);
    if (env_base_url) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len > 0) {
            return try normalizeAzureBaseUrl(allocator, value);
        }
    }

    if (options) |stream_options| {
        if (stream_options.azure_resource_name) |value| {
            const resource_name = std.mem.trim(u8, value, " \t\r\n");
            if (resource_name.len > 0) {
                return try std.fmt.allocPrint(allocator, "https://{s}.openai.azure.com/openai/v1", .{resource_name});
            }
        }
    }

    const env_resource_name = try loadEnvOptional(allocator, AZURE_RESOURCE_NAME_ENV);
    defer if (env_resource_name) |value| allocator.free(value);
    if (env_resource_name) |value| {
        const resource_name = std.mem.trim(u8, value, " \t\r\n");
        if (resource_name.len > 0) {
            return try std.fmt.allocPrint(allocator, "https://{s}.openai.azure.com/openai/v1", .{resource_name});
        }
    }

    if (std.mem.trim(u8, model.base_url, " \t\r\n").len > 0) {
        return try normalizeAzureBaseUrl(allocator, model.base_url);
    }

    return error.MissingAzureBaseUrl;
}

fn resolveAzureApiVersion(allocator: std.mem.Allocator, options: ?types.StreamOptions) !ResolvedApiVersion {
    if (options) |stream_options| {
        if (stream_options.azure_api_version) |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len > 0) return .{ .value = trimmed, .owned = false };
        }
    }

    const env_api_version = try loadEnvOptional(allocator, AZURE_API_VERSION_ENV);
    if (env_api_version) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) {
            allocator.free(value);
        } else if (trimmed.ptr == value.ptr and trimmed.len == value.len) {
            return .{ .value = value, .owned = true };
        } else {
            const owned = try allocator.dupe(u8, trimmed);
            allocator.free(value);
            return .{ .value = owned, .owned = true };
        }
    }
    return .{ .value = DEFAULT_AZURE_API_VERSION, .owned = false };
}

fn normalizeAzureBaseUrl(allocator: std.mem.Allocator, raw_base_url: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, raw_base_url, " \t\r\n"), "/");
    if (trimmed.len == 0) return error.MissingAzureBaseUrl;
    const uri = std.Uri.parse(trimmed) catch return error.InvalidAzureBaseUrl;
    const host = uri.host orelse return error.InvalidAzureBaseUrl;
    const host_text = host.percent_encoded;
    const path_text = uri.path.percent_encoded;
    const normalized_path = std.mem.trimEnd(u8, path_text, "/");
    const is_azure_host = std.mem.endsWith(u8, host_text, ".openai.azure.com") or
        std.mem.endsWith(u8, host_text, ".cognitiveservices.azure.com");

    if (is_azure_host and (normalized_path.len == 0 or std.mem.eql(u8, normalized_path, "/") or std.mem.eql(u8, normalized_path, "/openai"))) {
        return try std.fmt.allocPrint(allocator, "{s}://{s}/openai/v1", .{ uri.scheme, host_text });
    }

    return try allocator.dupe(u8, trimmed);
}

fn buildRequestUrl(allocator: std.mem.Allocator, raw_base_url: []const u8, api_version: []const u8) ![]const u8 {
    const base_url = try normalizeAzureBaseUrl(allocator, raw_base_url);
    defer allocator.free(base_url);

    if (std.mem.indexOfScalar(u8, base_url, '?')) |query_index| {
        return try std.fmt.allocPrint(
            allocator,
            "{s}?api-version={s}",
            .{ base_url[0..query_index], api_version },
        );
    }
    return try std.fmt.allocPrint(allocator, "{s}/responses?api-version={s}", .{ base_url, api_version });
}

fn resolveAzureAuthHeader(allocator: std.mem.Allocator, options: ?types.StreamOptions) !OwnedHeader {
    const provided = if (options) |stream_options| stream_options.api_key else null;

    var env_api_key: ?[]u8 = null;
    defer if (env_api_key) |value| allocator.free(value);
    if (provided == null) {
        env_api_key = try env_api_keys.getEnvApiKey(allocator, "azure-openai-responses");
    }

    return resolveAuthHeaderValue(allocator, provided, env_api_key);
}

fn resolveAuthHeaderValue(
    allocator: std.mem.Allocator,
    provided_auth: ?[]const u8,
    env_api_key: ?[]const u8,
) !OwnedHeader {
    if (provided_auth) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len > 0) {
            return .{
                .name = try allocator.dupe(u8, "api-key"),
                .value = try allocator.dupe(u8, trimmed),
            };
        }
    }

    if (env_api_key) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len > 0) {
            return .{
                .name = try allocator.dupe(u8, "api-key"),
                .value = try allocator.dupe(u8, trimmed),
            };
        }
    }

    return error.MissingAzureCredentials;
}

fn loadEnvOptional(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);

    const value = std.c.getenv(name_z) orelse return null;
    return try allocator.dupe(u8, std.mem.span(value));
}

fn putOwnedHeader(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    name: []const u8,
    value: []const u8,
) !void {
    var existing_name: ?[]const u8 = null;
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
            existing_name = entry.key_ptr.*;
            break;
        }
    }
    if (existing_name) |key| {
        if (headers.fetchRemove(key)) |removed| {
            allocator.free(removed.key);
            allocator.free(removed.value);
        }
    }
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
                const extracted_text = try extractMessageText(allocator, maybe_item_value);
                defer if (extracted_text) |final_text| allocator.free(final_text);
                const owned = if (extracted_text) |final_text|
                    try allocator.dupe(u8, final_text)
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
                const extracted_text = try extractReasoningSummary(allocator, maybe_item_value);
                defer if (extracted_text) |final_text| allocator.free(final_text);
                const owned = if (extracted_text) |final_text|
                    try allocator.dupe(u8, final_text)
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

fn isAbortRequested(options: ?types.StreamOptions) bool {
    if (options) |stream_options| {
        if (stream_options.signal) |signal| return signal.load(.seq_cst);
    }
    return false;
}

fn removeObjectField(allocator: std.mem.Allocator, payload: *std.json.Value, field_name: []const u8) !void {
    if (payload.* != .object) return;

    var old_object = payload.object;
    var new_object = try initObject(allocator);
    errdefer new_object.deinit(allocator);

    var iterator = old_object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, field_name)) {
            allocator.free(entry.key_ptr.*);
            freeJsonValue(allocator, entry.value_ptr.*);
            continue;
        }
        try new_object.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    old_object.deinit(allocator);
    payload.* = .{ .object = new_object };
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

test "buildRequestUrl normalizes Azure resource endpoints" {
    const allocator = std.testing.allocator;
    const url = try buildRequestUrl(allocator, "https://example.openai.azure.com/", "v1");
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://example.openai.azure.com/openai/v1/responses?api-version=v1",
        url,
    );
}

test "buildRequestUrl appends api-version for dated Azure APIs" {
    const allocator = std.testing.allocator;
    const url = try buildRequestUrl(allocator, "https://example.openai.azure.com/openai/v1", "2025-03-01-preview");
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://example.openai.azure.com/openai/v1/responses?api-version=2025-03-01-preview",
        url,
    );
}

test "resolveAuthHeaderValue prefers api-key for plain credentials" {
    const allocator = std.testing.allocator;
    const auth = try resolveAuthHeaderValue(allocator, "azure-key", null);
    defer auth.deinit(allocator);

    try std.testing.expectEqualStrings("api-key", auth.name);
    try std.testing.expectEqualStrings("azure-key", auth.value);
}

test "resolveAuthHeaderValue treats bearer-looking credentials as Azure API keys" {
    const allocator = std.testing.allocator;
    const auth = try resolveAuthHeaderValue(allocator, "Bearer entra-token", null);
    defer auth.deinit(allocator);

    try std.testing.expectEqualStrings("api-key", auth.name);
    try std.testing.expectEqualStrings("Bearer entra-token", auth.value);
}

test "extractMessageText uses caller allocator" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"},{\"type\":\"refusal\",\"refusal\":\" Azure\"}]}",
        .{},
    );
    defer parsed.deinit();

    const text = (try extractMessageText(allocator, parsed.value)).?;
    defer allocator.free(text);

    try std.testing.expectEqualStrings("Hello Azure", text);
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

test "parseSseStreamLines emits Azure text events" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_azure\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello Azure\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello Azure\"}]}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_azure\",\"status\":\"completed\",\"usage\":{\"input_tokens\":2,\"output_tokens\":2,\"total_tokens\":4}}}\n" ++
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
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .base_url = "https://example.openai.azure.com",
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
    try std.testing.expectEqualStrings("Hello Azure", event3.delta.?);

    const event4 = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, event4.event_type);
    try std.testing.expectEqualStrings("Hello Azure", event4.content.?);

    const event5 = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, event5.event_type);
    try std.testing.expect(event5.message != null);
    try std.testing.expectEqualStrings("resp_azure", event5.message.?.response_id.?);
    try std.testing.expectEqualStrings("Hello Azure", event5.message.?.content[0].text.text);

    freeAssistantMessageOwned(allocator, event5.message.?);
}

test "parseSseStreamLines emits Azure reasoning events without leaks" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_reasoning\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[]}}\n" ++
            "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"first\"}\n" ++
            "data: {\"type\":\"response.reasoning_summary_part.done\"}\n" ++
            "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"second\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"text\":\"first\"},{\"text\":\"second\"}]}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_reasoning\",\"status\":\"completed\",\"usage\":{\"input_tokens\":2,\"output_tokens\":2,\"total_tokens\":4}}}\n" ++
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
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .base_url = "https://example.openai.azure.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    const event1 = stream.next().?;
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream.next().?;
    try std.testing.expectEqual(types.EventType.thinking_start, event2.event_type);

    const event3 = stream.next().?;
    defer freeEventOwned(allocator, event3);
    try std.testing.expectEqual(types.EventType.thinking_delta, event3.event_type);
    try std.testing.expectEqualStrings("first", event3.delta.?);

    const event4 = stream.next().?;
    defer freeEventOwned(allocator, event4);
    try std.testing.expectEqual(types.EventType.thinking_delta, event4.event_type);
    try std.testing.expectEqualStrings("\n\n", event4.delta.?);

    const event5 = stream.next().?;
    defer freeEventOwned(allocator, event5);
    try std.testing.expectEqual(types.EventType.thinking_delta, event5.event_type);
    try std.testing.expectEqualStrings("second", event5.delta.?);

    const event6 = stream.next().?;
    try std.testing.expectEqual(types.EventType.thinking_end, event6.event_type);
    try std.testing.expectEqualStrings("first\n\nsecond", event6.content.?);

    const event7 = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, event7.event_type);
    try std.testing.expect(event7.message != null);
    try std.testing.expectEqualStrings("first\n\nsecond", event7.message.?.content[0].thinking.thinking);

    freeAssistantMessageOwned(allocator, event7.message.?);
}

test "stream HTTP status error is terminal sanitized event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"error\":{\"message\":\"azure denied\",\"api_key\":\"sk-azure-secret\",\"request_id\":\"req_azure_random_123456\"},\"trace\":\"/Users/alice/pi/azure_openai_responses.zig\"}");
    try body.appendNTimes(allocator, 'x', 900);

    var server = try provider_error.TestStatusServer.init(io, 429, "Too Many Requests", "", body.items);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
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

    var stream = try AzureOpenAIResponsesProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 429: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "azure denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "[truncated]") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "sk-azure-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_azure_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("azure-openai-responses", result.api);
}
