const std = @import("std");
const types = @import("types.zig");

/// Check if an assistant message represents a context overflow error.
/// The optional context_window is used to detect silent overflow (e.g. z.ai style).
pub fn isContextOverflow(msg: types.AssistantMessage, context_window: ?u32) bool {
    if (msg.stop_reason != .err) {
        if (context_window) |cw| {
            const input_tokens = @as(u64, msg.usage.input) + @as(u64, msg.usage.cache_read);
            if (input_tokens > cw) return true;
        }
        return false;
    }

    const err_msg = msg.error_message orelse return false;

    // Exclude known non-overflow patterns first
    inline for (non_overflow_patterns) |pat| {
        if (containsIgnoreCase(err_msg, pat)) return false;
    }

    inline for (overflow_patterns) |pat| {
        if (containsIgnoreCase(err_msg, pat)) return true;
    }

    return false;
}

const overflow_patterns = [_][]const u8{
    "prompt is too long",                           // Anthropic token overflow
    "request_too_large",                            // Anthropic request byte-size overflow
    "input is too long for requested model",        // Amazon Bedrock
    "exceeds the context window",                   // OpenAI
    "input token count",                            // Google (pre-filter for "exceeds the maximum")
    "exceeds the maximum",                          // Generic / Google fallback
    "maximum prompt length",                        // xAI (Grok)
    "reduce the length of the messages",            // Groq
    "maximum context length",                       // OpenRouter
    "exceeds the limit of",                         // GitHub Copilot
    "exceeds the available context size",           // llama.cpp
    "greater than the context length",              // LM Studio
    "context window exceeds limit",                 // MiniMax
    "exceeded model token limit",                   // Kimi For Coding
    "too large for model",                          // Mistral
    "model_context_window_exceeded",                // z.ai non-standard
    "prompt too long",                              // Ollama
    "exceeded max context length",                  // Ollama variant
    "context length exceeded",                      // Generic fallback
    "too many tokens",                              // Generic fallback
    "token limit exceeded",                         // Generic fallback
    "no body",                                      // Cerebras fallback (400/413 with no body)
};

const non_overflow_patterns = [_][]const u8{
    "throttling error",
    "service unavailable",
    "rate limit",
    "too many requests",
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

test "isContextOverflow detects known patterns" {
    const model = types.Model{ .id = "test", .name = "T", .api = .{ .known = .faux }, .provider = .{ .known = .faux }, .max_tokens = 1000 };
    var msg = types.AssistantMessage{
        .role = "assistant",
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = .{},
        .stop_reason = .err,
        .error_message = "prompt is too long: 213462 tokens > 200000 maximum",
        .timestamp = 0,
    };
    try std.testing.expect(isContextOverflow(msg, null));

    msg.error_message = "Rate limit exceeded. Please retry.";
    try std.testing.expect(!isContextOverflow(msg, null));

    msg.error_message = "Your request exceeded model token limit: 100000";
    try std.testing.expect(isContextOverflow(msg, null));

    // silent overflow detection (z.ai style)
    msg.error_message = null;
    msg.stop_reason = .stop;
    msg.usage = types.Usage{ .input = 150000, .cache_read = 10000 };
    try std.testing.expect(isContextOverflow(msg, 131072));
    try std.testing.expect(!isContextOverflow(msg, 200000));
}
