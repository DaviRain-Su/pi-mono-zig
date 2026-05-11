const std = @import("std");
const provider_json = @import("../shared/provider_json.zig");
const types = @import("../types.zig");

const CLAUDE_CODE_IDENTITY = "You are Claude Code, Anthropic's official CLI for Claude.";
const TOOL_PLACEHOLDER_TEXT = "";

/// Type alias matching anthropic.zig's AnthropicCompat.
/// Passed by the caller; imported here only for builder signatures.
pub const AnthropicCompat = struct {
    supports_eager_tool_input_streaming: bool = true,
    supports_long_cache_retention: bool = true,
};

pub fn deinitJsonArrayItems(allocator: std.mem.Allocator, array: *std.json.Array) void {
    for (array.items) |item| provider_json.freeValue(allocator, item);
    array.deinit();
}

const CANONICAL_TOOL_NAMES = std.StaticStringMap([]const u8).initComptime(.{
    .{ "read", "Read" },
    .{ "write", "Write" },
    .{ "edit", "Edit" },
    .{ "bash", "Bash" },
    .{ "grep", "Grep" },
    .{ "glob", "Glob" },
    .{ "askuserquestion", "AskUserQuestion" },
    .{ "enterplanmode", "EnterPlanMode" },
    .{ "exitplanmode", "ExitPlanMode" },
    .{ "killshell", "KillShell" },
    .{ "notebookedit", "NotebookEdit" },
    .{ "skill", "Skill" },
    .{ "task", "Task" },
    .{ "taskoutput", "TaskOutput" },
    .{ "todowrite", "TodoWrite" },
    .{ "webfetch", "WebFetch" },
    .{ "websearch", "WebSearch" },
});

const CANONICAL_TOOL_NAME_BUF_LEN: usize = 64;

pub fn canonicalClaudeCodeToolName(name: []const u8) []const u8 {
    if (name.len == 0 or name.len > CANONICAL_TOOL_NAME_BUF_LEN) return name;
    var buf: [CANONICAL_TOOL_NAME_BUF_LEN]u8 = undefined;
    for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return CANONICAL_TOOL_NAMES.get(buf[0..name.len]) orelse name;
}

test "canonicalClaudeCodeToolName maps every entry case-insensitively" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "read", .expected = "Read" },
        .{ .input = "READ", .expected = "Read" },
        .{ .input = "Read", .expected = "Read" },
        .{ .input = "write", .expected = "Write" },
        .{ .input = "edit", .expected = "Edit" },
        .{ .input = "bash", .expected = "Bash" },
        .{ .input = "grep", .expected = "Grep" },
        .{ .input = "glob", .expected = "Glob" },
        .{ .input = "askuserquestion", .expected = "AskUserQuestion" },
        .{ .input = "AskUserQuestion", .expected = "AskUserQuestion" },
        .{ .input = "enterplanmode", .expected = "EnterPlanMode" },
        .{ .input = "exitplanmode", .expected = "ExitPlanMode" },
        .{ .input = "killshell", .expected = "KillShell" },
        .{ .input = "notebookedit", .expected = "NotebookEdit" },
        .{ .input = "skill", .expected = "Skill" },
        .{ .input = "task", .expected = "Task" },
        .{ .input = "taskoutput", .expected = "TaskOutput" },
        .{ .input = "todowrite", .expected = "TodoWrite" },
        .{ .input = "webfetch", .expected = "WebFetch" },
        .{ .input = "websearch", .expected = "WebSearch" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, canonicalClaudeCodeToolName(case.input));
    }
}

test "canonicalClaudeCodeToolName returns input for unknown or oversized names" {
    try std.testing.expectEqualStrings("unknown_tool", canonicalClaudeCodeToolName("unknown_tool"));
    try std.testing.expectEqualStrings("", canonicalClaudeCodeToolName(""));
    const long_name = "a" ** (CANONICAL_TOOL_NAME_BUF_LEN + 1);
    try std.testing.expectEqualStrings(long_name, canonicalClaudeCodeToolName(long_name));
}

