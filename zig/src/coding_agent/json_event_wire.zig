const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const config_errors = @import("config_errors.zig");
const common = @import("tools/common.zig");

pub fn stringifyAgentEventLine(allocator: std.mem.Allocator, event: agent.AgentEvent) ![]u8 {
    return stringifyAgentEventLineWithConfigErrors(allocator, event, &.{});
}

pub fn stringifyAgentEventLineWithConfigErrors(
    allocator: std.mem.Allocator,
    event: agent.AgentEvent,
    errors: []const config_errors.ConfigError,
) ![]u8 {
    var value = try agentEventToJsonValue(allocator, event);
    defer common.deinitJsonValue(allocator, value);
    if (event.event_type == .agent_start) {
        try putField(&value.object, allocator, "config_errors", try configErrorsToJsonValue(allocator, errors));
    }
    try validateAgentEventJson(allocator, value);
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub fn agentEventToJsonValue(allocator: std.mem.Allocator, event: agent.AgentEvent) !std.json.Value {
    var object = try initObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = object });

    try putStringField(&object, allocator, "type", agentEventTypeToString(event.event_type));

    switch (event.event_type) {
        .agent_start, .turn_start => {},
        .agent_end => {
            if (event.messages) |messages| {
                try putField(&object, allocator, "messages", try messagesToJsonValue(allocator, messages));
            }
        },
        .turn_end => {
            if (event.message) |message| {
                try putField(&object, allocator, "message", try messageToJsonValue(allocator, message));
            }
            if (event.tool_results) |tool_results| {
                try putField(&object, allocator, "toolResults", try toolResultMessagesToJsonValue(allocator, tool_results));
            }
        },
        .message_start, .message_end => {
            if (event.message) |message| {
                try putField(&object, allocator, "message", try messageToJsonValue(allocator, message));
            }
        },
        .message_update => {
            if (event.message) |message| {
                try putField(&object, allocator, "message", try messageToJsonValue(allocator, message));
            }
            if (event.assistant_message_event) |assistant_message_event| {
                const fallback_partial = if (event.message) |message| switch (message) {
                    .assistant => |assistant| assistant,
                    else => null,
                } else null;
                try putField(&object, allocator, "assistantMessageEvent", try assistantMessageEventToJsonValue(allocator, assistant_message_event, fallback_partial));
            }
        },
        .tool_execution_start => {
            if (event.tool_call_id) |tool_call_id| try putStringField(&object, allocator, "toolCallId", tool_call_id);
            if (event.tool_name) |tool_name| try putStringField(&object, allocator, "toolName", tool_name);
            if (event.args) |args| try putField(&object, allocator, "args", try common.cloneJsonValue(allocator, args));
        },
        .tool_execution_update => {
            if (event.tool_call_id) |tool_call_id| try putStringField(&object, allocator, "toolCallId", tool_call_id);
            if (event.tool_name) |tool_name| try putStringField(&object, allocator, "toolName", tool_name);
            if (event.args) |args| try putField(&object, allocator, "args", try common.cloneJsonValue(allocator, args));
            if (event.partial_result) |partial_result| {
                try putField(&object, allocator, "partialResult", try agentToolResultToJsonValue(allocator, partial_result));
            }
        },
        .tool_execution_end => {
            if (event.tool_call_id) |tool_call_id| try putStringField(&object, allocator, "toolCallId", tool_call_id);
            if (event.tool_name) |tool_name| try putStringField(&object, allocator, "toolName", tool_name);
            if (event.result) |result| {
                try putField(&object, allocator, "result", try agentToolResultToJsonValue(allocator, result));
            }
            if (event.is_error) |is_error| try putBoolField(&object, allocator, "isError", is_error);
        },
    }

    return .{ .object = object };
}

pub fn assistantMessageEventToJsonValue(
    allocator: std.mem.Allocator,
    event: ai.AssistantMessageEvent,
    fallback_partial: ?ai.AssistantMessage,
) !std.json.Value {
    var object = try initObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = object });

    try putStringField(&object, allocator, "type", assistantEventTypeToString(event.event_type));

    switch (event.event_type) {
        .start => {
            if (assistantPartialForEvent(event, fallback_partial)) |partial| {
                try putField(&object, allocator, "partial", try assistantMessageToJsonValue(allocator, partial));
            }
        },
        .text_start, .thinking_start, .toolcall_start => {
            if (event.content_index) |content_index| try putIntField(&object, allocator, "contentIndex", content_index);
            if (assistantPartialForEvent(event, fallback_partial)) |partial| {
                try putField(&object, allocator, "partial", try assistantMessageToJsonValue(allocator, partial));
            }
        },
        .text_delta, .thinking_delta, .toolcall_delta => {
            if (event.content_index) |content_index| try putIntField(&object, allocator, "contentIndex", content_index);
            if (event.delta) |delta| try putStringField(&object, allocator, "delta", delta);
            if (assistantPartialForEvent(event, fallback_partial)) |partial| {
                try putField(&object, allocator, "partial", try assistantMessageToJsonValue(allocator, partial));
            }
        },
        .text_end, .thinking_end => {
            if (event.content_index) |content_index| try putIntField(&object, allocator, "contentIndex", content_index);
            if (event.content) |content| try putStringField(&object, allocator, "content", content);
            if (assistantPartialForEvent(event, fallback_partial)) |partial| {
                try putField(&object, allocator, "partial", try assistantMessageToJsonValue(allocator, partial));
            }
        },
        .toolcall_end => {
            if (event.content_index) |content_index| try putIntField(&object, allocator, "contentIndex", content_index);
            if (event.tool_call) |tool_call| {
                try putField(&object, allocator, "toolCall", try toolCallToJsonValue(allocator, tool_call));
            }
            if (assistantPartialForEvent(event, fallback_partial)) |partial| {
                try putField(&object, allocator, "partial", try assistantMessageToJsonValue(allocator, partial));
            }
        },
        .done => {
            if (event.message) |message| {
                try putStringField(&object, allocator, "reason", stopReasonToString(message.stop_reason));
                try putField(&object, allocator, "message", try assistantMessageToJsonValue(allocator, message));
            }
        },
        .error_event => {
            if (event.message) |message| {
                try putStringField(&object, allocator, "reason", stopReasonToString(message.stop_reason));
                try putField(&object, allocator, "error", try assistantMessageToJsonValue(allocator, message));
            }
        },
    }

    return .{ .object = object };
}

