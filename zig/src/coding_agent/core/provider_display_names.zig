const std = @import("std");

pub const ProviderDisplayName = struct {
    provider: []const u8,
    display_name: []const u8,
};

pub const BUILT_IN_PROVIDER_DISPLAY_NAMES: []const ProviderDisplayName = &.{
    .{ .provider = "anthropic", .display_name = "Anthropic" },
    .{ .provider = "amazon-bedrock", .display_name = "Amazon Bedrock" },
    .{ .provider = "azure-openai-responses", .display_name = "Azure OpenAI Responses" },
    .{ .provider = "cerebras", .display_name = "Cerebras" },
    .{ .provider = "cloudflare-ai-gateway", .display_name = "Cloudflare AI Gateway" },
    .{ .provider = "cloudflare-workers-ai", .display_name = "Cloudflare Workers AI" },
    .{ .provider = "deepseek", .display_name = "DeepSeek" },
    .{ .provider = "fireworks", .display_name = "Fireworks" },
    .{ .provider = "google", .display_name = "Google Gemini" },
    .{ .provider = "google-vertex", .display_name = "Google Vertex AI" },
    .{ .provider = "groq", .display_name = "Groq" },
    .{ .provider = "huggingface", .display_name = "Hugging Face" },
    .{ .provider = "kimi-coding", .display_name = "Kimi For Coding" },
    .{ .provider = "kimi-code-openai", .display_name = "Kimi Code (OpenAI Compatible)" },
    .{ .provider = "mistral", .display_name = "Mistral" },
    .{ .provider = "minimax", .display_name = "MiniMax" },
    .{ .provider = "minimax-cn", .display_name = "MiniMax (China)" },
    .{ .provider = "moonshotai", .display_name = "Moonshot AI" },
    .{ .provider = "moonshotai-cn", .display_name = "Moonshot AI (China)" },
    .{ .provider = "opencode", .display_name = "OpenCode Zen" },
    .{ .provider = "opencode-go", .display_name = "OpenCode Go" },
    .{ .provider = "openai", .display_name = "OpenAI" },
    .{ .provider = "openrouter", .display_name = "OpenRouter" },
    .{ .provider = "together", .display_name = "Together AI" },
    .{ .provider = "vercel-ai-gateway", .display_name = "Vercel AI Gateway" },
    .{ .provider = "xai", .display_name = "xAI" },
    .{ .provider = "zai", .display_name = "ZAI" },
    .{ .provider = "xiaomi", .display_name = "Xiaomi MiMo" },
    .{ .provider = "xiaomi-token-plan-cn", .display_name = "Xiaomi MiMo Token Plan (China)" },
    .{ .provider = "xiaomi-token-plan-ams", .display_name = "Xiaomi MiMo Token Plan (Amsterdam)" },
    .{ .provider = "xiaomi-token-plan-sgp", .display_name = "Xiaomi MiMo Token Plan (Singapore)" },
};

pub fn builtInProviderDisplayName(provider: []const u8) ?[]const u8 {
    for (BUILT_IN_PROVIDER_DISPLAY_NAMES) |entry| {
        if (std.mem.eql(u8, entry.provider, provider)) return entry.display_name;
    }
    return null;
}

test "builtInProviderDisplayName returns known provider names" {
    try std.testing.expectEqualStrings("OpenAI", builtInProviderDisplayName("openai").?);
    try std.testing.expectEqual(@as(?[]const u8, null), builtInProviderDisplayName("missing"));
}
