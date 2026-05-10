const std = @import("std");
const types = @import("../types.zig");
const provider_json = @import("../shared/provider_json.zig");
const transform_messages = @import("../shared/transform_messages.zig");

pub fn freeOwnedJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    provider_json.freeValue(allocator, value);
}

/// Mirror TypeScript Array.prototype.filter(Boolean) semantics for parsed
/// JSON values produced by JSON.parse. Returns true if the value would be
/// filtered out by `filter(Boolean)`.
///
/// JSON.parse can yield: null, true/false, number, string, array, object.
/// Of these, the falsey ones are: null, false, 0 (integer or float), and
/// empty string. NaN cannot appear from JSON.parse (it is not valid JSON),
/// but we conservatively treat number_string-encoded NaN-like values the
/// same as the underlying numeric semantics.
fn isFalseyJsonValue(value: std.json.Value) bool {
    return switch (value) {
        .null => true,
        .bool => |b| !b,
        .integer => |i| i == 0,
        .float => |f| f == 0.0 or std.math.isNan(f),
        .number_string => |ns| ns.len == 0 or std.mem.eql(u8, ns, "0") or std.mem.eql(u8, ns, "-0") or std.mem.eql(u8, ns, "NaN"),
        .string => |s| s.len == 0,
        .array, .object => false,
    };
}

pub fn sanitizeSurrogates(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    // In-place filtering: scan for unpaired surrogates and remove them
    // High surrogates: 0xD800-0xDBFF
    // Low surrogates: 0xDC00-0xDFFF
    // This is a simplified version that works on UTF-8 encoded text.
    // Surrogates in UTF-8 appear as 3-byte sequences: ED A0 80-ED AF BF (high) or ED B0 80-ED BF BF (low)
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        // Check for 3-byte UTF-8 surrogate sequence
        if (i + 2 < text.len and text[i] == 0xED) {
            const is_high = text[i + 1] >= 0xA0 and text[i + 1] <= 0xAF;
            const is_low = text[i + 1] >= 0xB0 and text[i + 1] <= 0xBF;

            if (is_high) {
                // Check if followed by low surrogate
                if (i + 5 < text.len and text[i + 3] == 0xED and text[i + 4] >= 0xB0 and text[i + 4] <= 0xBF) {
                    // Valid pair, keep both
                    try result.appendSlice(allocator, text[i .. i + 6]);
                    i += 6;
                    continue;
                }
                // Unpaired high surrogate, skip
                i += 3;
                continue;
            } else if (is_low) {
                // Unpaired low surrogate (not preceded by high), skip
                // Note: if we got here, the preceding bytes were not a valid high surrogate
                i += 3;
                continue;
            }
        }

        // Regular byte, keep it
        try result.append(allocator, text[i]);
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

pub fn processCacheRetentionEnv() ?[]const u8 {
    const value = std.c.getenv("PI_CACHE_RETENTION") orelse return null;
    return std.mem.span(value);
}

pub fn resolveCacheRetention(cache_retention: types.CacheRetention, pi_cache_retention_env: ?[]const u8) types.CacheRetention {
    return switch (cache_retention) {
        .unset => if (pi_cache_retention_env) |value|
            if (std.mem.eql(u8, value, "long")) .long else .short
        else
            .short,
        .none, .short, .long => cache_retention,
    };
}

pub fn resolveOptionsCacheRetention(options: ?types.StreamOptions, pi_cache_retention_env: ?[]const u8) types.CacheRetention {
    return resolveCacheRetention(if (options) |opts| opts.cache_retention else .unset, pi_cache_retention_env);
}

pub fn buildFinalRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    return buildFinalRequestPayloadWithCacheRetentionEnv(allocator, model, context, options, processCacheRetentionEnv());
}

pub fn buildFinalRequestPayloadWithCacheRetentionEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    pi_cache_retention_env: ?[]const u8,
) !std.json.Value {
    var payload = try buildRequestPayloadWithCacheRetentionEnv(allocator, model, context, options, pi_cache_retention_env);
    errdefer provider_json.freeValue(allocator, payload);

    if (options) |opts| {
        if (opts.on_payload) |on_payload| {
            if (try on_payload(allocator, payload, model)) |replacement| {
                provider_json.freeValue(allocator, payload);
                payload = replacement;
            }
        }
    }

    return payload;
}

/// Build the request payload for OpenAI chat completions API
pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    return buildRequestPayloadWithCacheRetentionEnv(allocator, model, context, options, processCacheRetentionEnv());
}

pub fn buildRequestPayloadWithCacheRetentionEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    pi_cache_retention_env: ?[]const u8,
) !std.json.Value {
    const compat = getCompat(model);
    const cache_retention = resolveOptionsCacheRetention(options, pi_cache_retention_env);
    var messages = try buildMessages(allocator, model, context, compat);
    errdefer messages.deinit();

    const has_tool_history = hasToolHistory(context.messages);

    var payload = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer payload.deinit(allocator);

    try payload.put(allocator, try allocator.dupe(u8, "model"), std.json.Value{ .string = try allocator.dupe(u8, model.id) });
    try payload.put(allocator, try allocator.dupe(u8, "messages"), std.json.Value{ .array = messages });
    try payload.put(allocator, try allocator.dupe(u8, "stream"), std.json.Value{ .bool = true });

    try appendCommonPayloadFields(allocator, &payload, compat);
    try appendOptionPayloadFields(allocator, &payload, model, compat, cache_retention, options);
    try appendToolPayloadFields(allocator, &payload, context, compat, has_tool_history);

    if (try buildCompatCacheControl(allocator, compat, cache_retention)) |cache_control| {
        defer provider_json.freeValue(allocator, cache_control);
        try applyAnthropicCacheControl(allocator, &payload, cache_control);
    }

    try appendReasoningPayloadFields(allocator, &payload, model, compat, options);
    try appendRoutingPayloadFields(allocator, &payload, model, compat);

    return std.json.Value{ .object = payload };
}