pub fn validateAgentEventJson(allocator: std.mem.Allocator, value: std.json.Value) !void {
    try validateAgentEventValue(allocator, value, "$");
}

fn validateAgentEventValue(allocator: std.mem.Allocator, value: std.json.Value, path: []const u8) !void {
    const object = try asObject(allocator, value, path);
    const event_type = try requireStringField(allocator, object, path, "type");

    if (std.mem.eql(u8, event_type, "agent_start")) {
        if (object.get("config_errors")) |errors| try validateConfigErrors(allocator, errors, path);
        return;
    }
    if (std.mem.eql(u8, event_type, "turn_start")) return;

    if (std.mem.eql(u8, event_type, "agent_end")) {
        try validateMessagesField(allocator, object, path, "messages");
        return;
    }
    if (std.mem.eql(u8, event_type, "turn_end")) {
        try validateMessageField(allocator, object, path, "message");
        try validateToolResultMessagesField(allocator, object, path, "toolResults");
        return;
    }
    if (std.mem.eql(u8, event_type, "message_start") or std.mem.eql(u8, event_type, "message_end")) {
        try validateMessageField(allocator, object, path, "message");
        return;
    }
    if (std.mem.eql(u8, event_type, "message_update")) {
        try validateMessageField(allocator, object, path, "message");
        try validateAssistantEventField(allocator, object, path, "assistantMessageEvent");
        return;
    }
    if (std.mem.eql(u8, event_type, "tool_execution_start")) {
        _ = try requireStringField(allocator, object, path, "toolCallId");
        _ = try requireStringField(allocator, object, path, "toolName");
        _ = try requireField(object, allocator, path, "args");
        return;
    }
    if (std.mem.eql(u8, event_type, "tool_execution_update")) {
        _ = try requireStringField(allocator, object, path, "toolCallId");
        _ = try requireStringField(allocator, object, path, "toolName");
        _ = try requireField(object, allocator, path, "args");
        try validateAgentToolResultField(allocator, object, path, "partialResult");
        return;
    }
    if (std.mem.eql(u8, event_type, "tool_execution_end")) {
        _ = try requireStringField(allocator, object, path, "toolCallId");
        _ = try requireStringField(allocator, object, path, "toolName");
        try validateAgentToolResultField(allocator, object, path, "result");
        _ = try requireBoolField(allocator, object, path, "isError");
        return;
    }

    try invalidValue(allocator, path, "type", event_type, "a known AgentEvent.type");
}

fn validateAssistantEventValue(allocator: std.mem.Allocator, value: std.json.Value, path: []const u8) !void {
    const object = try asObject(allocator, value, path);
    const event_type = try requireStringField(allocator, object, path, "type");

    if (std.mem.eql(u8, event_type, "start")) {
        try validateAssistantMessageField(allocator, object, path, "partial");
        return;
    }
    if (std.mem.eql(u8, event_type, "text_start") or std.mem.eql(u8, event_type, "thinking_start") or std.mem.eql(u8, event_type, "toolcall_start")) {
        _ = try requireIntegerField(allocator, object, path, "contentIndex");
        try validateAssistantMessageField(allocator, object, path, "partial");
        return;
    }
    if (std.mem.eql(u8, event_type, "text_delta") or std.mem.eql(u8, event_type, "thinking_delta") or std.mem.eql(u8, event_type, "toolcall_delta")) {
        _ = try requireIntegerField(allocator, object, path, "contentIndex");
        _ = try requireStringField(allocator, object, path, "delta");
        try validateAssistantMessageField(allocator, object, path, "partial");
        return;
    }
    if (std.mem.eql(u8, event_type, "text_end") or std.mem.eql(u8, event_type, "thinking_end")) {
        _ = try requireIntegerField(allocator, object, path, "contentIndex");
        _ = try requireStringField(allocator, object, path, "content");
        try validateAssistantMessageField(allocator, object, path, "partial");
        return;
    }
    if (std.mem.eql(u8, event_type, "toolcall_end")) {
        _ = try requireIntegerField(allocator, object, path, "contentIndex");
        try validateToolCallField(allocator, object, path, "toolCall");
        try validateAssistantMessageField(allocator, object, path, "partial");
        return;
    }
    if (std.mem.eql(u8, event_type, "done")) {
        const reason = try requireAllowedStringField(allocator, object, path, "reason", &[_][]const u8{ "stop", "length", "toolUse" }, "an allowed stop reason");
        try validateAssistantMessageField(allocator, object, path, "message");
        try requireMatchingAssistantStopReason(allocator, object, path, "message", reason);
        return;
    }
    if (std.mem.eql(u8, event_type, "error")) {
        const reason = try requireAllowedStringField(allocator, object, path, "reason", &[_][]const u8{ "error", "aborted" }, "an allowed stop reason");
        try validateAssistantMessageField(allocator, object, path, "error");
        try requireMatchingAssistantStopReason(allocator, object, path, "error", reason);
        return;
    }

    try invalidValue(allocator, path, "type", event_type, "a known AssistantMessageEvent.type");
}