fn buildTextBlockObject(allocator: std.mem.Allocator, text: []const u8, cache_control: ?std.json.Value) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "text") });
    try object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text) });
    if (cache_control) |value| {
        try object.put(allocator, try allocator.dupe(u8, "cache_control"), try provider_json.cloneValue(allocator, value));
    }
    return .{ .object = object };
}

fn buildRoleMessageObject(allocator: std.mem.Allocator, role: []const u8, content: std.json.Value) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, role) });
    try object.put(allocator, try allocator.dupe(u8, "content"), content);
    return .{ .object = object };
}

fn applyCacheControlToBlock(allocator: std.mem.Allocator, block: *std.json.Value, cache_control: std.json.Value) !void {
    if (block.* != .object) return;
    try block.object.put(allocator, try allocator.dupe(u8, "cache_control"), try provider_json.cloneValue(allocator, cache_control));
}

fn applyCacheControlToLastUserContent(allocator: std.mem.Allocator, message: *std.json.Value, cache_control: std.json.Value) !void {
    if (message.* != .object) return;
    const role_value = message.object.get("role") orelse return;
    if (role_value != .string or !std.mem.eql(u8, role_value.string, "user")) return;
    const content_value = message.object.getPtr("content") orelse return;
    if (content_value.* == .array and content_value.array.items.len > 0) {
        try applyCacheControlToBlock(allocator, &content_value.array.items[content_value.array.items.len - 1], cache_control);
    }
}

fn applyCacheControlToLastNUserMessages(
    allocator: std.mem.Allocator,
    messages: *std.json.Array,
    cache_control: std.json.Value,
    count: usize,
) !void {
    var remaining = count;
    var index = messages.items.len;
    while (index > 0 and remaining > 0) {
        index -= 1;
        const message = &messages.items[index];
        if (message.* != .object) continue;
        const role_value = message.object.get("role") orelse continue;
        if (role_value != .string or !std.mem.eql(u8, role_value.string, "user")) continue;
        try applyCacheControlToLastUserContent(allocator, message, cache_control);
        remaining -= 1;
    }
}

pub fn buildCacheControl(
    allocator: std.mem.Allocator,
    compat: AnthropicCompat,
    retention: types.CacheRetention,
) !?std.json.Value {
    if (retention == .none) return null;
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "ephemeral") });
    if (retention == .long and compat.supports_long_cache_retention) {
        try object.put(allocator, try allocator.dupe(u8, "ttl"), .{ .string = try allocator.dupe(u8, "1h") });
    }
    return .{ .object = object };
}

pub fn buildSystemPromptValue(
    allocator: std.mem.Allocator,
    system_prompt: ?[]const u8,
    is_oauth: bool,
    cache_control: ?std.json.Value,
) !?std.json.Value {
    if (!is_oauth and system_prompt == null) return null;

    var array = std.json.Array.init(allocator);
    errdefer deinitJsonArrayItems(allocator, &array);
    if (is_oauth) {
        try array.append(try buildTextBlockObject(allocator, CLAUDE_CODE_IDENTITY, null));
    }
    if (system_prompt) |prompt| {
        try array.append(try buildTextBlockObject(allocator, prompt, null));
    }
    if (cache_control) |value| {
        if (array.items.len > 0) {
            try applyCacheControlToBlock(allocator, &array.items[array.items.len - 1], value);
        }
    }
    return .{ .array = array };
}