fn buildMessages(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    compat: OpenAICompat,
) !std.json.Array {
    const transformed_messages = try transform_messages.transformMessages(
        allocator,
        context.messages,
        model,
        &normalizeToolCallId,
    );
    defer transform_messages.freeMessages(allocator, transformed_messages);

    var messages = std.json.Array.init(allocator);
    errdefer messages.deinit();

    // Determine if we should use developer role for reasoning models
    const use_developer_role = model.reasoning and compat.supports_developer_role;

    // Add system prompt if present
    if (context.system_prompt) |system| {
        const role = if (use_developer_role) "developer" else "system";
        const sanitized = try sanitizeSurrogates(allocator, system);
        defer allocator.free(sanitized);
        try messages.append(std.json.Value{ .object = try buildMessageObject(allocator, role, sanitized) });
    }

    // Add conversation messages
    var last_role: ?[]const u8 = null;
    var message_index: usize = 0;
    while (message_index < transformed_messages.len) : (message_index += 1) {
        const msg = transformed_messages[message_index];
        if (compat.requires_assistant_after_tool_result and last_role != null and std.mem.eql(u8, last_role.?, "toolResult") and msg == .user) {
            try messages.append(.{ .object = try buildMessageObject(allocator, "assistant", "I have processed the tool results.") });
        }
        switch (msg) {
            .user => |user_msg| {
                if (user_msg.content.len == 0) continue;
                try messages.append(try buildUserMessage(allocator, model, user_msg));
                last_role = "user";
            },
            .assistant => |assistant_msg| {
                if (try buildAssistantMessage(allocator, model, assistant_msg)) |assistant_message| {
                    try messages.append(assistant_message);
                    last_role = "assistant";
                }
            },
            .tool_result => {
                const append_result = try appendToolResultMessages(allocator, &messages, model, transformed_messages, message_index);
                message_index = append_result.next_index - 1;
                last_role = if (append_result.appended_image_user) "user" else "toolResult";
            },
        }
    }

    return messages;
}

fn appendCommonPayloadFields(
    allocator: std.mem.Allocator,
    payload: *std.json.ObjectMap,
    compat: OpenAICompat,
) !void {
    if (compat.supports_usage_in_streaming) {
        var stream_options = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        errdefer stream_options.deinit(allocator);
        try stream_options.put(allocator, try allocator.dupe(u8, "include_usage"), std.json.Value{ .bool = true });
        try payload.put(allocator, try allocator.dupe(u8, "stream_options"), std.json.Value{ .object = stream_options });
    }

    if (compat.supports_store) {
        try payload.put(allocator, try allocator.dupe(u8, "store"), std.json.Value{ .bool = false });
    }
}

fn appendOptionPayloadFields(
    allocator: std.mem.Allocator,
    payload: *std.json.ObjectMap,
    model: types.Model,
    compat: OpenAICompat,
    cache_retention: types.CacheRetention,
    options: ?types.StreamOptions,
) !void {
    if (options) |opts| {
        if (opts.session_id) |session_id| {
            if ((std.mem.indexOf(u8, model.base_url, "api.openai.com") != null and cache_retention != .none) or
                (cache_retention == .long and compat.supports_long_cache_retention))
            {
                try payload.put(allocator, try allocator.dupe(u8, "prompt_cache_key"), std.json.Value{ .string = try allocator.dupe(u8, session_id) });
            }
        }
        if (opts.temperature) |temp| {
            try payload.put(allocator, try allocator.dupe(u8, "temperature"), std.json.Value{ .float = temp });
        }
        if (opts.max_tokens) |max| {
            const field = if (std.mem.eql(u8, compat.max_tokens_field, "max_tokens")) "max_tokens" else "max_completion_tokens";
            try payload.put(allocator, try allocator.dupe(u8, field), std.json.Value{ .integer = @intCast(max) });
        }
        const openai_opts = opts.openaiOptions();
        if (openai_opts.tool_choice) |tool_choice| {
            try payload.put(allocator, try allocator.dupe(u8, "tool_choice"), try provider_json.cloneValue(allocator, tool_choice));
        }
    }

    if (cache_retention == .long and compat.supports_long_cache_retention) {
        try payload.put(allocator, try allocator.dupe(u8, "prompt_cache_retention"), std.json.Value{ .string = try allocator.dupe(u8, "24h") });
    }
}

fn appendToolPayloadFields(
    allocator: std.mem.Allocator,
    payload: *std.json.ObjectMap,
    context: types.Context,
    compat: OpenAICompat,
    has_tool_history: bool,
) !void {
    if (context.tools) |tools| {
        if (tools.len > 0) {
            var tools_array = std.json.Array.init(allocator);
            errdefer tools_array.deinit();
            for (tools) |tool| {
                try tools_array.append(try buildToolObject(allocator, tool, compat));
            }
            try payload.put(allocator, try allocator.dupe(u8, "tools"), std.json.Value{ .array = tools_array });
            if (compat.zai_tool_stream) {
                try payload.put(allocator, try allocator.dupe(u8, "tool_stream"), .{ .bool = true });
            }
        } else if (has_tool_history) {
            try payload.put(allocator, try allocator.dupe(u8, "tools"), .{ .array = std.json.Array.init(allocator) });
        }
    } else if (has_tool_history) {
        try payload.put(allocator, try allocator.dupe(u8, "tools"), .{ .array = std.json.Array.init(allocator) });
    }
}

fn appendReasoningPayloadFields(
    allocator: std.mem.Allocator,
    payload: *std.json.ObjectMap,
    model: types.Model,
    compat: OpenAICompat,
    options: ?types.StreamOptions,
) !void {
    if (model.reasoning) {
        const openai_opts = if (options) |opts| opts.openaiOptions() else types.OpenAIChatStreamOptions{};
        const effort = openai_opts.reasoning_effort;
        if (std.mem.eql(u8, compat.thinking_format, "zai") or std.mem.eql(u8, compat.thinking_format, "qwen")) {
            try payload.put(allocator, try allocator.dupe(u8, "enable_thinking"), .{ .bool = effort != null });
        } else if (std.mem.eql(u8, compat.thinking_format, "qwen-chat-template")) {
            var template_kwargs = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            errdefer template_kwargs.deinit(allocator);
            try template_kwargs.put(allocator, try allocator.dupe(u8, "enable_thinking"), .{ .bool = effort != null });
            try template_kwargs.put(allocator, try allocator.dupe(u8, "preserve_thinking"), .{ .bool = true });
            try payload.put(allocator, try allocator.dupe(u8, "chat_template_kwargs"), .{ .object = template_kwargs });
        } else if (std.mem.eql(u8, compat.thinking_format, "deepseek")) {
            var thinking = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            errdefer thinking.deinit(allocator);
            try thinking.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, if (effort != null) "enabled" else "disabled") });
            try payload.put(allocator, try allocator.dupe(u8, "thinking"), .{ .object = thinking });
            if (effort) |value| {
                try payload.put(allocator, try allocator.dupe(u8, "reasoning_effort"), .{ .string = try allocator.dupe(u8, value) });
            }
        } else if (std.mem.eql(u8, compat.thinking_format, "openrouter")) {
            var reasoning = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            errdefer reasoning.deinit(allocator);
            const value = effort orelse "none";
            try reasoning.put(allocator, try allocator.dupe(u8, "effort"), .{ .string = try allocator.dupe(u8, value) });
            try payload.put(allocator, try allocator.dupe(u8, "reasoning"), .{ .object = reasoning });
        } else if (std.mem.eql(u8, compat.thinking_format, "together")) {
            var reasoning = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            errdefer reasoning.deinit(allocator);
            try reasoning.put(allocator, try allocator.dupe(u8, "enabled"), .{ .bool = effort != null });
            try payload.put(allocator, try allocator.dupe(u8, "reasoning"), .{ .object = reasoning });
            if (effort) |value| {
                if (compat.supports_reasoning_effort) {
                    try payload.put(allocator, try allocator.dupe(u8, "reasoning_effort"), .{ .string = try allocator.dupe(u8, mappedReasoningEffort(model, value)) });
                }
            }
        } else if (effort) |value| {
            if (compat.supports_reasoning_effort) {
                try payload.put(allocator, try allocator.dupe(u8, "reasoning_effort"), .{ .string = try allocator.dupe(u8, value) });
            }
        }
    }
}

