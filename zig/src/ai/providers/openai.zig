const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");

pub const OpenAIProvider = struct {
    pub const api = "openai-completions";

    pub fn stream(
        allocator: std.mem.Allocator,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !void {
        _ = model;
        _ = context;
        _ = options;
        _ = allocator;
        // TODO: Implement OpenAI streaming
    }

    pub fn streamSimple(
        allocator: std.mem.Allocator,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !void {
        _ = model;
        _ = context;
        _ = options;
        _ = allocator;
        // TODO: Implement OpenAI simple streaming
    }
};

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