pub fn buildUserMessageValue(allocator: std.mem.Allocator, user: types.UserMessage) !std.json.Value {
    var content = std.json.Array.init(allocator);
    errdefer deinitJsonArrayItems(allocator, &content);

    for (user.content) |block| {
        switch (block) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) continue;
                try content.append(try buildTextBlockObject(allocator, text.text, null));
            },
            .image => |image| {
                var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                var source = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "image") });
                try source.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "base64") });
                try source.put(allocator, try allocator.dupe(u8, "media_type"), .{ .string = try allocator.dupe(u8, image.mime_type) });
                try source.put(allocator, try allocator.dupe(u8, "data"), .{ .string = try allocator.dupe(u8, image.data) });
                try object.put(allocator, try allocator.dupe(u8, "source"), .{ .object = source });
                try content.append(.{ .object = object });
            },
            .thinking, .tool_call => {},
        }
    }

    if (content.items.len == 0) {
        try content.append(try buildTextBlockObject(allocator, "", null));
    }
    return try buildRoleMessageObject(allocator, "user", .{ .array = content });
}

pub fn buildAssistantMessageValue(
    allocator: std.mem.Allocator,
    assistant: types.AssistantMessage,
    is_oauth: bool,
) !std.json.Value {
    var content = std.json.Array.init(allocator);
    errdefer deinitJsonArrayItems(allocator, &content);

    for (assistant.content) |block| {
        switch (block) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) continue;
                try content.append(try buildTextBlockObject(allocator, text.text, null));
            },
            .thinking => |thinking| {
                const signature = types.thinkingSignature(thinking);
                if (thinking.redacted) {
                    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "redacted_thinking") });
                    try object.put(allocator, try allocator.dupe(u8, "data"), .{ .string = try allocator.dupe(u8, signature orelse "") });
                    try content.append(.{ .object = object });
                    continue;
                }
                if (signature) |value| {
                    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "thinking") });
                    try object.put(allocator, try allocator.dupe(u8, "thinking"), .{ .string = try allocator.dupe(u8, thinking.thinking) });
                    try object.put(allocator, try allocator.dupe(u8, "signature"), .{ .string = try allocator.dupe(u8, value) });
                    try content.append(.{ .object = object });
                } else {
                    try content.append(try buildTextBlockObject(allocator, thinking.thinking, null));
                }
            },
            .image => {},
            .tool_call => |tool_call| {
                var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "tool_use") });
                try object.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, tool_call.id) });
                try object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, if (is_oauth) canonicalClaudeCodeToolName(tool_call.name) else tool_call.name) });
                try object.put(allocator, try allocator.dupe(u8, "input"), try provider_json.cloneValue(allocator, tool_call.arguments));
                try content.append(.{ .object = object });
            },
        }
    }

    if (!types.hasInlineToolCalls(assistant)) {
        if (assistant.tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "tool_use") });
                try object.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, tool_call.id) });
                try object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, if (is_oauth) canonicalClaudeCodeToolName(tool_call.name) else tool_call.name) });
                try object.put(allocator, try allocator.dupe(u8, "input"), try provider_json.cloneValue(allocator, tool_call.arguments));
                try content.append(.{ .object = object });
            }
        }
    }

    return try buildRoleMessageObject(allocator, "assistant", .{ .array = content });
}

fn buildToolResultContentValue(allocator: std.mem.Allocator, content: []const types.ContentBlock) !std.json.Value {
    var only_text = true;
    for (content) |block| {
        if (block != .text) {
            only_text = false;
            break;
        }
    }

    if (only_text) {
        var text = std.ArrayList(u8).empty;
        defer text.deinit(allocator);
        for (content, 0..) |block, index| {
            if (index > 0) try text.append(allocator, '\n');
            try text.appendSlice(allocator, block.text.text);
        }
        return .{ .string = try allocator.dupe(u8, text.items) };
    }

    var array = std.json.Array.init(allocator);
    errdefer deinitJsonArrayItems(allocator, &array);
    for (content) |block| {
        switch (block) {
            .text => |text| try array.append(try buildTextBlockObject(allocator, text.text, null)),
            .image => |image| {
                var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                var source = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "image") });
                try source.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "base64") });
                try source.put(allocator, try allocator.dupe(u8, "media_type"), .{ .string = try allocator.dupe(u8, image.mime_type) });
                try source.put(allocator, try allocator.dupe(u8, "data"), .{ .string = try allocator.dupe(u8, image.data) });
                try object.put(allocator, try allocator.dupe(u8, "source"), .{ .object = source });
                try array.append(.{ .object = object });
            },
            .thinking => |thinking| try array.append(try buildTextBlockObject(allocator, thinking.thinking, null)),
            .tool_call => {},
        }
    }
    return .{ .array = array };
}