fn mappedReasoningEffort(model: types.Model, effort: []const u8) []const u8 {
    const level = modelThinkingLevel(effort) orelse return effort;
    const map = model.thinking_level_map orelse return effort;
    const entry = map.get(level) orelse return effort;
    return switch (entry) {
        .mapped => |mapped| mapped,
        .unsupported => effort,
    };
}

fn modelThinkingLevel(effort: []const u8) ?types.ModelThinkingLevel {
    if (std.mem.eql(u8, effort, "off")) return .off;
    if (std.mem.eql(u8, effort, "minimal")) return .minimal;
    if (std.mem.eql(u8, effort, "low")) return .low;
    if (std.mem.eql(u8, effort, "medium")) return .medium;
    if (std.mem.eql(u8, effort, "high")) return .high;
    if (std.mem.eql(u8, effort, "xhigh")) return .xhigh;
    return null;
}

fn appendRoutingPayloadFields(
    allocator: std.mem.Allocator,
    payload: *std.json.ObjectMap,
    model: types.Model,
    compat: OpenAICompat,
) !void {
    if (std.mem.indexOf(u8, model.base_url, "openrouter.ai") != null) {
        if (compat.open_router_routing) |routing| {
            try payload.put(allocator, try allocator.dupe(u8, "provider"), try provider_json.cloneValue(allocator, routing));
        }
    }

    if (std.mem.indexOf(u8, model.base_url, "ai-gateway.vercel.sh") != null) {
        if (compat.vercel_gateway_routing) |routing| {
            if (routing == .object and (routing.object.get("only") != null or routing.object.get("order") != null)) {
                var gateway = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                errdefer gateway.deinit(allocator);
                if (routing.object.get("only")) |only| {
                    try gateway.put(allocator, try allocator.dupe(u8, "only"), try provider_json.cloneValue(allocator, only));
                }
                if (routing.object.get("order")) |order| {
                    try gateway.put(allocator, try allocator.dupe(u8, "order"), try provider_json.cloneValue(allocator, order));
                }
                var provider_options = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                errdefer provider_options.deinit(allocator);
                try provider_options.put(allocator, try allocator.dupe(u8, "gateway"), .{ .object = gateway });
                try payload.put(allocator, try allocator.dupe(u8, "providerOptions"), .{ .object = provider_options });
            }
        }
    }
}

fn buildCompatCacheControl(
    allocator: std.mem.Allocator,
    compat: OpenAICompat,
    cache_retention: types.CacheRetention,
) !?std.json.Value {
    const format = compat.cache_control_format orelse return null;
    if (!std.mem.eql(u8, format, "anthropic") or cache_retention == .none) return null;

    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "ephemeral") });
    if (cache_retention == .long and compat.supports_long_cache_retention) {
        try object.put(allocator, try allocator.dupe(u8, "ttl"), .{ .string = try allocator.dupe(u8, "1h") });
    }
    return .{ .object = object };
}

fn applyAnthropicCacheControl(
    allocator: std.mem.Allocator,
    payload: *std.json.ObjectMap,
    cache_control: std.json.Value,
) !void {
    if (payload.getPtr("messages")) |messages_value| {
        if (messages_value.* == .array) {
            try addCacheControlToInstructionMessage(allocator, &messages_value.array, cache_control);
            try addCacheControlToLastConversationMessage(allocator, &messages_value.array, cache_control);
        }
    }

    if (payload.getPtr("tools")) |tools_value| {
        if (tools_value.* == .array and tools_value.array.items.len > 0) {
            const last_tool = &tools_value.array.items[tools_value.array.items.len - 1];
            if (last_tool.* == .object) {
                try putJsonObjectFieldReplacing(allocator, &last_tool.object, "cache_control", try provider_json.cloneValue(allocator, cache_control));
            }
        }
    }
}

fn addCacheControlToInstructionMessage(
    allocator: std.mem.Allocator,
    messages: *std.json.Array,
    cache_control: std.json.Value,
) !void {
    for (messages.items) |*message| {
        if (message.* != .object) continue;
        const role = objectStringField(message.object, "role") orelse continue;
        if (std.mem.eql(u8, role, "system") or std.mem.eql(u8, role, "developer")) {
            _ = try addCacheControlToTextContent(allocator, &message.object, cache_control);
            return;
        }
    }
}

fn addCacheControlToLastConversationMessage(
    allocator: std.mem.Allocator,
    messages: *std.json.Array,
    cache_control: std.json.Value,
) !void {
    var index = messages.items.len;
    while (index > 0) {
        index -= 1;
        const message = &messages.items[index];
        if (message.* != .object) continue;
        const role = objectStringField(message.object, "role") orelse continue;
        if (std.mem.eql(u8, role, "user") or std.mem.eql(u8, role, "assistant")) {
            if (try addCacheControlToTextContent(allocator, &message.object, cache_control)) return;
        }
    }
}

