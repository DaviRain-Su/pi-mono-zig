const std = @import("std");
const types = @import("../../types.zig");
const http_client = @import("../../http_client.zig");
const env_api_keys = @import("../../env_api_keys.zig");
const provider_json = @import("../../shared/provider_json.zig");
const provider_stream = @import("../../shared/provider_stream.zig");
const chat_payload = @import("../openai_chat_payload.zig");

const request_path = "/chat/completions";

pub fn generateImagesOpenRouter(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.ImagesModel,
    context: types.ImagesContext,
    options: ?types.ImagesOptions,
) !types.AssistantImages {
    var output = try emptyImages(allocator, model);
    errdefer types.freeAssistantImages(allocator, output);

    const provided_api_key = if (options) |opts| opts.api_key else null;
    var env_api_key: ?[]u8 = null;
    defer if (env_api_key) |key| allocator.free(key);
    if (provided_api_key == null or provided_api_key.?.len == 0) {
        env_api_key = try env_api_keys.getEnvApiKey(allocator, model.provider);
    }
    const api_key = provided_api_key orelse env_api_key;
    if (api_key == null or api_key.?.len == 0) {
        try setErrorMessage(allocator, &output, try std.fmt.allocPrint(allocator, "No API key available for provider: {s}", .{model.provider}));
        return output;
    }

    const payload = try buildParams(allocator, model, context);
    defer provider_json.freeValue(allocator, payload);

    var final_payload = payload;
    var final_payload_owned = false;
    defer if (final_payload_owned) provider_json.freeValue(allocator, final_payload);
    if (options) |opts| {
        if (opts.on_payload) |on_payload| {
            if (try on_payload(allocator, payload, model)) |next_payload| {
                final_payload = next_payload;
                final_payload_owned = true;
            }
        }
    }

    var json_out: std.Io.Writer.Allocating = .init(allocator);
    defer json_out.deinit();
    try std.json.Stringify.value(final_payload, .{}, &json_out.writer);

    var headers = try buildRequestHeaders(allocator, model, api_key.?, options);
    defer provider_stream.deinitOwnedHeaders(allocator, &headers);

    const request_url = try buildRequestUrl(allocator, model.base_url);
    defer allocator.free(request_url);

    var client = try http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    var response = client.requestStreaming(.{
        .method = .POST,
        .url = request_url,
        .headers = headers,
        .body = json_out.written(),
        .timeout_ms = if (options) |opts| opts.timeout_ms orelse 0 else 0,
        .aborted = if (options) |opts| opts.signal else null,
    }) catch |err| {
        try setRuntimeError(allocator, &output, options, err);
        return output;
    };
    defer response.deinit();

    if (options) |opts| {
        if (opts.on_response) |on_response| {
            try invokeOnImagesResponse(allocator, on_response, response.status, response.response_headers, model);
        }
    }

    const body = response.readAllBounded(allocator, http_client.max_response_body_bytes) catch |err| {
        try setRuntimeError(allocator, &output, options, err);
        return output;
    };
    defer allocator.free(body);

    if (response.status < 200 or response.status >= 300) {
        try setErrorMessage(allocator, &output, try httpStatusMessage(allocator, response.status, body));
        return output;
    }

    output = parseResponseIntoOutput(allocator, model, body, output) catch |err| {
        try setRuntimeError(allocator, &output, options, err);
        return output;
    };
    return output;
}

fn emptyImages(allocator: std.mem.Allocator, model: types.ImagesModel) !types.AssistantImages {
    return .{
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .output = try allocator.alloc(types.ImagesOutputContent, 0),
        .stop_reason = .stop,
        .timestamp = 0,
    };
}

fn setRuntimeError(
    allocator: std.mem.Allocator,
    output: *types.AssistantImages,
    options: ?types.ImagesOptions,
    err: anyerror,
) !void {
    const stop_reason: types.ImagesStopReason = if (isAbortRequested(options)) .aborted else .@"error";
    output.stop_reason = stop_reason;
    const message = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
    if (output.error_message) |existing| allocator.free(existing);
    output.error_message = message;
}

fn setErrorMessage(allocator: std.mem.Allocator, output: *types.AssistantImages, owned_message: []const u8) !void {
    if (output.error_message) |existing| allocator.free(existing);
    output.stop_reason = .@"error";
    output.error_message = owned_message;
}

