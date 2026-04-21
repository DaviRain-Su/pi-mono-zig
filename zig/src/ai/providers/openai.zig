const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");

pub const OpenAIProvider = struct {
    pub const api = "openai-completions";

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        var event_stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
        errdefer event_stream_instance.deinit();

        // Build request payload
        const payload = try buildRequestPayload(allocator, model, context, options);
        defer payload.deinit(allocator);

        // Serialize payload to JSON
        var json_str = std.ArrayList(u8).empty;
        defer json_str.deinit(allocator);
        
        // TODO: Serialize payload to json_str
        _ = try std.json.stringifyAlloc(allocator, payload, .{});

        // Build HTTP request
        var headers = std.StringHashMap([]const u8).empty;
        defer headers.deinit(allocator);
        
        try headers.put(allocator, "Content-Type", "application/json");
        try headers.put(allocator, "Authorization", try std.fmt.allocPrint(allocator, "Bearer {s}", .{options.?.api_key orelse ""}));
        try headers.put(allocator, "Accept", "text/event-stream");

        const req = http_client.HttpRequest{
            .method = .POST,
            .url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{model.base_url}),
            .headers = headers,
            .body = json_str.items,
        };
        defer allocator.free(req.url);

        // Send request and process response
        var client = try http_client.HttpClient.init(allocator);
        defer client.deinit();

        const response = try client.request(req);
        defer response.deinit();

        if (response.status != 200) {
            event_stream_instance.end(.{
                .role = "assistant",
                .content = &[_]types.ContentBlock{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = types.Usage.init(),
                .stop_reason = .error_reason,
                .error_message = try std.fmt.allocPrint(allocator, "HTTP {d}", .{response.status}),
                .timestamp = 0,
            });
            return event_stream_instance;
        }

        // Parse SSE stream
        try parseSseStream(allocator, &event_stream_instance, response.body, model);

        return event_stream_instance;
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

fn parseSseStream(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    body: []const u8,
    model: types.Model,
) !void {
    var lines = std.mem.split(u8, body, "\n");
    
    var output = types.AssistantMessage{
        .role = "assistant",
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    };

    stream_ptr.push(.{
        .event_type = .start,
    });

    var current_text: ?std.ArrayList(u8) = null;
    defer if (current_text) |*t| t.deinit(allocator);

    while (lines.next()) |line| {
        const data = parseSseLine(line) orelse continue;
        
        if (std.mem.eql(u8, data, "[DONE]")) {
            break;
        }

        const chunk = try parseChunk(allocator, data);
        defer if (chunk) |c| c.deinit(allocator);

        if (chunk == null) continue;

        // Extract choices from chunk
        const choices = chunk.?.object.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;

        const choice = choices.array.items[0];
        if (choice != .object) continue;

        const delta = choice.object.get("delta") orelse continue;
        if (delta != .object) continue;

        // Handle text content
        if (delta.object.get("content")) |content| {
            if (content == .string and content.string.len > 0) {
                if (current_text == null) {
                    stream_ptr.push(.{
                        .event_type = .text_start,
                        .content_index = 0,
                    });
                    current_text = std.ArrayList(u8).empty;
                }

                try current_text.?.appendSlice(allocator, content.string);
                stream_ptr.push(.{
                    .event_type = .text_delta,
                    .content_index = 0,
                    .delta = content.string,
                });
            }
        }

        // Handle finish_reason
        if (choice.object.get("finish_reason")) |finish_reason| {
            if (finish_reason == .string) {
                output.stop_reason = mapStopReason(finish_reason.string);
            }
        }
    }

    // Finish current text block
    if (current_text) |text| {
        stream_ptr.push(.{
            .event_type = .text_end,
            .content_index = 0,
            .content = text.items,
        });
        
        // Add text content to output
        var content_blocks = try allocator.alloc(types.ContentBlock, 1);
        content_blocks[0] = .{ .text = .{ .text = text.items } };
        output.content = content_blocks;
    }

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

fn mapStopReason(reason: []const u8) types.StopReason {
    if (std.mem.eql(u8, reason, "stop")) return .stop;
    if (std.mem.eql(u8, reason, "length")) return .length;
    if (std.mem.eql(u8, reason, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, reason, "content_filter")) return .error_reason;
    return .stop;
}

/// Build the request payload for OpenAI chat completions API
pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    var messages = std.json.Array.init(allocator);
    errdefer {
        for (messages.items) |*item| {
            item.deinit(allocator);
        }
        messages.deinit(allocator);
    }

    // Add system prompt if present
    if (context.system_prompt) |system| {
        try messages.append(allocator, std.json.Value{ .object = try buildMessageObject(allocator, "system", system) });
    }

    // Add conversation messages
    for (context.messages) |msg| {
        switch (msg) {
            .user => |user_msg| {
                const content = if (user_msg.content.len > 0)
                    user_msg.content[0].text.text
                else
                    "";
                try messages.append(allocator, std.json.Value{ .object = try buildMessageObject(allocator, "user", content) });
            },
            .assistant => |assistant_msg| {
                const content = if (assistant_msg.content.len > 0)
                    assistant_msg.content[0].text.text
                else
                    "";
                try messages.append(allocator, std.json.Value{ .object = try buildMessageObject(allocator, "assistant", content) });
            },
            .tool_result => |tool_result| {
                const content = if (tool_result.content.len > 0)
                    tool_result.content[0].text.text
                else
                    "";
                try messages.append(allocator, std.json.Value{ .object = try buildMessageObject(allocator, "tool", content) });
            },
        }
    }

    var payload = std.json.ObjectMap.init(allocator);
    errdefer payload.deinit(allocator);

    try payload.put(allocator, "model", std.json.Value{ .string = model.id });
    try payload.put(allocator, "messages", std.json.Value{ .array = messages });
    try payload.put(allocator, "stream", std.json.Value{ .bool = true });

    if (options) |opts| {
        if (opts.temperature) |temp| {
            try payload.put(allocator, "temperature", std.json.Value{ .float = temp });
        }
        if (opts.max_tokens) |max| {
            try payload.put(allocator, "max_tokens", std.json.Value{ .integer = @intCast(max) });
        }
    }

    return std.json.Value{ .object = payload };
}

fn buildMessageObject(allocator: std.mem.Allocator, role: []const u8, content: []const u8) !std.json.ObjectMap {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "role", std.json.Value{ .string = role });
    try obj.put(allocator, "content", std.json.Value{ .string = content });
    return obj;
}