fn addCacheControlToTextContent(
    allocator: std.mem.Allocator,
    message: *std.json.ObjectMap,
    cache_control: std.json.Value,
) !bool {
    const content = message.getPtr("content") orelse return false;
    switch (content.*) {
        .string => |text| {
            if (text.len == 0) return false;
            var parts = std.json.Array.init(allocator);
            errdefer parts.deinit();

            var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            errdefer part.deinit(allocator);
            try part.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "text") });
            try part.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text) });
            try part.put(allocator, try allocator.dupe(u8, "cache_control"), try provider_json.cloneValue(allocator, cache_control));
            try parts.append(.{ .object = part });

            provider_json.freeValue(allocator, content.*);
            content.* = .{ .array = parts };
            return true;
        },
        .array => |*parts| {
            var index = parts.items.len;
            while (index > 0) {
                index -= 1;
                const part = &parts.items[index];
                if (part.* != .object) continue;
                const part_type = objectStringField(part.object, "type") orelse continue;
                if (std.mem.eql(u8, part_type, "text")) {
                    try putJsonObjectFieldReplacing(allocator, &part.object, "cache_control", try provider_json.cloneValue(allocator, cache_control));
                    return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

fn objectStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn putJsonObjectFieldReplacing(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: std.json.Value,
) !void {
    if (object.getPtr(key)) |existing| {
        provider_json.freeValue(allocator, existing.*);
        existing.* = value;
    } else {
        try object.put(allocator, try allocator.dupe(u8, key), value);
    }
}

fn hasToolHistory(messages: []const types.Message) bool {
    for (messages) |message| {
        switch (message) {
            .tool_result => return true,
            .assistant => |assistant| {
                if (types.hasInlineToolCalls(assistant)) return true;
                if (assistant.tool_calls) |tool_calls| {
                    if (tool_calls.len > 0) return true;
                }
            },
            .user => {},
        }
    }
    return false;
}

pub const OpenAICompat = struct {
    supports_store: bool = true,
    supports_developer_role: bool = true,
    supports_reasoning_effort: bool = true,
    supports_usage_in_streaming: bool = true,
    max_tokens_field: []const u8 = "max_completion_tokens",
    requires_tool_result_name: bool = false,
    requires_assistant_after_tool_result: bool = false,
    requires_thinking_as_text: bool = false,
    requires_reasoning_content_on_assistant_messages: bool = false,
    thinking_format: []const u8 = "openai",
    open_router_routing: ?std.json.Value = null,
    vercel_gateway_routing: ?std.json.Value = null,
    zai_tool_stream: bool = false,
    supports_strict_mode: bool = true,
    cache_control_format: ?[]const u8 = null,
    send_session_affinity_headers: bool = false,
    supports_long_cache_retention: bool = true,
};

pub fn getCompat(model: types.Model) OpenAICompat {
    const is_non_standard = isNonStandardProvider(model);
    const is_chutes = std.mem.indexOf(u8, model.base_url, "chutes.ai") != null;
    const is_zai = std.mem.eql(u8, model.provider, "zai") or std.mem.indexOf(u8, model.base_url, "api.z.ai") != null or std.mem.indexOf(u8, model.base_url, "open.bigmodel.cn") != null;
    const is_grok = std.mem.eql(u8, model.provider, "xai") or std.mem.indexOf(u8, model.base_url, "api.x.ai") != null;
    const is_deepseek = std.mem.eql(u8, model.provider, "deepseek") or std.mem.indexOf(u8, model.base_url, "deepseek.com") != null;
    const is_together = std.mem.eql(u8, model.provider, "together") or
        std.mem.indexOf(u8, model.base_url, "api.together.ai") != null or
        std.mem.indexOf(u8, model.base_url, "api.together.xyz") != null;
    const is_cloudflare_workers_ai = std.mem.eql(u8, model.provider, "cloudflare-workers-ai") or std.mem.indexOf(u8, model.base_url, "api.cloudflare.com") != null;
    const is_cloudflare_ai_gateway = std.mem.eql(u8, model.provider, "cloudflare-ai-gateway") or std.mem.indexOf(u8, model.base_url, "gateway.ai.cloudflare.com") != null;
    const detected_thinking_format = if (is_deepseek)
        "deepseek"
    else if (is_zai)
        "zai"
    else if (is_together)
        "together"
    else if (std.mem.eql(u8, model.provider, "openrouter") or std.mem.indexOf(u8, model.base_url, "openrouter.ai") != null)
        "openrouter"
    else
        "openai";
    const detected_cache_control_format: ?[]const u8 = if (std.mem.eql(u8, model.provider, "openrouter") and std.mem.startsWith(u8, model.id, "anthropic/"))
        "anthropic"
    else
        null;

    return .{
        .supports_store = compatBoolField(model.compat, "supportsStore") orelse !is_non_standard,
        .supports_developer_role = compatBoolField(model.compat, "supportsDeveloperRole") orelse !is_non_standard,
        .supports_reasoning_effort = compatBoolField(model.compat, "supportsReasoningEffort") orelse (!is_grok and !is_zai and !is_together and !is_cloudflare_ai_gateway),
        .supports_usage_in_streaming = compatBoolField(model.compat, "supportsUsageInStreaming") orelse true,
        .max_tokens_field = compatStringField(model.compat, "maxTokensField") orelse if (is_chutes or is_together or is_cloudflare_ai_gateway) "max_tokens" else "max_completion_tokens",
        .requires_tool_result_name = compatBoolField(model.compat, "requiresToolResultName") orelse false,
        .requires_assistant_after_tool_result = compatBoolField(model.compat, "requiresAssistantAfterToolResult") orelse false,
        .requires_thinking_as_text = compatBoolField(model.compat, "requiresThinkingAsText") orelse false,
        .requires_reasoning_content_on_assistant_messages = compatBoolField(model.compat, "requiresReasoningContentOnAssistantMessages") orelse is_deepseek,
        .thinking_format = compatStringField(model.compat, "thinkingFormat") orelse detected_thinking_format,
        .open_router_routing = compatObjectValueField(model.compat, "openRouterRouting") orelse null,
        .vercel_gateway_routing = compatObjectValueField(model.compat, "vercelGatewayRouting") orelse null,
        .zai_tool_stream = compatBoolField(model.compat, "zaiToolStream") orelse false,
        .supports_strict_mode = compatBoolField(model.compat, "supportsStrictMode") orelse !(is_together or is_cloudflare_ai_gateway),
        .cache_control_format = compatStringField(model.compat, "cacheControlFormat") orelse detected_cache_control_format,
        .send_session_affinity_headers = compatBoolField(model.compat, "sendSessionAffinityHeaders") orelse false,
        .supports_long_cache_retention = compatBoolField(model.compat, "supportsLongCacheRetention") orelse !(is_together or is_cloudflare_workers_ai or is_cloudflare_ai_gateway),
    };
}

fn compatBoolField(compat: ?std.json.Value, key: []const u8) ?bool {
    const value = compat orelse return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field != .bool) return null;
    return field.bool;
}

fn compatStringField(compat: ?std.json.Value, key: []const u8) ?[]const u8 {
    const value = compat orelse return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn compatObjectValueField(compat: ?std.json.Value, key: []const u8) ?std.json.Value {
    const value = compat orelse return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field != .object) return null;
    return field;
}

fn isNonStandardProvider(model: types.Model) bool {
    const provider = model.provider;
    const base_url = model.base_url;

    if (std.mem.eql(u8, provider, "cerebras") or
        std.mem.eql(u8, provider, "xai") or
        std.mem.eql(u8, provider, "zai") or
        std.mem.eql(u8, provider, "together") or
        std.mem.eql(u8, provider, "opencode") or
        std.mem.eql(u8, provider, "cloudflare-workers-ai") or
        std.mem.eql(u8, provider, "cloudflare-ai-gateway"))
    {
        return true;
    }

    if (std.mem.indexOf(u8, base_url, "cerebras.ai") != null or
        std.mem.indexOf(u8, base_url, "api.x.ai") != null or
        std.mem.indexOf(u8, base_url, "chutes.ai") != null or
        std.mem.indexOf(u8, base_url, "deepseek.com") != null or
        std.mem.indexOf(u8, base_url, "api.z.ai") != null or
        std.mem.indexOf(u8, base_url, "open.bigmodel.cn") != null or
        std.mem.indexOf(u8, base_url, "api.together.ai") != null or
        std.mem.indexOf(u8, base_url, "api.together.xyz") != null or
        std.mem.indexOf(u8, base_url, "opencode.ai") != null or
        std.mem.indexOf(u8, base_url, "api.cloudflare.com") != null or
        std.mem.indexOf(u8, base_url, "gateway.ai.cloudflare.com") != null)
    {
        return true;
    }

    return false;
}

pub fn buildResolvedCompatSnapshotValue(allocator: std.mem.Allocator, model: types.Model) !std.json.Value {
    const compat = getCompat(model);
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);

    try putBoolValue(allocator, &object, "requiresAssistantAfterToolResult", compat.requires_assistant_after_tool_result);
    try putBoolValue(allocator, &object, "requiresReasoningContentOnAssistantMessages", compat.requires_reasoning_content_on_assistant_messages);
    try putBoolValue(allocator, &object, "requiresThinkingAsText", compat.requires_thinking_as_text);
    try putBoolValue(allocator, &object, "requiresToolResultName", compat.requires_tool_result_name);
    try putObjectValue(allocator, &object, "openRouterRouting", if (compat.open_router_routing) |routing| try provider_json.cloneValue(allocator, routing) else try emptyObjectValue(allocator));
    try putBoolValue(allocator, &object, "sendSessionAffinityHeaders", compat.send_session_affinity_headers);
    try putBoolValue(allocator, &object, "supportsDeveloperRole", compat.supports_developer_role);
    try putBoolValue(allocator, &object, "supportsLongCacheRetention", compat.supports_long_cache_retention);
    try putBoolValue(allocator, &object, "supportsReasoningEffort", compat.supports_reasoning_effort);
    try putBoolValue(allocator, &object, "supportsStore", compat.supports_store);
    try putBoolValue(allocator, &object, "supportsStrictMode", compat.supports_strict_mode);
    try putBoolValue(allocator, &object, "supportsUsageInStreaming", compat.supports_usage_in_streaming);
    try putStringValue(allocator, &object, "maxTokensField", compat.max_tokens_field);
    try putStringValue(allocator, &object, "thinkingFormat", compat.thinking_format);
    try putObjectValue(allocator, &object, "vercelGatewayRouting", if (compat.vercel_gateway_routing) |routing| try provider_json.cloneValue(allocator, routing) else try emptyObjectValue(allocator));
    try putBoolValue(allocator, &object, "zaiToolStream", compat.zai_tool_stream);
    if (compat.cache_control_format) |format| {
        try putStringValue(allocator, &object, "cacheControlFormat", format);
    }

    return .{ .object = object };
}

fn putBoolValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: bool) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .bool = value });
}