fn isAbortRequested(options: ?types.ImagesOptions) bool {
    const signal = if (options) |opts| opts.signal else null;
    return signal != null and signal.?.load(types.abort_signal_load_order);
}

fn buildRequestUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    var end = base_url.len;
    while (end > 0 and base_url[end - 1] == '/') : (end -= 1) {}
    const trimmed = base_url[0..end];
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, request_path });
}

fn buildRequestHeaders(
    allocator: std.mem.Allocator,
    model: types.ImagesModel,
    api_key: []const u8,
    options: ?types.ImagesOptions,
) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer provider_stream.deinitOwnedHeaders(allocator, &headers);

    try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "content-type", "application/json");
    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(authorization);
    try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "authorization", authorization);
    try provider_stream.mergeHeadersCaseInsensitive(allocator, &headers, model.headers);
    if (options) |opts| try provider_stream.mergeHeadersCaseInsensitive(allocator, &headers, opts.headers);
    return headers;
}

fn buildParams(allocator: std.mem.Allocator, model: types.ImagesModel, context: types.ImagesContext) !std.json.Value {
    var root = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = root });

    try putOwnedValue(allocator, &root, "model", .{ .string = try allocator.dupe(u8, model.id) });

    var messages = std.json.Array.init(allocator);
    errdefer provider_json.freeValue(allocator, .{ .array = messages });
    var user_message = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = user_message });
    try putOwnedValue(allocator, &user_message, "role", .{ .string = try allocator.dupe(u8, "user") });
    try putOwnedValue(allocator, &user_message, "content", try buildContentParts(allocator, context));
    try appendOwnedValue(allocator, &messages, .{ .object = user_message });
    try putOwnedValue(allocator, &root, "messages", .{ .array = messages });

    try putOwnedValue(allocator, &root, "stream", .{ .bool = false });
    try putOwnedValue(allocator, &root, "modalities", try buildModalities(allocator, model));
    return .{ .object = root };
}

fn buildContentParts(allocator: std.mem.Allocator, context: types.ImagesContext) !std.json.Value {
    var content = std.json.Array.init(allocator);
    errdefer provider_json.freeValue(allocator, .{ .array = content });

    for (context.input) |item| {
        var part = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = part });

        switch (item) {
            .text => |text| {
                const sanitized = try chat_payload.sanitizeSurrogates(allocator, text.text);
                errdefer allocator.free(sanitized);
                try putOwnedValue(allocator, &part, "type", .{ .string = try allocator.dupe(u8, "text") });
                try putOwnedValue(allocator, &part, "text", .{ .string = sanitized });
            },
            .image => |image| {
                var image_url = try provider_json.initObject(allocator);
                errdefer provider_json.freeValue(allocator, .{ .object = image_url });
                const data_url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ image.mime_type, image.data });
                errdefer allocator.free(data_url);
                try putOwnedValue(allocator, &image_url, "url", .{ .string = data_url });
                try putOwnedValue(allocator, &part, "type", .{ .string = try allocator.dupe(u8, "image_url") });
                try putOwnedValue(allocator, &part, "image_url", .{ .object = image_url });
            },
        }

        try appendOwnedValue(allocator, &content, .{ .object = part });
    }
    return .{ .array = content };
}

fn buildModalities(allocator: std.mem.Allocator, model: types.ImagesModel) !std.json.Value {
    var modalities = std.json.Array.init(allocator);
    errdefer provider_json.freeValue(allocator, .{ .array = modalities });
    try appendOwnedValue(allocator, &modalities, .{ .string = try allocator.dupe(u8, "image") });
    if (containsString(model.output, "text")) {
        try appendOwnedValue(allocator, &modalities, .{ .string = try allocator.dupe(u8, "text") });
    }
    return .{ .array = modalities };
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn putOwnedValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    errdefer provider_json.freeValue(allocator, value);
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try object.put(allocator, owned_key, value);
}

fn appendOwnedValue(allocator: std.mem.Allocator, array: *std.json.Array, value: std.json.Value) !void {
    errdefer provider_json.freeValue(allocator, value);
    try array.append(value);
}