fn validateMessageValue(allocator: std.mem.Allocator, value: std.json.Value, path: []const u8) !void {
    const object = try asObject(allocator, value, path);
    const role = try requireStringField(allocator, object, path, "role");

    if (std.mem.eql(u8, role, "user")) {
        const content_value = try requireField(object, allocator, path, "content");
        if (content_value != .string) {
            try validateContentArray(allocator, content_value, path, "content", .user);
        }
        _ = try requireIntegerField(allocator, object, path, "timestamp");
        return;
    }
    if (std.mem.eql(u8, role, "assistant")) {
        try validateAssistantMessageObject(allocator, object, path);
        return;
    }
    if (std.mem.eql(u8, role, "toolResult")) {
        try validateToolResultMessageObject(allocator, object, path);
        return;
    }

    try invalidValue(allocator, path, "role", role, "user, assistant, or toolResult");
}

fn validateAssistantMessageObject(allocator: std.mem.Allocator, object: std.json.ObjectMap, path: []const u8) !void {
    try validateContentArray(allocator, try requireField(object, allocator, path, "content"), path, "content", .assistant);
    _ = try requireStringField(allocator, object, path, "api");
    _ = try requireStringField(allocator, object, path, "provider");
    _ = try requireStringField(allocator, object, path, "model");
    if (object.get("responseId")) |response_id| {
        if (response_id != .string) {
            const response_id_path = try fieldPath(allocator, path, "responseId");
            defer allocator.free(response_id_path);
            try invalidType(allocator, response_id_path, "string", response_id);
        }
    }
    try validateUsageField(allocator, object, path, "usage");
    _ = try requireAllowedStringField(allocator, object, path, "stopReason", &[_][]const u8{ "stop", "length", "toolUse", "error", "aborted" }, "an allowed stop reason");
    if (object.get("errorMessage")) |error_message| {
        if (error_message != .string) {
            const error_message_path = try fieldPath(allocator, path, "errorMessage");
            defer allocator.free(error_message_path);
            try invalidType(allocator, error_message_path, "string", error_message);
        }
    }
    _ = try requireIntegerField(allocator, object, path, "timestamp");
}

fn validateToolResultMessageObject(allocator: std.mem.Allocator, object: std.json.ObjectMap, path: []const u8) !void {
    _ = try requireStringField(allocator, object, path, "toolCallId");
    _ = try requireStringField(allocator, object, path, "toolName");
    try validateContentArray(allocator, try requireField(object, allocator, path, "content"), path, "content", .tool_result);
    _ = try requireBoolField(allocator, object, path, "isError");
    _ = try requireIntegerField(allocator, object, path, "timestamp");
}

const ContentValidationMode = enum {
    user,
    assistant,
    tool_result,
};

fn validateContentArray(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    parent_path: []const u8,
    field_name: []const u8,
    mode: ContentValidationMode,
) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);

    const array = try asArray(allocator, value, path);

    for (array.items, 0..) |item, index| {
        const item_path = try indexPath(allocator, path, index);
        defer allocator.free(item_path);

        const object = try asObject(allocator, item, item_path);
        const item_type = try requireStringField(allocator, object, item_path, "type");

        if (std.mem.eql(u8, item_type, "text")) {
            _ = try requireStringField(allocator, object, item_path, "text");
            if (object.get("textSignature")) |signature| {
                if (signature != .string) {
                    const signature_path = try fieldPath(allocator, item_path, "textSignature");
                    defer allocator.free(signature_path);
                    try invalidType(allocator, signature_path, "string", signature);
                }
            }
            continue;
        }
        if (std.mem.eql(u8, item_type, "image")) {
            _ = try requireStringField(allocator, object, item_path, "data");
            _ = try requireStringField(allocator, object, item_path, "mimeType");
            continue;
        }
        if (std.mem.eql(u8, item_type, "thinking")) {
            if (mode == .tool_result or mode == .user) try invalidValue(allocator, item_path, "type", item_type, "text or image");
            _ = try requireStringField(allocator, object, item_path, "thinking");
            if (object.get("thinkingSignature")) |signature| {
                if (signature != .string) {
                    const signature_path = try fieldPath(allocator, item_path, "thinkingSignature");
                    defer allocator.free(signature_path);
                    try invalidType(allocator, signature_path, "string", signature);
                }
            }
            if (object.get("redacted")) |redacted| {
                if (redacted != .bool) {
                    const redacted_path = try fieldPath(allocator, item_path, "redacted");
                    defer allocator.free(redacted_path);
                    try invalidType(allocator, redacted_path, "bool", redacted);
                }
            }
            continue;
        }
        if (std.mem.eql(u8, item_type, "toolCall")) {
            if (mode != .assistant) try invalidValue(allocator, item_path, "type", item_type, "text or image");
            try validateToolCallObject(allocator, object, item_path);
            continue;
        }

        try invalidValue(allocator, item_path, "type", item_type, "text, image, thinking, or toolCall");
    }
}