fn putStringValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .string = try allocator.dupe(u8, value) });
}

fn putObjectValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    try object.put(allocator, try allocator.dupe(u8, key), value);
}

fn emptyObjectValue(allocator: std.mem.Allocator) !std.json.Value {
    return provider_json.emptyObjectValue(allocator);
}

fn normalizeToolCallId(
    allocator: std.mem.Allocator,
    id: []const u8,
    model: types.Model,
    source: types.AssistantMessage,
) ![]const u8 {
    _ = source;

    if (std.mem.indexOfScalar(u8, id, '|')) |separator_index| {
        const prefix = id[0..separator_index];
        return sanitizeOpenAIToolCallId(allocator, prefix);
    }

    if (std.mem.eql(u8, model.provider, "openai")) {
        const trimmed = if (id.len > 40) id[0..40] else id;
        return try allocator.dupe(u8, trimmed);
    }

    return try allocator.dupe(u8, id);
}

fn sanitizeOpenAIToolCallId(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (id) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-') {
            try result.append(allocator, byte);
        } else {
            try result.append(allocator, '_');
        }
        if (result.items.len == 40) break;
    }

    return try result.toOwnedSlice(allocator);
}

fn buildUserMessage(allocator: std.mem.Allocator, model: types.Model, user_msg: types.UserMessage) !std.json.Value {
    // Check if message contains images
    var has_images = false;
    for (user_msg.content) |block| {
        if (block == .image) {
            has_images = true;
            break;
        }
    }

    // Check if model supports images
    var model_supports_images = false;
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) {
            model_supports_images = true;
            break;
        }
    }

    if (has_images and model_supports_images) {
        // Build content as array of parts
        var content_parts = std.json.Array.init(allocator);
        errdefer content_parts.deinit();

        for (user_msg.content) |block| {
            switch (block) {
                .text => |text| {
                    const sanitized = try sanitizeSurrogates(allocator, text.text);
                    defer allocator.free(sanitized);
                    var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    errdefer part.deinit(allocator);
                    try part.put(allocator, try allocator.dupe(u8, "type"), std.json.Value{ .string = try allocator.dupe(u8, "text") });
                    try part.put(allocator, try allocator.dupe(u8, "text"), std.json.Value{ .string = try allocator.dupe(u8, sanitized) });
                    try content_parts.append(std.json.Value{ .object = part });
                },
                .image => |image| {
                    var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    errdefer part.deinit(allocator);
                    try part.put(allocator, try allocator.dupe(u8, "type"), std.json.Value{ .string = try allocator.dupe(u8, "image_url") });

                    const url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ image.mime_type, image.data });
                    defer allocator.free(url);

                    var image_url = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    errdefer image_url.deinit(allocator);
                    try image_url.put(allocator, try allocator.dupe(u8, "url"), std.json.Value{ .string = try allocator.dupe(u8, url) });
                    try part.put(allocator, try allocator.dupe(u8, "image_url"), std.json.Value{ .object = image_url });
                    try content_parts.append(std.json.Value{ .object = part });
                },
                .thinking, .tool_call => continue, // User messages shouldn't have thinking/tool-call blocks
            }
        }

        var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        errdefer obj.deinit(allocator);
        try obj.put(allocator, try allocator.dupe(u8, "role"), std.json.Value{ .string = try allocator.dupe(u8, "user") });
        try obj.put(allocator, try allocator.dupe(u8, "content"), std.json.Value{ .array = content_parts });
        return std.json.Value{ .object = obj };
    } else {
        // Plain text content
        var text_parts = std.ArrayList(u8).empty;
        defer text_parts.deinit(allocator);

        for (user_msg.content) |block| {
            switch (block) {
                .text => |text| {
                    if (text_parts.items.len > 0) {
                        try text_parts.appendSlice(allocator, "\n");
                    }
                    try text_parts.appendSlice(allocator, text.text);
                },
                .image => {
                    if (!model_supports_images) {
                        if (text_parts.items.len > 0) {
                            try text_parts.appendSlice(allocator, "\n");
                        }
                        try text_parts.appendSlice(allocator, "(image omitted: model does not support images)");
                    }
                },
                .thinking, .tool_call => continue,
            }
        }

        const sanitized = try sanitizeSurrogates(allocator, text_parts.items);
        defer allocator.free(sanitized);
        return std.json.Value{ .object = try buildMessageObject(allocator, "user", sanitized) };
    }
}

