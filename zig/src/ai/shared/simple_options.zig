const std = @import("std");
const types = @import("../types.zig");

pub const AdjustedThinkingTokens = struct {
    max_tokens: u32,
    thinking_budget: u32,
};

pub fn buildBaseOptions(
    model: types.Model,
    options: ?types.SimpleStreamOptions,
    api_key: ?[]const u8,
) types.StreamOptions {
    return .{
        .temperature = if (options) |value| value.temperature else null,
        .max_tokens = if (options) |value|
            value.max_tokens orelse defaultMaxTokens(model)
        else
            defaultMaxTokens(model),
        .api_key = api_key orelse if (options) |value| value.api_key else null,
        .transport = if (options) |value| value.transport else .auto,
        .cache_retention = if (options) |value| value.cache_retention else .unset,
        .session_id = if (options) |value| value.session_id else null,
        .headers = if (options) |value| value.headers else null,
        .on_payload = if (options) |value| value.on_payload else null,
        .on_response = if (options) |value| value.on_response else null,
        .signal = if (options) |value| value.signal else null,
        .max_retry_delay_ms = if (options) |value| value.max_retry_delay_ms else 60000,
        .metadata = if (options) |value| value.metadata else null,
        .google_tool_choice = if (options) |value| value.google_tool_choice else null,
        .google_thinking = if (options) |value| value.google_thinking else null,
        .mistral_prompt_mode = if (options) |value| value.mistral_prompt_mode else null,
        .mistral_reasoning_effort = if (options) |value| value.mistral_reasoning_effort else null,
    };
}

pub fn clampReasoning(effort: ?types.ThinkingLevel) ?types.ThinkingLevel {
    return switch (effort orelse return null) {
        .xhigh => .high,
        else => |value| value,
    };
}

pub fn adjustMaxTokensForThinking(
    base_max_tokens: u32,
    model_max_tokens: u32,
    reasoning_level: types.ThinkingLevel,
    custom_budgets: ?types.ThinkingBudgets,
) AdjustedThinkingTokens {
    const budgets = custom_budgets orelse types.ThinkingBudgets{};
    const min_output_tokens: u32 = 1024;
    const level = clampReasoning(reasoning_level).?;
    var thinking_budget = switch (level) {
        .minimal => budgets.minimal,
        .low => budgets.low,
        .medium => budgets.medium,
        .high, .xhigh => budgets.high,
    };

    const max_tokens = @min(base_max_tokens +| thinking_budget, model_max_tokens);
    if (max_tokens <= thinking_budget) {
        thinking_budget = if (max_tokens > min_output_tokens) max_tokens - min_output_tokens else 0;
    }

    return .{
        .max_tokens = max_tokens,
        .thinking_budget = thinking_budget,
    };
}

fn defaultMaxTokens(model: types.Model) ?u32 {
    if (model.max_tokens == 0) return null;
    return @min(model.max_tokens, @as(u32, 32000));
}

test "buildBaseOptions applies defaults and explicit api key override" {
    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const options = types.SimpleStreamOptions{
        .temperature = 0.25,
        .api_key = "fallback-key",
        .cache_retention = .long,
        .session_id = "session-123",
        .max_retry_delay_ms = 1234,
        .google_tool_choice = "auto",
    };

    const base = buildBaseOptions(model, options, "provided-key");
    try std.testing.expectEqual(@as(?f32, 0.25), base.temperature);
    try std.testing.expectEqual(@as(?u32, 32000), base.max_tokens);
    try std.testing.expectEqualStrings("provided-key", base.api_key.?);
    try std.testing.expectEqual(types.CacheRetention.long, base.cache_retention);
    try std.testing.expectEqualStrings("session-123", base.session_id.?);
    try std.testing.expectEqual(@as(u32, 1234), base.max_retry_delay_ms);
    try std.testing.expectEqualStrings("auto", base.google_tool_choice.?);
}

test "clampReasoning downgrades xhigh only" {
    try std.testing.expectEqual(@as(?types.ThinkingLevel, .high), clampReasoning(.xhigh));
    try std.testing.expectEqual(@as(?types.ThinkingLevel, .medium), clampReasoning(.medium));
    try std.testing.expectEqual(@as(?types.ThinkingLevel, null), clampReasoning(null));
}

test "adjustMaxTokensForThinking uses default budgets" {
    const adjusted = adjustMaxTokensForThinking(4000, 10000, .medium, null);
    try std.testing.expectEqual(@as(u32, 10000), adjusted.max_tokens);
    try std.testing.expectEqual(@as(u32, 8192), adjusted.thinking_budget);
}

test "adjustMaxTokensForThinking preserves output space when capped" {
    const adjusted = adjustMaxTokensForThinking(500, 900, .high, null);
    try std.testing.expectEqual(@as(u32, 900), adjusted.max_tokens);
    try std.testing.expectEqual(@as(u32, 0), adjusted.thinking_budget);
}