fn parseResponseIntoOutput(
    allocator: std.mem.Allocator,
    model: types.ImagesModel,
    body: []const u8,
    existing: types.AssistantImages,
) !types.AssistantImages {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    var output = existing;
    if (parsed.value != .object) return error.InvalidImagesResponse;
    const object = parsed.value.object;

    if (object.get("id")) |id_value| {
        if (id_value == .string) output.response_id = try allocator.dupe(u8, id_value.string);
    }

    if (object.get("usage")) |usage_value| {
        if (usage_value == .object) output.usage = parseUsage(usage_value.object, model);
    }

    var contents: std.ArrayList(types.ImagesOutputContent) = .empty;
    errdefer {
        for (contents.items) |content| types.freeImagesContent(allocator, content);
        contents.deinit(allocator);
    }

    if (firstChoiceMessage(object)) |message| {
        if (message.get("content")) |content_value| {
            if (content_value == .string and content_value.string.len > 0) {
                try contents.append(allocator, .{ .text = .{ .text = try allocator.dupe(u8, content_value.string) } });
            }
        }
        if (message.get("images")) |images_value| {
            if (images_value == .array) {
                for (images_value.array.items) |image_value| {
                    if (try parseImageContent(allocator, image_value)) |image| {
                        try contents.append(allocator, .{ .image = image });
                    }
                }
            }
        }
    }

    allocator.free(output.output);
    output.output = try contents.toOwnedSlice(allocator);
    return output;
}

fn firstChoiceMessage(root: std.json.ObjectMap) ?std.json.ObjectMap {
    const choices_value = root.get("choices") orelse return null;
    if (choices_value != .array or choices_value.array.items.len == 0) return null;
    const choice = choices_value.array.items[0];
    if (choice != .object) return null;
    const message = choice.object.get("message") orelse return null;
    if (message != .object) return null;
    return message.object;
}

fn parseImageContent(allocator: std.mem.Allocator, value: std.json.Value) !?types.ImageContent {
    if (value != .object) return null;
    const image_url_value = value.object.get("image_url") orelse return null;
    const image_url = switch (image_url_value) {
        .string => |url| url,
        .object => |object| blk: {
            const url_value = object.get("url") orelse return null;
            if (url_value != .string) return null;
            break :blk url_value.string;
        },
        else => return null,
    };
    const parsed = parseDataImageUrl(image_url) orelse return null;
    return .{
        .mime_type = try allocator.dupe(u8, parsed.mime_type),
        .data = try allocator.dupe(u8, parsed.data),
    };
}

const ParsedDataImageUrl = struct {
    mime_type: []const u8,
    data: []const u8,
};

fn parseDataImageUrl(url: []const u8) ?ParsedDataImageUrl {
    const prefix = "data:";
    const marker = ";base64,";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const marker_index = std.mem.indexOf(u8, url, marker) orelse return null;
    const mime_type = url[prefix.len..marker_index];
    const data = url[marker_index + marker.len ..];
    if (mime_type.len == 0 or data.len == 0) return null;
    return .{ .mime_type = mime_type, .data = data };
}

fn parseUsage(raw: std.json.ObjectMap, model: types.ImagesModel) types.Usage {
    const prompt_tokens = jsonU32(raw.get("prompt_tokens"));
    const completion_tokens = jsonU32(raw.get("completion_tokens"));
    const details_value = raw.get("prompt_tokens_details");
    const details = if (details_value != null and details_value.? == .object) details_value.?.object else null;
    const reported_cached_tokens = if (details) |d| jsonU32(d.get("cached_tokens")) else 0;
    const cache_write_tokens = if (details) |d| jsonU32(d.get("cache_write_tokens")) else 0;
    const cache_read_tokens = if (cache_write_tokens > 0)
        if (reported_cached_tokens > cache_write_tokens) reported_cached_tokens - cache_write_tokens else 0
    else
        reported_cached_tokens;
    const input = if (prompt_tokens > cache_read_tokens + cache_write_tokens)
        prompt_tokens - cache_read_tokens - cache_write_tokens
    else
        0;

    var usage = types.Usage{
        .input = input,
        .output = completion_tokens,
        .cache_read = cache_read_tokens,
        .cache_write = cache_write_tokens,
        .total_tokens = input + completion_tokens + cache_read_tokens + cache_write_tokens,
        .cost = .{
            .input = (model.cost.input / 1_000_000.0) * @as(f64, @floatFromInt(input)),
            .output = (model.cost.output / 1_000_000.0) * @as(f64, @floatFromInt(completion_tokens)),
            .cache_read = (model.cost.cache_read / 1_000_000.0) * @as(f64, @floatFromInt(cache_read_tokens)),
            .cache_write = (model.cost.cache_write / 1_000_000.0) * @as(f64, @floatFromInt(cache_write_tokens)),
            .total = 0,
        },
    };
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
    return usage;
}