fn validateToolCallObject(allocator: std.mem.Allocator, object: std.json.ObjectMap, path: []const u8) !void {
    _ = try requireStringField(allocator, object, path, "id");
    _ = try requireStringField(allocator, object, path, "name");
    const arguments_value = try requireField(object, allocator, path, "arguments");
    if (arguments_value != .object) {
        const arguments_path = try fieldPath(allocator, path, "arguments");
        defer allocator.free(arguments_path);
        try invalidType(allocator, arguments_path, "object", arguments_value);
    }
    if (object.get("thoughtSignature")) |signature| {
        if (signature != .string) {
            const signature_path = try fieldPath(allocator, path, "thoughtSignature");
            defer allocator.free(signature_path);
            try invalidType(allocator, signature_path, "string", signature);
        }
    }
}

fn validateUsageField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);

    const usage_object = try asObject(allocator, try requireField(object, allocator, parent_path, field_name), path);

    _ = try requireIntegerField(allocator, usage_object, path, "input");
    _ = try requireIntegerField(allocator, usage_object, path, "output");
    _ = try requireIntegerField(allocator, usage_object, path, "cacheRead");
    _ = try requireIntegerField(allocator, usage_object, path, "cacheWrite");
    _ = try requireIntegerField(allocator, usage_object, path, "totalTokens");

    const cost_value = try requireField(usage_object, allocator, path, "cost");
    const cost_path = try fieldPath(allocator, path, "cost");
    defer allocator.free(cost_path);
    const cost_object = try asObject(allocator, cost_value, cost_path);
    try requireNumberField(allocator, cost_object, cost_path, "input");
    try requireNumberField(allocator, cost_object, cost_path, "output");
    try requireNumberField(allocator, cost_object, cost_path, "cacheRead");
    try requireNumberField(allocator, cost_object, cost_path, "cacheWrite");
    try requireNumberField(allocator, cost_object, cost_path, "total");
}

fn validateMessagesField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);
    const array = try asArray(allocator, try requireField(object, allocator, parent_path, field_name), path);
    for (array.items, 0..) |item, index| {
        const item_path = try indexPath(allocator, path, index);
        defer allocator.free(item_path);
        try validateMessageValue(allocator, item, item_path);
    }
}

fn validateToolResultMessagesField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);
    const array = try asArray(allocator, try requireField(object, allocator, parent_path, field_name), path);
    for (array.items, 0..) |item, index| {
        const item_path = try indexPath(allocator, path, index);
        defer allocator.free(item_path);
        try validateToolResultMessageObject(allocator, try asObject(allocator, item, item_path), item_path);
    }
}

fn validateMessageField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);
    try validateMessageValue(allocator, try requireField(object, allocator, parent_path, field_name), path);
}

fn validateAssistantMessageField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);
    const assistant_object = try asObject(allocator, try requireField(object, allocator, parent_path, field_name), path);
    const role = try requireStringField(allocator, assistant_object, path, "role");
    if (!std.mem.eql(u8, role, "assistant")) try invalidValue(allocator, path, "role", role, "assistant");
    try validateAssistantMessageObject(allocator, assistant_object, path);
}

fn validateToolCallField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);
    try validateToolCallObject(allocator, try asObject(allocator, try requireField(object, allocator, parent_path, field_name), path), path);
}

fn validateAssistantEventField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);
    try validateAssistantEventValue(allocator, try requireField(object, allocator, parent_path, field_name), path);
}

fn requireMatchingAssistantStopReason(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    parent_path: []const u8,
    field_name: []const u8,
    expected_reason: []const u8,
) !void {
    const field_path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(field_path);
    const field_object = try asObject(allocator, try requireField(object, allocator, parent_path, field_name), field_path);
    const actual_reason = try requireStringField(allocator, field_object, field_path, "stopReason");
    if (!std.mem.eql(u8, expected_reason, actual_reason)) {
        try mismatchedValue(allocator, field_path, "stopReason", actual_reason, parent_path, "reason", expected_reason);
    }
}

fn validateAgentToolResultField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);
    const result_object = try asObject(allocator, try requireField(object, allocator, parent_path, field_name), path);
    try validateContentArray(allocator, try requireField(result_object, allocator, path, "content"), path, "content", .tool_result);
}

fn validateConfigErrors(allocator: std.mem.Allocator, value: std.json.Value, parent_path: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, "config_errors");
    defer allocator.free(path);
    const array = try asArray(allocator, value, path);
    for (array.items, 0..) |item, index| {
        const item_path = try indexPath(allocator, path, index);
        defer allocator.free(item_path);
        const object = try asObject(allocator, item, item_path);
        _ = try requireStringField(allocator, object, item_path, "source");
        _ = try requireStringField(allocator, object, item_path, "path");
        _ = try requireStringField(allocator, object, item_path, "message");
    }
}