pub fn buildAssistantMessage(allocator: std.mem.Allocator, model: types.Model, assistant_msg: types.AssistantMessage) !?std.json.Value {
    const compat = getCompat(model);
    const tool_calls_source = if (types.hasInlineToolCalls(assistant_msg))
        try types.collectAssistantToolCalls(allocator, assistant_msg)
    else
        null;
    defer if (tool_calls_source) |calls| allocator.free(calls);
    const assistant_tool_calls = tool_calls_source orelse assistant_msg.tool_calls;
    const has_tool_calls = if (assistant_tool_calls) |calls| calls.len > 0 else false;

    var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer obj.deinit(allocator);
    try obj.put(allocator, try allocator.dupe(u8, "role"), std.json.Value{ .string = try allocator.dupe(u8, "assistant") });

    var text_parts = std.ArrayList(u8).empty;
    defer text_parts.deinit(allocator);
    var thinking_parts = std.ArrayList(u8).empty;
    defer thinking_parts.deinit(allocator);
    var reasoning_field_name: ?[]const u8 = null;

    for (assistant_msg.content) |block| {
        switch (block) {
            .text => |text| {
                try text_parts.appendSlice(allocator, text.text);
            },
            .thinking => |thinking| {
                const signature = types.thinkingSignature(thinking);
                const trimmed = std.mem.trim(u8, thinking.thinking, " \t\r\n");
                if (trimmed.len == 0 and signature == null) continue;
                if (compat.requires_thinking_as_text) {
                    if (trimmed.len == 0) continue;
                    if (thinking_parts.items.len > 0) {
                        try thinking_parts.appendSlice(allocator, "\n\n");
                    }
                    try thinking_parts.appendSlice(allocator, thinking.thinking);
                } else if (signature) |value| {
                    if (trimmed.len > 0) {
                        if (reasoning_field_name == null) reasoning_field_name = value;
                        if (reasoning_field_name != null and std.mem.eql(u8, reasoning_field_name.?, value)) {
                            if (thinking_parts.items.len > 0) {
                                try thinking_parts.appendSlice(allocator, "\n");
                            }
                            try thinking_parts.appendSlice(allocator, thinking.thinking);
                        }
                    }
                }
            },
            .image, .tool_call => continue,
        }
    }

    if (compat.requires_thinking_as_text and thinking_parts.items.len > 0) {
        var content_parts = std.json.Array.init(allocator);
        errdefer content_parts.deinit();

        const sanitized_thinking = try sanitizeSurrogates(allocator, thinking_parts.items);
        defer allocator.free(sanitized_thinking);
        var thinking_part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        errdefer thinking_part.deinit(allocator);
        try thinking_part.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "text") });
        try thinking_part.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, sanitized_thinking) });
        try content_parts.append(.{ .object = thinking_part });

        if (text_parts.items.len > 0) {
            const sanitized_text = try sanitizeSurrogates(allocator, text_parts.items);
            defer allocator.free(sanitized_text);
            var text_part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            errdefer text_part.deinit(allocator);
            try text_part.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "text") });
            try text_part.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, sanitized_text) });
            try content_parts.append(.{ .object = text_part });
        }

        try obj.put(allocator, try allocator.dupe(u8, "content"), .{ .array = content_parts });
    } else {
        const content = if (text_parts.items.len > 0) try sanitizeSurrogates(allocator, text_parts.items) else try allocator.dupe(u8, "");
        defer allocator.free(content);
        if (content.len == 0 and has_tool_calls) {
            if (compat.requires_assistant_after_tool_result) {
                try obj.put(allocator, try allocator.dupe(u8, "content"), std.json.Value{ .string = try allocator.dupe(u8, "") });
            } else {
                try obj.put(allocator, try allocator.dupe(u8, "content"), .null);
            }
        } else if (content.len > 0) {
            try obj.put(allocator, try allocator.dupe(u8, "content"), std.json.Value{ .string = try allocator.dupe(u8, content) });
        } else if (compat.requires_assistant_after_tool_result) {
            try obj.put(allocator, try allocator.dupe(u8, "content"), std.json.Value{ .string = try allocator.dupe(u8, "") });
        } else {
            try obj.put(allocator, try allocator.dupe(u8, "content"), .null);
        }
    }

    if (!compat.requires_thinking_as_text and thinking_parts.items.len > 0 and reasoning_field_name != null) {
        const sanitized_reasoning = try sanitizeSurrogates(allocator, thinking_parts.items);
        defer allocator.free(sanitized_reasoning);
        try obj.put(
            allocator,
            try allocator.dupe(u8, reasoning_field_name.?),
            std.json.Value{ .string = try allocator.dupe(u8, sanitized_reasoning) },
        );
    } else if (compat.requires_reasoning_content_on_assistant_messages and model.reasoning and obj.get("reasoning_content") == null) {
        try obj.put(allocator, try allocator.dupe(u8, "reasoning_content"), std.json.Value{ .string = try allocator.dupe(u8, "") });
    }

    if (assistant_tool_calls) |tool_calls| {
        try appendAssistantToolCalls(allocator, &obj, tool_calls);
    }

    const content_value = obj.get("content") orelse .null;
    const has_content = switch (content_value) {
        .string => |content| content.len > 0,
        .array => |content| content.items.len > 0,
        else => false,
    };
    if (!has_content and !has_tool_calls) {
        provider_json.freeValue(allocator, .{ .object = obj });
        return null;
    }

    return std.json.Value{ .object = obj };
}

