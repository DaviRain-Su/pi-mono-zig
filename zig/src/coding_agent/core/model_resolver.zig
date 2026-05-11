const std = @import("std");

pub const ResolveCliModelResult = struct {
    provider_name: ?[]const u8 = null,
    model_name: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
    warning: ?[]u8 = null,
    error_message: ?[]u8 = null,
    owned_model_name: ?[]u8 = null,

    pub fn deinit(self: *ResolveCliModelResult, allocator: std.mem.Allocator) void {
        if (self.warning) |warning| allocator.free(warning);
        if (self.error_message) |message| allocator.free(message);
        if (self.owned_model_name) |model_name| allocator.free(model_name);
        self.* = undefined;
    }
};

pub fn resolveCliModel(
    allocator: std.mem.Allocator,
    cli_provider: ?[]const u8,
    cli_model: ?[]const u8,
) !ResolveCliModelResult {
    _ = allocator;
    return .{
        .provider_name = cli_provider,
        .model_name = cli_model,
    };
}

pub const DefaultModelForProvider = struct {
    provider: []const u8,
    model: []const u8,
};

pub const default_model_per_provider = [_]DefaultModelForProvider{
    .{ .provider = "amazon-bedrock", .model = "us.anthropic.claude-opus-4-6-v1" },
    .{ .provider = "anthropic", .model = "claude-opus-4-7" },
    .{ .provider = "openai", .model = "gpt-5.4" },
    .{ .provider = "azure-openai-responses", .model = "gpt-5.4" },
    .{ .provider = "openai-codex", .model = "gpt-5.5" },
    .{ .provider = "deepseek", .model = "deepseek-v4-pro" },
    .{ .provider = "google", .model = "gemini-3.1-pro-preview" },
    .{ .provider = "google-vertex", .model = "gemini-3.1-pro-preview" },
    .{ .provider = "github-copilot", .model = "gpt-5.4" },
    .{ .provider = "openrouter", .model = "moonshotai/kimi-k2.6" },
    .{ .provider = "vercel-ai-gateway", .model = "zai/glm-5.1" },
    .{ .provider = "xai", .model = "grok-4.20-0309-reasoning" },
    .{ .provider = "groq", .model = "openai/gpt-oss-120b" },
    .{ .provider = "cerebras", .model = "zai-glm-4.7" },
    .{ .provider = "zai", .model = "glm-4.7" },
    .{ .provider = "mistral", .model = "devstral-medium-latest" },
    .{ .provider = "minimax", .model = "MiniMax-M2.7" },
    .{ .provider = "minimax-cn", .model = "MiniMax-M2.7" },
    .{ .provider = "moonshotai", .model = "kimi-k2.6" },
    .{ .provider = "moonshotai-cn", .model = "kimi-k2.6" },
    .{ .provider = "huggingface", .model = "moonshotai/Kimi-K2.6" },
    .{ .provider = "fireworks", .model = "accounts/fireworks/models/kimi-k2p6" },
    .{ .provider = "together", .model = "moonshotai/Kimi-K2.6" },
    .{ .provider = "opencode", .model = "kimi-k2.6" },
    .{ .provider = "opencode-go", .model = "kimi-k2.6" },
    .{ .provider = "kimi-coding", .model = "kimi-for-coding" },
    .{ .provider = "kimi-code-openai", .model = "kimi-for-coding" },
    .{ .provider = "cloudflare-workers-ai", .model = "@cf/moonshotai/kimi-k2.6" },
    .{ .provider = "cloudflare-ai-gateway", .model = "workers-ai/@cf/moonshotai/kimi-k2.6" },
    .{ .provider = "xiaomi", .model = "mimo-v2.5-pro" },
    .{ .provider = "xiaomi-token-plan-cn", .model = "mimo-v2.5-pro" },
    .{ .provider = "xiaomi-token-plan-ams", .model = "mimo-v2.5-pro" },
    .{ .provider = "xiaomi-token-plan-sgp", .model = "mimo-v2.5-pro" },
};

pub fn defaultModelForProvider(provider: []const u8) ?[]const u8 {
    for (default_model_per_provider) |entry| {
        if (std.mem.eql(u8, entry.provider, provider)) return entry.model;
    }
    return null;
}

test "model resolver facade exposes default provider models" {
    try std.testing.expectEqualStrings("gpt-5.4", defaultModelForProvider("openai").?);
}