fn buildToolResultUserMessageValue(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
) !struct { value: std.json.Value, consumed: usize } {
    var content = std.json.Array.init(allocator);
    errdefer deinitJsonArrayItems(allocator, &content);

    var consumed: usize = 0;
    while (consumed < messages.len) : (consumed += 1) {
        switch (messages[consumed]) {
            .tool_result => |tool_result| {
                var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "tool_result") });
                try object.put(allocator, try allocator.dupe(u8, "tool_use_id"), .{ .string = try allocator.dupe(u8, tool_result.tool_call_id) });
                try object.put(allocator, try allocator.dupe(u8, "content"), try buildToolResultContentValue(allocator, tool_result.content));
                if (tool_result.is_error) {
                    try object.put(allocator, try allocator.dupe(u8, "is_error"), .{ .bool = true });
                }
                try content.append(.{ .object = object });
            },
            else => break,
        }
    }

    return .{
        .value = try buildRoleMessageObject(allocator, "user", .{ .array = content }),
        .consumed = consumed,
    };
}

pub fn buildMessagesValue(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    tools: ?[]const types.Tool,
    is_oauth: bool,
    cache_control: ?std.json.Value,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer deinitJsonArrayItems(allocator, &array);

    var index: usize = 0;
    while (index < messages.len) : (index += 1) {
        switch (messages[index]) {
            .user => |user| try array.append(try buildUserMessageValue(allocator, user)),
            .assistant => |assistant| {
                if (types.shouldReplayAssistantInProviderContext(assistant)) {
                    try array.append(try buildAssistantMessageValue(allocator, assistant, is_oauth));
                }
            },
            .tool_result => {
                const grouped = try buildToolResultUserMessageValue(allocator, messages[index..]);
                try array.append(grouped.value);
                index += grouped.consumed - 1;
            },
        }
    }
    _ = tools;
    if (cache_control) |value| {
        try applyCacheControlToLastNUserMessages(allocator, &array, value, 2);
    }
    return .{ .array = array };
}

pub fn buildToolsValue(
    allocator: std.mem.Allocator,
    tools: []const types.Tool,
    is_oauth: bool,
    supports_eager_tool_input_streaming: bool,
    cache_control: ?std.json.Value,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer deinitJsonArrayItems(allocator, &array);
    for (tools, 0..) |tool, index| {
        var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, if (is_oauth) canonicalClaudeCodeToolName(tool.name) else tool.name) });
        try object.put(allocator, try allocator.dupe(u8, "description"), .{ .string = try allocator.dupe(u8, tool.description) });
        if (supports_eager_tool_input_streaming) {
            try object.put(allocator, try allocator.dupe(u8, "eager_input_streaming"), .{ .bool = true });
        }

        var schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try schema.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });
        if (tool.parameters == .object) {
            if (tool.parameters.object.get("properties")) |properties| {
                try schema.put(allocator, try allocator.dupe(u8, "properties"), try provider_json.cloneValue(allocator, properties));
            } else {
                try schema.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) });
            }
            if (tool.parameters.object.get("required")) |required| {
                try schema.put(allocator, try allocator.dupe(u8, "required"), try provider_json.cloneValue(allocator, required));
            }
        } else {
            try schema.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) });
        }
        try object.put(allocator, try allocator.dupe(u8, "input_schema"), .{ .object = schema });
        if (cache_control != null and index == tools.len - 1) {
            try object.put(allocator, try allocator.dupe(u8, "cache_control"), try provider_json.cloneValue(allocator, cache_control.?));
        }
        try array.append(.{ .object = object });
    }
    return .{ .array = array };
}