fn requireField(object: std.json.ObjectMap, allocator: std.mem.Allocator, parent_path: []const u8, field_name: []const u8) !std.json.Value {
    return object.get(field_name) orelse {
        try missingField(allocator, parent_path, field_name);
        unreachable;
    };
}

fn requireStringField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) ![]const u8 {
    const field_value = try requireField(object, allocator, parent_path, field_name);
    return switch (field_value) {
        .string => |string| string,
        else => {
            const path = try fieldPath(allocator, parent_path, field_name);
            defer allocator.free(path);
            try invalidType(allocator, path, "string", field_value);
            unreachable;
        },
    };
}

fn requireBoolField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !bool {
    const field_value = try requireField(object, allocator, parent_path, field_name);
    return switch (field_value) {
        .bool => |boolean| boolean,
        else => {
            const path = try fieldPath(allocator, parent_path, field_name);
            defer allocator.free(path);
            try invalidType(allocator, path, "bool", field_value);
            unreachable;
        },
    };
}

fn requireIntegerField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !i64 {
    const field_value = try requireField(object, allocator, parent_path, field_name);
    return switch (field_value) {
        .integer => |integer| integer,
        else => {
            const path = try fieldPath(allocator, parent_path, field_name);
            defer allocator.free(path);
            try invalidType(allocator, path, "integer", field_value);
            unreachable;
        },
    };
}

fn requireNumberField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const field_value = try requireField(object, allocator, parent_path, field_name);
    switch (field_value) {
        .integer, .float => return {},
        else => {
            const path = try fieldPath(allocator, parent_path, field_name);
            defer allocator.free(path);
            try invalidType(allocator, path, "number", field_value);
        },
    }
}

fn requireAllowedStringField(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    parent_path: []const u8,
    field_name: []const u8,
    allowed: []const []const u8,
    expected: []const u8,
) ![]const u8 {
    const value = try requireStringField(allocator, object, parent_path, field_name);
    for (allowed) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return value;
    }
    try invalidValue(allocator, parent_path, field_name, value, expected);
    unreachable;
}

fn missingField(allocator: std.mem.Allocator, parent_path: []const u8, field_name: []const u8) !void {
    const message = try std.fmt.allocPrint(allocator, "{s}.{s}: missing required field", .{ parent_path, field_name });
    defer allocator.free(message);
    std.debug.print("JSON schema validation failed: {s}\n", .{message});
    return error.InvalidJsonSchema;
}

fn invalidType(allocator: std.mem.Allocator, path: []const u8, expected: []const u8, actual: std.json.Value) !void {
    const message = try std.fmt.allocPrint(allocator, "{s}: expected {s}, found {s}", .{ path, expected, jsonTypeName(actual) });
    defer allocator.free(message);
    std.debug.print("JSON schema validation failed: {s}\n", .{message});
    return error.InvalidJsonSchema;
}

fn invalidValue(allocator: std.mem.Allocator, parent_path: []const u8, field_name: []const u8, actual: []const u8, expected: []const u8) !void {
    const message = try std.fmt.allocPrint(allocator, "{s}.{s}: invalid value '{s}', expected {s}", .{ parent_path, field_name, actual, expected });
    defer allocator.free(message);
    std.debug.print("JSON schema validation failed: {s}\n", .{message});
    return error.InvalidJsonSchema;
}

fn mismatchedValue(
    allocator: std.mem.Allocator,
    parent_path: []const u8,
    field_name: []const u8,
    actual: []const u8,
    expected_parent_path: []const u8,
    expected_field_name: []const u8,
    expected: []const u8,
) !void {
    const message = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}: value '{s}' must match {s}.{s} ('{s}')",
        .{ parent_path, field_name, actual, expected_parent_path, expected_field_name, expected },
    );
    defer allocator.free(message);
    std.debug.print("JSON schema validation failed: {s}\n", .{message});
    return error.InvalidJsonSchema;
}

fn jsonTypeName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "bool",
        .integer => "integer",
        .float => "float",
        .number_string => "number_string",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn fieldPath(allocator: std.mem.Allocator, parent_path: []const u8, field_name: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field_name });
}

fn indexPath(allocator: std.mem.Allocator, parent_path: []const u8, index: usize) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ parent_path, index });
}

fn asObject(allocator: std.mem.Allocator, value: std.json.Value, path: []const u8) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => {
            try invalidType(allocator, path, "object", value);
            unreachable;
        },
    };
}

fn asArray(allocator: std.mem.Allocator, value: std.json.Value, path: []const u8) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => {
            try invalidType(allocator, path, "array", value);
            unreachable;
        },
    };
}

fn agentToolResultToJsonValue(allocator: std.mem.Allocator, result: agent.AgentToolResult) !std.json.Value {
    var object = try initObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = object });

    try putField(&object, allocator, "content", try contentBlocksToJsonValue(allocator, result.content, false, null));
    if (result.details) |details| {
        try putField(&object, allocator, "details", try common.cloneJsonValue(allocator, details));
    }

    return .{ .object = object };
}