/// Parse SSE line and extract JSON data
pub fn parseSseLine(line: []const u8) ?[]const u8 {
    const prefix = "data: ";
    if (std.mem.startsWith(u8, line, prefix)) {
        return line[prefix.len..];
    }
    return null;
}

/// Parse a streaming chunk from OpenAI
pub fn parseChunk(allocator: std.mem.Allocator, data: []const u8) !?std.json.Value {
    if (data.len == 0 or std.mem.eql(u8, data, "[DONE]")) {
        return null;
    }
    return try json_parse.parseStreamingJson(allocator, data);
}

test "buildRequestPayload basic" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    const context = types.Context{
        .system_prompt = "You are a helpful assistant.",
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1234567890,
            } },
        },
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer payload.deinit(allocator);

    try std.testing.expect(payload == .object);
    const model_val = payload.object.get("model").?;
    try std.testing.expectEqualStrings("gpt-4", model_val.string);

    const messages = payload.object.get("messages").?;
    try std.testing.expect(messages == .array);
    try std.testing.expectEqual(@as(usize, 2), messages.array.items.len);
}

test "parseSseLine" {
    const line = "data: {\"foo\": 123}";
    const result = parseSseLine(line);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{\"foo\": 123}", result.?);

    const no_data = "event: start";
    const no_result = parseSseLine(no_data);
    try std.testing.expect(no_result == null);
}

test "parseChunk" {
    const allocator = std.testing.allocator;

    const done = try parseChunk(allocator, "[DONE]");
    try std.testing.expect(done == null);

    const empty = try parseChunk(allocator, "");
    try std.testing.expect(empty == null);

    const valid = try parseChunk(allocator, "{\"foo\": 123}");
    defer if (valid) |v| v.deinit(allocator);
    try std.testing.expect(valid != null);
    try std.testing.expect(valid.? == .object);
}