fn jsonU32(value: ?std.json.Value) u32 {
    const item = value orelse return 0;
    return switch (item) {
        .integer => |integer| if (integer > 0) @intCast(integer) else 0,
        .float => |float| if (float > 0) @intFromFloat(float) else 0,
        else => 0,
    };
}

fn httpStatusMessage(allocator: std.mem.Allocator, status: u16, body: []const u8) ![]const u8 {
    const max_body_len: usize = 1024;
    const preview = body[0..@min(body.len, max_body_len)];
    if (preview.len == 0) return std.fmt.allocPrint(allocator, "HTTP {d}", .{status});
    return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, preview });
}

fn invokeOnImagesResponse(
    allocator: std.mem.Allocator,
    callback: *const fn (u16, std.StringHashMap([]const u8), types.ImagesModel) anyerror!void,
    status: u16,
    maybe_headers: ?std.StringHashMap([]const u8),
    model: types.ImagesModel,
) !void {
    var response_headers = try provider_stream.normalizedResponseHeaders(allocator, maybe_headers);
    defer provider_stream.deinitOwnedHeaders(allocator, &response_headers);
    try callback(status, response_headers, model);
}

test "OpenRouter image payload mirrors TS request shape" {
    const allocator = std.testing.allocator;
    const input = [_]types.ImagesInputContent{
        .{ .text = .{ .text = "draw" } },
        .{ .image = .{ .mime_type = "image/png", .data = "abc" } },
    };
    const model = types.ImagesModel{
        .id = "openrouter/auto",
        .name = "Auto Router",
        .api = "openrouter-images",
        .provider = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .input = &[_][]const u8{ "text", "image" },
        .output = &[_][]const u8{ "image", "text" },
    };
    const payload = try buildParams(allocator, model, .{ .input = &input });
    defer provider_json.freeValue(allocator, payload);

    const object = payload.object;
    try std.testing.expectEqualStrings("openrouter/auto", object.get("model").?.string);
    try std.testing.expectEqual(false, object.get("stream").?.bool);
    try std.testing.expectEqual(@as(usize, 2), object.get("modalities").?.array.items.len);
    try std.testing.expectEqualStrings("text", object.get("messages").?.array.items[0].object.get("content").?.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("data:image/png;base64,abc", object.get("messages").?.array.items[0].object.get("content").?.array.items[1].object.get("image_url").?.object.get("url").?.string);
}

test "OpenRouter image response parser extracts text images and usage" {
    const allocator = std.testing.allocator;
    const model = types.ImagesModel{
        .id = "openrouter/auto",
        .name = "Auto Router",
        .api = "openrouter-images",
        .provider = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .input = &[_][]const u8{ "text", "image" },
        .output = &[_][]const u8{ "image", "text" },
        .cost = .{ .input = 10, .output = 20, .cache_read = 1, .cache_write = 2 },
    };
    var output = try emptyImages(allocator, model);
    const body =
        \\{"id":"resp_1","usage":{"prompt_tokens":12,"completion_tokens":4,"prompt_tokens_details":{"cached_tokens":5,"cache_write_tokens":2}},"choices":[{"message":{"content":"caption","images":[{"image_url":{"url":"data:image/png;base64,abc"}}]}}]}
    ;
    output = try parseResponseIntoOutput(allocator, model, body, output);
    defer types.freeAssistantImages(allocator, output);
    try std.testing.expectEqualStrings("resp_1", output.response_id.?);
    try std.testing.expectEqual(@as(usize, 2), output.output.len);
    try std.testing.expectEqualStrings("caption", output.output[0].text.text);
    try std.testing.expectEqualStrings("image/png", output.output[1].image.mime_type);
    try std.testing.expectEqualStrings("abc", output.output[1].image.data);
    try std.testing.expectEqual(@as(u32, 7), output.usage.?.input);
    try std.testing.expectEqual(@as(u32, 4), output.usage.?.output);
    try std.testing.expectEqual(@as(u32, 3), output.usage.?.cache_read);
    try std.testing.expectEqual(@as(u32, 2), output.usage.?.cache_write);
}