fn configErrorsToJsonValue(allocator: std.mem.Allocator, errors: []const config_errors.ConfigError) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();

    for (errors) |config_error| {
        var object = try initObject(allocator);
        errdefer common.deinitJsonValue(allocator, .{ .object = object });
        try putStringField(&object, allocator, "source", config_errors.sourceName(config_error.source));
        try putStringField(&object, allocator, "path", config_error.path);
        try putStringField(&object, allocator, "message", config_error.message);
        try array.append(.{ .object = object });
    }

    return .{ .array = array };
}

fn messagesToJsonValue(allocator: std.mem.Allocator, messages: []const agent.AgentMessage) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (messages) |message| {
        try array.append(try messageToJsonValue(allocator, message));
    }
    return .{ .array = array };
}

fn toolResultMessagesToJsonValue(allocator: std.mem.Allocator, tool_results: []const agent.types.ToolResultMessage) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (tool_results) |tool_result| {
        try array.append(try toolResultMessageToJsonValue(allocator, tool_result));
    }
    return .{ .array = array };
}

fn messageToJsonValue(allocator: std.mem.Allocator, message: agent.AgentMessage) !std.json.Value {
    return switch (message) {
        .user => |user| try userMessageToJsonValue(allocator, user),
        .assistant => |assistant| try assistantMessageToJsonValue(allocator, assistant),
        .tool_result => |tool_result| try toolResultMessageToJsonValue(allocator, tool_result),
    };
}

fn userMessageToJsonValue(allocator: std.mem.Allocator, user: ai.UserMessage) !std.json.Value {
    var object = try initObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = object });

    try putStringField(&object, allocator, "role", "user");
    if (user.content.len == 1 and user.content[0] == .text) {
        try putStringField(&object, allocator, "content", user.content[0].text.text);
    } else {
        try putField(&object, allocator, "content", try contentBlocksToJsonValue(allocator, user.content, false, null));
    }
    try putIntField(&object, allocator, "timestamp", user.timestamp);
    return .{ .object = object };
}

fn assistantMessageToJsonValue(allocator: std.mem.Allocator, assistant: ai.AssistantMessage) !std.json.Value {
    var object = try initObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = object });

    try putStringField(&object, allocator, "role", "assistant");
    try putField(&object, allocator, "content", try contentBlocksToJsonValue(allocator, assistant.content, true, assistant.tool_calls));
    try putStringField(&object, allocator, "api", assistant.api);
    try putStringField(&object, allocator, "provider", assistant.provider);
    try putStringField(&object, allocator, "model", assistant.model);
    if (assistant.response_id) |response_id| {
        try putStringField(&object, allocator, "responseId", response_id);
    }
    try putField(&object, allocator, "usage", try usageToJsonValue(allocator, assistant.usage));
    try putStringField(&object, allocator, "stopReason", stopReasonToString(assistant.stop_reason));
    if (assistant.error_message) |error_message| {
        try putStringField(&object, allocator, "errorMessage", error_message);
    }
    try putIntField(&object, allocator, "timestamp", assistant.timestamp);
    return .{ .object = object };
}

fn toolResultMessageToJsonValue(allocator: std.mem.Allocator, tool_result: agent.types.ToolResultMessage) !std.json.Value {
    var object = try initObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = object });

    try putStringField(&object, allocator, "role", "toolResult");
    try putStringField(&object, allocator, "toolCallId", tool_result.tool_call_id);
    try putStringField(&object, allocator, "toolName", tool_result.tool_name);
    try putField(&object, allocator, "content", try contentBlocksToJsonValue(allocator, tool_result.content, false, null));
    if (tool_result.details) |details| {
        try putField(&object, allocator, "details", try common.cloneJsonValue(allocator, details));
    }
    try putBoolField(&object, allocator, "isError", tool_result.is_error);
    try putIntField(&object, allocator, "timestamp", tool_result.timestamp);
    return .{ .object = object };
}

fn contentBlocksToJsonValue(
    allocator: std.mem.Allocator,
    content: []const ai.ContentBlock,
    include_tool_calls: bool,
    tool_calls: ?[]const ai.ToolCall,
) !std.json.Value {
    var array = std.json.Array.init(allocator);

    for (content) |block| {
        var object = try initObject(allocator);
        switch (block) {
            .text => |text| {
                try putStringField(&object, allocator, "type", "text");
                try putStringField(&object, allocator, "text", text.text);
            },
            .image => |image| {
                try putStringField(&object, allocator, "type", "image");
                try putStringField(&object, allocator, "data", image.data);
                try putStringField(&object, allocator, "mimeType", image.mime_type);
            },
            .thinking => |thinking| {
                try putStringField(&object, allocator, "type", "thinking");
                try putStringField(&object, allocator, "thinking", thinking.thinking);
                if (thinking.signature) |signature| {
                    try putStringField(&object, allocator, "thinkingSignature", signature);
                }
                if (thinking.redacted) {
                    try putBoolField(&object, allocator, "redacted", true);
                }
            },
        }
        try array.append(.{ .object = object });
    }

    if (include_tool_calls) {
        if (tool_calls) |calls| {
            for (calls) |tool_call| {
                try array.append(try toolCallToJsonValue(allocator, tool_call));
            }
        }
    }

    return .{ .array = array };
}

