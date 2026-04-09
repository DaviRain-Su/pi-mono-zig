const std = @import("std");
const types = @import("types.zig");

pub fn buildBaseOptions(model: types.Model, options: ?types.SimpleStreamOptions, api_key: ?[]const u8) types.StreamOptions {
    const opts = options orelse types.SimpleStreamOptions{};
    return .{
        .temperature = opts.base.temperature,
        .max_tokens = opts.base.max_tokens orelse @min(model.max_tokens, 32000),
        .api_key = api_key orelse opts.base.api_key,
        .cache_retention = opts.base.cache_retention,
        .session_id = opts.base.session_id,
        .headers = opts.base.headers,
        .metadata = opts.base.metadata,
        .max_retry_delay_ms = opts.base.max_retry_delay_ms,
    };
}

pub fn clampReasoning(effort: ?types.ThinkingLevel) ?types.ThinkingLevel {
    if (effort) |e| {
        if (e == .xhigh) return .high;
        return e;
    }
    return null;
}

pub fn adjustMaxTokensForThinking(
    base_max_tokens: u32,
    model_max_tokens: u32,
    reasoning_level: types.ThinkingLevel,
    custom_budgets: ?types.ThinkingBudgets,
) struct { max_tokens: u32, thinking_budget: u32 } {
    const defaults = types.ThinkingBudgets{};
    const budgets = custom_budgets orelse defaults;

    const min_output_tokens: u32 = 1024;
    const level = clampReasoning(reasoning_level) orelse reasoning_level;
    const thinking_budget = switch (level) {
        .minimal => budgets.minimal,
        .low => budgets.low,
        .medium => budgets.medium,
        .high => budgets.high,
        .xhigh => budgets.high,
    };

    const max_tokens = @min(base_max_tokens + thinking_budget, model_max_tokens);
    if (max_tokens <= thinking_budget) {
        return .{
            .max_tokens = max_tokens,
            .thinking_budget = if (max_tokens > min_output_tokens) max_tokens - min_output_tokens else 0,
        };
    }

    return .{ .max_tokens = max_tokens, .thinking_budget = thinking_budget };
}

test "buildBaseOptions defaults" {
    const model = types.Model{
        .id = "test",
        .name = "Test",
        .api = .{ .known = .openai_completions },
        .provider = .{ .known = .openai },
        .max_tokens = 64000,
    };
    const base = buildBaseOptions(model, null, null);
    try std.testing.expectEqual(@as(?f32, null), base.temperature);
    try std.testing.expectEqual(@as(u32, 32000), base.max_tokens.?);
}

test "adjustMaxTokensForThinking" {
    const result = adjustMaxTokensForThinking(1000, 50000, .high, null);
    try std.testing.expect(result.max_tokens > 1000);
    try std.testing.expectEqual(@as(u32, 16384), result.thinking_budget);
}

test "adjustMaxTokensForThinking clamp" {
    const result = adjustMaxTokensForThinking(100, 20000, .high, null);
    // max_tokens = min(100 + 16384, 20000) = 16484
    // > 16384, so thinking_budget stays 16384
    try std.testing.expect(result.max_tokens > result.thinking_budget);
}

test "clampReasoning" {
    try std.testing.expectEqual(@as(?types.ThinkingLevel, .high), clampReasoning(.xhigh));
    try std.testing.expectEqual(@as(?types.ThinkingLevel, .medium), clampReasoning(.medium));
    try std.testing.expectEqual(@as(?types.ThinkingLevel, null), clampReasoning(null));
}

test "adjustMaxTokensForThinking with custom budgets" {
    const custom = types.ThinkingBudgets{ .minimal = 512, .low = 1024, .medium = 4096, .high = 8192 };
    const result = adjustMaxTokensForThinking(2000, 50000, .medium, custom);
    try std.testing.expectEqual(@as(u32, 4096), result.thinking_budget);
    try std.testing.expectEqual(@as(u32, 6096), result.max_tokens);
}

test "adjustMaxTokensForThinking forces clamp when max_tokens <= thinking_budget" {
    const result = adjustMaxTokensForThinking(100, 1000, .high, null);
    // max_tokens = min(100 + 16384, 1000) = 1000
    // <= 16384, so thinking_budget = 1000 - 1024 = 0 (capped at 0)
    try std.testing.expectEqual(@as(u32, 1000), result.max_tokens);
    try std.testing.expectEqual(@as(u32, 0), result.thinking_budget);
}

test "buildBaseOptions passes through api_key and temperature" {
    const model = types.Model{
        .id = "test",
        .name = "Test",
        .api = .{ .known = .openai_completions },
        .provider = .{ .known = .openai },
        .max_tokens = 64000,
    };
    const opts = types.SimpleStreamOptions{ .base = .{ .temperature = 0.7, .max_tokens = 4096, .api_key = "key123" } };
    const base = buildBaseOptions(model, opts, null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), base.temperature.?, 0.001);
    try std.testing.expectEqual(@as(u32, 4096), base.max_tokens.?);
    try std.testing.expectEqualStrings("key123", base.api_key.?);
}

test "buildBaseOptions uses provided api_key over options" {
    const model = types.Model{
        .id = "test",
        .name = "Test",
        .api = .{ .known = .openai_completions },
        .provider = .{ .known = .openai },
        .max_tokens = 64000,
    };
    const opts = types.SimpleStreamOptions{ .base = .{ .api_key = "opt_key" } };
    const base = buildBaseOptions(model, opts, "arg_key");
    try std.testing.expectEqualStrings("arg_key", base.api_key.?);
}