fn appendAssistantToolCalls(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    tool_calls: []const types.ToolCall,
) !void {
    var tc_array = std.json.Array.init(allocator);
    errdefer tc_array.deinit();
    for (tool_calls) |tc| {
        var tc_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        errdefer tc_obj.deinit(allocator);
        try tc_obj.put(allocator, try allocator.dupe(u8, "id"), std.json.Value{ .string = try allocator.dupe(u8, tc.id) });
        try tc_obj.put(allocator, try allocator.dupe(u8, "type"), std.json.Value{ .string = try allocator.dupe(u8, "function") });

        var func_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        errdefer func_obj.deinit(allocator);
        try func_obj.put(allocator, try allocator.dupe(u8, "name"), std.json.Value{ .string = try allocator.dupe(u8, tc.name) });

        const args_owned = try std.json.Stringify.valueAlloc(allocator, tc.arguments, .{});
        defer allocator.free(args_owned);
        try func_obj.put(allocator, try allocator.dupe(u8, "arguments"), std.json.Value{ .string = try allocator.dupe(u8, args_owned) });

        try tc_obj.put(allocator, try allocator.dupe(u8, "function"), std.json.Value{ .object = func_obj });
        try tc_array.append(std.json.Value{ .object = tc_obj });
    }
    try obj.put(allocator, try allocator.dupe(u8, "tool_calls"), std.json.Value{ .array = tc_array });
    try appendAssistantReasoningDetails(allocator, obj, tool_calls);
}

fn appendAssistantReasoningDetails(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    tool_calls: []const types.ToolCall,
) !void {
    var reasoning_details = std.json.Array.init(allocator);
    for (tool_calls) |tc| {
        if (tc.thought_signature) |sig| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, sig, .{}) catch continue;
            defer parsed.deinit();
            if (isFalseyJsonValue(parsed.value)) continue;
            reasoning_details.append(try provider_json.cloneValue(allocator, parsed.value)) catch continue;
        }
    }
    if (reasoning_details.items.len > 0) {
        try obj.put(allocator, try allocator.dupe(u8, "reasoning_details"), std.json.Value{ .array = reasoning_details });
    } else {
        reasoning_details.deinit();
    }
}

const ToolResultAppendResult = struct {
    next_index: usize,
    appended_image_user: bool,
};

fn appendToolResultMessages(
    allocator: std.mem.Allocator,
    messages: *std.json.Array,
    model: types.Model,
    transformed_messages: []const types.Message,
    start_index: usize,
) !ToolResultAppendResult {
    const compat = getCompat(model);
    var image_parts = std.json.Array.init(allocator);
    defer image_parts.deinit();

    var index = start_index;
    while (index < transformed_messages.len and transformed_messages[index] == .tool_result) : (index += 1) {
        const tool_result = transformed_messages[index].tool_result;
        try messages.append(try buildToolResultMessage(allocator, model, tool_result));
        try appendToolResultImageParts(allocator, model, tool_result, &image_parts);
    }

    if (image_parts.items.len > 0) {
        if (compat.requires_assistant_after_tool_result) {
            try messages.append(.{ .object = try buildMessageObject(allocator, "assistant", "I have processed the tool results.") });
        }
        try messages.append(try buildToolResultImageUserMessage(allocator, image_parts));
        return .{ .next_index = index, .appended_image_user = true };
    }
    return .{ .next_index = index, .appended_image_user = false };
}

fn buildToolResultMessage(allocator: std.mem.Allocator, model: types.Model, tool_result: types.ToolResultMessage) !std.json.Value {
    const compat = getCompat(model);
    var text_parts = std.ArrayList(u8).empty;
    defer text_parts.deinit(allocator);

    for (tool_result.content) |block| {
        switch (block) {
            .text => |text| {
                if (text_parts.items.len > 0) {
                    try text_parts.appendSlice(allocator, "\n");
                }
                try text_parts.appendSlice(allocator, text.text);
            },
            .image => {},
            .thinking, .tool_call => continue,
        }
    }

    const content = if (text_parts.items.len > 0)
        try sanitizeSurrogates(allocator, text_parts.items)
    else
        try allocator.dupe(u8, "(see attached image)");
    defer allocator.free(content);

    var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer obj.deinit(allocator);
    try obj.put(allocator, try allocator.dupe(u8, "role"), std.json.Value{ .string = try allocator.dupe(u8, "tool") });
    try obj.put(allocator, try allocator.dupe(u8, "content"), std.json.Value{ .string = try allocator.dupe(u8, content) });
    try obj.put(allocator, try allocator.dupe(u8, "tool_call_id"), std.json.Value{ .string = try allocator.dupe(u8, tool_result.tool_call_id) });

    // Add name if required by provider
    if (compat.requires_tool_result_name and tool_result.tool_name.len > 0) {
        try obj.put(allocator, try allocator.dupe(u8, "name"), std.json.Value{ .string = try allocator.dupe(u8, tool_result.tool_name) });
    }

    return std.json.Value{ .object = obj };
}

fn appendToolResultImageParts(
    allocator: std.mem.Allocator,
    model: types.Model,
    tool_result: types.ToolResultMessage,
    image_parts: *std.json.Array,
) !void {
    var model_supports_images = false;
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) {
            model_supports_images = true;
            break;
        }
    }
    if (!model_supports_images) return;

    for (tool_result.content) |block| {
        if (block != .image) continue;
        var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        errdefer part.deinit(allocator);
        try part.put(allocator, try allocator.dupe(u8, "type"), std.json.Value{ .string = try allocator.dupe(u8, "image_url") });

        const url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ block.image.mime_type, block.image.data });
        defer allocator.free(url);

        var image_url = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        errdefer image_url.deinit(allocator);
        try image_url.put(allocator, try allocator.dupe(u8, "url"), std.json.Value{ .string = try allocator.dupe(u8, url) });
        try part.put(allocator, try allocator.dupe(u8, "image_url"), .{ .object = image_url });
        try image_parts.append(.{ .object = part });
    }
}