fn usageToJsonValue(allocator: std.mem.Allocator, usage: ai.Usage) !std.json.Value {
    var cost_object = try initObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = cost_object });
    try putFloatField(&cost_object, allocator, "input", usage.cost.input);
    try putFloatField(&cost_object, allocator, "output", usage.cost.output);
    try putFloatField(&cost_object, allocator, "cacheRead", usage.cost.cache_read);
    try putFloatField(&cost_object, allocator, "cacheWrite", usage.cost.cache_write);
    try putFloatField(&cost_object, allocator, "total", usage.cost.total);

    var object = try initObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try putIntField(&object, allocator, "input", usage.input);
    try putIntField(&object, allocator, "output", usage.output);
    try putIntField(&object, allocator, "cacheRead", usage.cache_read);
    try putIntField(&object, allocator, "cacheWrite", usage.cache_write);
    try putIntField(&object, allocator, "totalTokens", usage.total_tokens);
    try putField(&object, allocator, "cost", .{ .object = cost_object });

    return .{ .object = object };
}

fn toolCallToJsonValue(allocator: std.mem.Allocator, tool_call: ai.ToolCall) !std.json.Value {
    var object = try initObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = object });

    try putStringField(&object, allocator, "type", "toolCall");
    try putStringField(&object, allocator, "id", tool_call.id);
    try putStringField(&object, allocator, "name", tool_call.name);
    try putField(&object, allocator, "arguments", try common.cloneJsonValue(allocator, tool_call.arguments));
    return .{ .object = object };
}

fn assistantPartialForEvent(event: ai.AssistantMessageEvent, fallback_partial: ?ai.AssistantMessage) ?ai.AssistantMessage {
    return event.message orelse fallback_partial;
}

pub fn stopReasonToString(reason: ai.StopReason) []const u8 {
    return switch (reason) {
        .stop => "stop",
        .length => "length",
        .tool_use => "toolUse",
        .error_reason => "error",
        .aborted => "aborted",
    };
}

fn agentEventTypeToString(event_type: agent.AgentEventType) []const u8 {
    return @tagName(event_type);
}

fn assistantEventTypeToString(event_type: ai.EventType) []const u8 {
    return switch (event_type) {
        .error_event => "error",
        else => @tagName(event_type),
    };
}

fn initObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return try std.json.ObjectMap.init(allocator, &.{}, &.{});
}

fn putField(object: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    try object.put(allocator, try allocator.dupe(u8, key), value);
}

fn putStringField(object: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try putField(object, allocator, key, .{ .string = try allocator.dupe(u8, value) });
}

fn putBoolField(object: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: bool) !void {
    try putField(object, allocator, key, .{ .bool = value });
}

fn putIntField(object: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: anytype) !void {
    try putField(object, allocator, key, .{ .integer = @as(i64, @intCast(value)) });
}

fn putFloatField(object: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: f64) !void {
    try putField(object, allocator, key, .{ .float = value });
}

test "validateAgentEventJson reports contextual schema errors" {
    const allocator = std.testing.allocator;

    var object = try initObject(allocator);
    defer common.deinitJsonValue(allocator, .{ .object = object });
    try putStringField(&object, allocator, "type", "tool_execution_end");

    try std.testing.expectError(error.InvalidJsonSchema, validateAgentEventJson(allocator, .{ .object = object }));
}

test "stringifyAgentEventLine rejects malformed serialized events" {
    const allocator = std.testing.allocator;

    const invalid_event = agent.AgentEvent{
        .event_type = .tool_execution_end,
        .tool_name = "bash",
        .result = .{
            .content = &[_]ai.ContentBlock{
                .{ .text = .{ .text = "missing tool call id" } },
            },
        },
        .is_error = false,
    };

    try std.testing.expectError(error.InvalidJsonSchema, stringifyAgentEventLine(allocator, invalid_event));
}

