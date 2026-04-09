const std = @import("std");
const ai = @import("ai");
const types = @import("types.zig");

/// Proxy stream options for routing LLM calls through a server
pub const ProxyStreamOptions = struct {
    base: ai.SimpleStreamOptions = .{},
    auth_token: []const u8,
    proxy_url: []const u8,
};

/// Proxy event types - server sends these with partial field stripped to reduce bandwidth
pub const ProxyAssistantMessageEvent = union(enum) {
    start,
    text_start: struct { content_index: usize },
    text_delta: struct { content_index: usize, delta: []const u8 },
    text_end: struct { content_index: usize, content_signature: ?[]const u8 = null },
    thinking_start: struct { content_index: usize },
    thinking_delta: struct { content_index: usize, delta: []const u8 },
    thinking_end: struct { content_index: usize, content_signature: ?[]const u8 = null },
    toolcall_start: struct { content_index: usize, id: []const u8, tool_name: []const u8 },
    toolcall_delta: struct { content_index: usize, delta: []const u8 },
    toolcall_end: struct { content_index: usize },
    done: struct { reason: ai.StopReason, usage: ai.Usage },
    err_event: struct { reason: ai.StopReason, error_message: ?[]const u8 = null, usage: ai.Usage },
};

/// Stream function that proxies through a server instead of calling LLM providers directly
/// The server strips the partial field from delta events to reduce bandwidth
/// We reconstruct the partial message client-side
pub fn streamProxy(
    model: ai.Model,
    context: ai.Context,
    options: ProxyStreamOptions,
) ai.AssistantMessageEventStream {
    // TODO: Implement full proxy stream with HTTP client
    // For now, return a faux stream as placeholder
    return ai.faux_provider.streamSimpleFaux(model, context, .{ .base = options.base });
}

/// Process a proxy event and update the partial message
fn processProxyEvent(
    proxy_event: ProxyAssistantMessageEvent,
    partial: *ai.AssistantMessage,
) ?ai.AssistantMessageEvent {
    switch (proxy_event) {
        .start => return ai.AssistantMessageEvent{ .start = .{ .partial = partial.* } },

        .text_start => |ev| {
            if (ev.content_index >= partial.content.len) {
                // Extend content array
                // Note: In real implementation, we'd need allocator
            }
            return ai.AssistantMessageEvent{ .text_start = .{ .content_index = ev.content_index, .partial = partial.* } };
        },

        .text_delta => |ev| {
            // Append delta to text content
            // Note: In real implementation, we'd need allocator to extend strings
            return ai.AssistantMessageEvent{ .text_delta = .{ .content_index = ev.content_index, .delta = ev.delta, .partial = partial.* } };
        },

        .text_end => |ev| {
            return ai.AssistantMessageEvent{ .text_end = .{ .content_index = ev.content_index, .content = "", .partial = partial.* } };
        },

        .thinking_start => |ev| {
            return ai.AssistantMessageEvent{ .thinking_start = .{ .content_index = ev.content_index, .partial = partial.* } };
        },

        .thinking_delta => |ev| {
            return ai.AssistantMessageEvent{ .thinking_delta = .{ .content_index = ev.content_index, .delta = ev.delta, .partial = partial.* } };
        },

        .thinking_end => |ev| {
            return ai.AssistantMessageEvent{ .thinking_end = .{ .content_index = ev.content_index, .content = "", .partial = partial.* } };
        },

        .toolcall_start => |ev| {
            return ai.AssistantMessageEvent{ .toolcall_start = .{ .content_index = ev.content_index, .partial = partial.* } };
        },

        .toolcall_delta => |ev| {
            return ai.AssistantMessageEvent{ .toolcall_delta = .{ .content_index = ev.content_index, .delta = ev.delta, .partial = partial.* } };
        },

        .toolcall_end => |ev| {
            return ai.AssistantMessageEvent{ .toolcall_end = .{ .content_index = ev.content_index, .partial = partial.* } };
        },

        .done => |ev| {
            partial.stop_reason = ev.reason;
            partial.usage = ev.usage;
            return ai.AssistantMessageEvent{ .done = .{ .reason = ev.reason, .message = partial.* } };
        },

        .err_event => |ev| {
            partial.stop_reason = ev.reason;
            partial.error_message = ev.error_message;
            partial.usage = ev.usage;
            return ai.AssistantMessageEvent{ .err_event = .{ .reason = ev.reason, .err_msg = partial.* } };
        },
    }
}

test "proxy types compile" {
    const opts = ProxyStreamOptions{
        .auth_token = "test-token",
        .proxy_url = "https://example.com",
    };
    _ = opts;

    const ev = ProxyAssistantMessageEvent{ .start = {} };
    _ = ev;
}