fn buildToolResultImageUserMessage(
    allocator: std.mem.Allocator,
    image_parts: std.json.Array,
) !std.json.Value {
    var content_parts = std.json.Array.init(allocator);
    errdefer content_parts.deinit();

    var text_part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer text_part.deinit(allocator);
    try text_part.put(allocator, try allocator.dupe(u8, "type"), std.json.Value{ .string = try allocator.dupe(u8, "text") });
    try text_part.put(allocator, try allocator.dupe(u8, "text"), std.json.Value{ .string = try allocator.dupe(u8, "Attached image(s) from tool result:") });
    try content_parts.append(.{ .object = text_part });

    for (image_parts.items) |part| {
        try content_parts.append(part);
    }

    var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer obj.deinit(allocator);
    try obj.put(allocator, try allocator.dupe(u8, "role"), std.json.Value{ .string = try allocator.dupe(u8, "user") });
    try obj.put(allocator, try allocator.dupe(u8, "content"), .{ .array = content_parts });
    return .{ .object = obj };
}

fn buildToolObject(allocator: std.mem.Allocator, tool: types.Tool, compat: OpenAICompat) !std.json.Value {
    var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer obj.deinit(allocator);
    try obj.put(allocator, try allocator.dupe(u8, "type"), std.json.Value{ .string = try allocator.dupe(u8, "function") });

    var func_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer func_obj.deinit(allocator);
    try func_obj.put(allocator, try allocator.dupe(u8, "name"), std.json.Value{ .string = try allocator.dupe(u8, tool.name) });
    try func_obj.put(allocator, try allocator.dupe(u8, "description"), std.json.Value{ .string = try allocator.dupe(u8, tool.description) });
    try func_obj.put(allocator, try allocator.dupe(u8, "parameters"), try provider_json.cloneValue(allocator, tool.parameters));
    if (compat.supports_strict_mode) {
        try func_obj.put(allocator, try allocator.dupe(u8, "strict"), std.json.Value{ .bool = false });
    }

    try obj.put(allocator, try allocator.dupe(u8, "function"), std.json.Value{ .object = func_obj });
    return std.json.Value{ .object = obj };
}

fn buildMessageObject(allocator: std.mem.Allocator, role: []const u8, content: []const u8) !std.json.ObjectMap {
    var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer obj.deinit(allocator);
    try obj.put(allocator, try allocator.dupe(u8, "role"), std.json.Value{ .string = try allocator.dupe(u8, role) });
    try obj.put(allocator, try allocator.dupe(u8, "content"), std.json.Value{ .string = try allocator.dupe(u8, content) });
    return obj;
}

test "Together compat uses non-standard chat payload fields" {
    const allocator = std.testing.allocator;

    var tool_schema = std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) };
    defer provider_json.freeValue(allocator, tool_schema);
    try tool_schema.object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });

    const model = types.Model{
        .id = "moonshotai/Kimi-K2.6",
        .name = "Kimi K2.6",
        .api = "openai-completions",
        .provider = "together",
        .base_url = "https://api.together.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 262144,
        .max_tokens = 131000,
    };
    const context = types.Context{
        .system_prompt = "Follow instructions.",
        .messages = &[_]types.Message{},
        .tools = &[_]types.Tool{.{
            .name = "lookup",
            .description = "Look up data",
            .parameters = tool_schema,
        }},
    };

    const payload = try buildRequestPayloadWithCacheRetentionEnv(allocator, model, context, .{
        .max_tokens = 256,
        .session_id = "together-session",
        .cache_retention = .long,
        .provider = .{ .openai = .{ .reasoning_effort = "high" } },
    }, null);
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expect(payload.object.get("store") == null);
    try std.testing.expect(payload.object.get("prompt_cache_key") == null);
    try std.testing.expect(payload.object.get("prompt_cache_retention") == null);
    try std.testing.expect(payload.object.get("max_completion_tokens") == null);
    try std.testing.expectEqual(@as(i64, 256), payload.object.get("max_tokens").?.integer);
    try std.testing.expect(payload.object.get("reasoning_effort") == null);
    try std.testing.expectEqual(true, payload.object.get("reasoning").?.object.get("enabled").?.bool);

    const messages = payload.object.get("messages").?.array.items;
    try std.testing.expectEqualStrings("system", messages[0].object.get("role").?.string);

    const tool = payload.object.get("tools").?.array.items[0].object;
    const function = tool.get("function").?.object;
    try std.testing.expect(function.get("strict") == null);
}

test "Together reasoning payload preserves supported mapped effort" {
    const allocator = std.testing.allocator;

    var compat = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try compat.put(allocator, try allocator.dupe(u8, "thinkingFormat"), .{ .string = try allocator.dupe(u8, "together") });
    try compat.put(allocator, try allocator.dupe(u8, "supportsReasoningEffort"), .{ .bool = true });
    const compat_value = std.json.Value{ .object = compat };
    defer provider_json.freeValue(allocator, compat_value);

    const model = types.Model{
        .id = "deepseek-ai/DeepSeek-V4-Pro",
        .name = "DeepSeek V4 Pro",
        .api = "openai-completions",
        .provider = "custom-provider",
        .base_url = "https://api.together.xyz/v1",
        .reasoning = true,
        .thinking_level_map = .{ .high = .{ .mapped = "max" } },
        .input_types = &[_][]const u8{"text"},
        .context_window = 512000,
        .max_tokens = 384000,
        .compat = compat_value,
    };
    const context = types.Context{ .messages = &[_]types.Message{} };

    const enabled_payload = try buildRequestPayload(allocator, model, context, .{
        .provider = .{ .openai = .{ .reasoning_effort = "high" } },
    });
    defer provider_json.freeValue(allocator, enabled_payload);
    try std.testing.expectEqual(true, enabled_payload.object.get("reasoning").?.object.get("enabled").?.bool);
    try std.testing.expectEqualStrings("max", enabled_payload.object.get("reasoning_effort").?.string);

    const disabled_payload = try buildRequestPayload(allocator, model, context, null);
    defer provider_json.freeValue(allocator, disabled_payload);
    try std.testing.expectEqual(false, disabled_payload.object.get("reasoning").?.object.get("enabled").?.bool);
    try std.testing.expect(disabled_payload.object.get("reasoning_effort") == null);
}