test "agent event JSON covers all top-level variants" {
    const allocator = std.testing.allocator;

    var args_object = try initObject(allocator);
    defer common.deinitJsonValue(allocator, .{ .object = args_object });
    try putStringField(&args_object, allocator, "path", "/tmp/file.txt");
    const args_value: std.json.Value = .{ .object = args_object };

    var details_object = try initObject(allocator);
    defer common.deinitJsonValue(allocator, .{ .object = details_object });
    try putIntField(&details_object, allocator, "exit_code", 0);
    const details_value: std.json.Value = .{ .object = details_object };

    const user_content = [_]ai.ContentBlock{
        .{ .text = .{ .text = "hello" } },
    };
    const assistant_content = [_]ai.ContentBlock{
        .{ .text = .{ .text = "partial text" } },
        .{ .thinking = .{ .thinking = "reasoning", .signature = "sig-1" } },
    };
    const tool_result_content = [_]ai.ContentBlock{
        .{ .text = .{ .text = "tool output" } },
    };

    const tool_call = ai.ToolCall{
        .id = "tool-1",
        .name = "bash",
        .arguments = args_value,
    };
    const tool_calls = [_]ai.ToolCall{tool_call};

    const assistant_message = ai.AssistantMessage{
        .content = assistant_content[0..],
        .tool_calls = tool_calls[0..],
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 2, .total_tokens = 3 },
        .stop_reason = .stop,
        .timestamp = 2,
    };
    const tool_result_message = agent.types.ToolResultMessage{
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .content = tool_result_content[0..],
        .details = details_value,
        .timestamp = 3,
    };
    const tool_execution_result = agent.types.AgentToolResult{
        .content = tool_result_content[0..],
        .details = details_value,
    };

    const events = [_]agent.AgentEvent{
        .{ .event_type = .agent_start },
        .{ .event_type = .turn_start },
        .{ .event_type = .message_start, .message = .{ .user = .{ .content = user_content[0..], .timestamp = 1 } } },
        .{
            .event_type = .message_update,
            .message = .{ .assistant = assistant_message },
            .assistant_message_event = .{
                .event_type = .text_delta,
                .content_index = 0,
                .delta = "partial text",
                .message = assistant_message,
            },
        },
        .{ .event_type = .message_end, .message = .{ .assistant = assistant_message } },
        .{ .event_type = .tool_execution_start, .tool_call_id = "tool-1", .tool_name = "bash", .args = args_value },
        .{ .event_type = .tool_execution_update, .tool_call_id = "tool-1", .tool_name = "bash", .args = args_value, .partial_result = tool_execution_result },
        .{ .event_type = .tool_execution_end, .tool_call_id = "tool-1", .tool_name = "bash", .result = tool_execution_result, .is_error = false },
        .{ .event_type = .turn_end, .message = .{ .assistant = assistant_message }, .tool_results = &[_]agent.types.ToolResultMessage{tool_result_message} },
        .{ .event_type = .agent_end, .messages = &[_]agent.AgentMessage{ .{ .user = .{ .content = user_content[0..], .timestamp = 1 } }, .{ .assistant = assistant_message }, .{ .tool_result = tool_result_message } } },
    };

    for (events) |event| {
        const value = try agentEventToJsonValue(allocator, event);
        defer common.deinitJsonValue(allocator, value);
        try validateAgentEventJson(allocator, value);
    }
}

test "assistant message event JSON covers all nested variants" {
    const allocator = std.testing.allocator;

    var args_object = try initObject(allocator);
    defer common.deinitJsonValue(allocator, .{ .object = args_object });
    try putStringField(&args_object, allocator, "command", "echo hi");
    const args_value: std.json.Value = .{ .object = args_object };

    const assistant_content = [_]ai.ContentBlock{
        .{ .text = .{ .text = "hello" } },
    };
    const assistant_message = ai.AssistantMessage{
        .content = assistant_content[0..],
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 1, .total_tokens = 2 },
        .stop_reason = .stop,
        .timestamp = 10,
    };
    const error_message = ai.AssistantMessage{
        .content = assistant_content[0..],
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 0, .total_tokens = 1 },
        .stop_reason = .error_reason,
        .error_message = "boom",
        .timestamp = 11,
    };
    const tool_call = ai.ToolCall{
        .id = "tool-1",
        .name = "bash",
        .arguments = args_value,
    };

    const assistant_events = [_]ai.AssistantMessageEvent{
        .{ .event_type = .start, .message = assistant_message },
        .{ .event_type = .text_start, .content_index = 0, .message = assistant_message },
        .{ .event_type = .text_delta, .content_index = 0, .delta = "h", .message = assistant_message },
        .{ .event_type = .text_end, .content_index = 0, .content = "hello", .message = assistant_message },
        .{ .event_type = .thinking_start, .content_index = 1, .message = assistant_message },
        .{ .event_type = .thinking_delta, .content_index = 1, .delta = "thinking", .message = assistant_message },
        .{ .event_type = .thinking_end, .content_index = 1, .content = "thinking", .message = assistant_message },
        .{ .event_type = .toolcall_start, .content_index = 2, .message = assistant_message },
        .{ .event_type = .toolcall_delta, .content_index = 2, .delta = "{\"x\":1}", .message = assistant_message },
        .{ .event_type = .toolcall_end, .content_index = 2, .tool_call = tool_call, .message = assistant_message },
        .{ .event_type = .done, .message = assistant_message },
        .{ .event_type = .error_event, .message = error_message },
    };

    for (assistant_events) |assistant_event| {
        const event = agent.AgentEvent{
            .event_type = .message_update,
            .message = .{ .assistant = assistant_message },
            .assistant_message_event = assistant_event,
        };
        const value = try agentEventToJsonValue(allocator, event);
        defer common.deinitJsonValue(allocator, value);
        try validateAgentEventJson(allocator, value);
    }
}

test "assistant event done reason must match nested message stopReason" {
    const allocator = std.testing.allocator;
    const json =
        \\{"type":"done","reason":"stop","message":{"role":"assistant","content":[{"type":"text","text":"hello"}],"api":"faux","provider":"faux","model":"faux-1","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"length","timestamp":10}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectError(error.InvalidJsonSchema, validateAssistantEventValue(allocator, parsed.value, "$"));
}

test "assistant event error reason must match nested message stopReason" {
    const allocator = std.testing.allocator;
    const json =
        \\{"type":"error","reason":"error","error":{"role":"assistant","content":[{"type":"text","text":"boom"}],"api":"faux","provider":"faux","model":"faux-1","usage":{"input":1,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":1,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"aborted","errorMessage":"aborted","timestamp":10}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectError(error.InvalidJsonSchema, validateAssistantEventValue(allocator, parsed.value, "$"));
}
