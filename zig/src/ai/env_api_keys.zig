const std = @import("std");
const builtin = @import("builtin");

const AUTHENTICATED_SENTINEL = "<authenticated>";

pub fn getEnvApiKey(allocator: std.mem.Allocator, provider: []const u8) !?[]u8 {
    const env = currentProcessEnviron();
    var env_map = try env.createMap(allocator);
    defer env_map.deinit();
    return try getEnvApiKeyFromMap(allocator, &env_map, provider);
}

fn currentProcessEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .{ .use_global = true } },
        else => blk: {
            const c_environ = std.c.environ;
            var env_count: usize = 0;
            while (c_environ[env_count] != null) : (env_count += 1) {}
            break :blk .{ .block = .{ .slice = c_environ[0..env_count :null] } };
        },
    };
}

pub fn getEnvApiKeyFromMap(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    provider: []const u8,
) !?[]u8 {
    if (std.mem.eql(u8, provider, "github-copilot")) {
        return try firstEnvValue(allocator, env_map, &[_][]const u8{
            "COPILOT_GITHUB_TOKEN",
            "GH_TOKEN",
            "GITHUB_TOKEN",
        });
    }

    if (std.mem.eql(u8, provider, "anthropic")) {
        return try firstEnvValue(allocator, env_map, &[_][]const u8{
            "ANTHROPIC_OAUTH_TOKEN",
            "ANTHROPIC_API_KEY",
        });
    }

    if (std.mem.eql(u8, provider, "google-vertex")) {
        if (env_map.get("GOOGLE_CLOUD_API_KEY")) |api_key| {
            return try allocator.dupe(u8, api_key);
        }

        const has_credentials = env_map.get("GOOGLE_APPLICATION_CREDENTIALS") != null;
        const has_project = env_map.get("GOOGLE_CLOUD_PROJECT") != null or env_map.get("GCLOUD_PROJECT") != null;
        const has_location = env_map.get("GOOGLE_CLOUD_LOCATION") != null;
        if (has_credentials and has_project and has_location) {
            return try allocator.dupe(u8, AUTHENTICATED_SENTINEL);
        }
    }

    if (std.mem.eql(u8, provider, "amazon-bedrock")) {
        const has_standard_keys = env_map.get("AWS_ACCESS_KEY_ID") != null and env_map.get("AWS_SECRET_ACCESS_KEY") != null;
        const has_alt_auth = env_map.get("AWS_PROFILE") != null or
            env_map.get("AWS_BEARER_TOKEN_BEDROCK") != null or
            env_map.get("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI") != null or
            env_map.get("AWS_CONTAINER_CREDENTIALS_FULL_URI") != null or
            env_map.get("AWS_WEB_IDENTITY_TOKEN_FILE") != null;
        if (has_standard_keys or has_alt_auth) {
            return try allocator.dupe(u8, AUTHENTICATED_SENTINEL);
        }
    }

    const env_var = resolveEnvVar(provider) orelse return null;
    if (env_map.get(env_var)) |value| {
        return try allocator.dupe(u8, value);
    }

    return null;
}

fn firstEnvValue(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    keys: []const []const u8,
) !?[]u8 {
    for (keys) |key| {
        if (env_map.get(key)) |value| {
            return try allocator.dupe(u8, value);
        }
    }
    return null;
}

fn resolveEnvVar(provider: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider, "openai")) return "OPENAI_API_KEY";
    if (std.mem.eql(u8, provider, "openai-responses")) return "OPENAI_API_KEY";
    if (std.mem.eql(u8, provider, "openai-codex")) return "OPENAI_API_KEY";
    if (std.mem.eql(u8, provider, "azure-openai-responses")) return "AZURE_OPENAI_API_KEY";
    if (std.mem.eql(u8, provider, "google")) return "GEMINI_API_KEY";
    if (std.mem.eql(u8, provider, "google-gemini-cli")) return "GEMINI_API_KEY";
    if (std.mem.eql(u8, provider, "groq")) return "GROQ_API_KEY";
    if (std.mem.eql(u8, provider, "cerebras")) return "CEREBRAS_API_KEY";
    if (std.mem.eql(u8, provider, "xai")) return "XAI_API_KEY";
    if (std.mem.eql(u8, provider, "openrouter")) return "OPENROUTER_API_KEY";
    if (std.mem.eql(u8, provider, "vercel-ai-gateway")) return "AI_GATEWAY_API_KEY";
    if (std.mem.eql(u8, provider, "zai")) return "ZAI_API_KEY";
    if (std.mem.eql(u8, provider, "mistral")) return "MISTRAL_API_KEY";
    if (std.mem.eql(u8, provider, "minimax")) return "MINIMAX_API_KEY";
    if (std.mem.eql(u8, provider, "minimax-cn")) return "MINIMAX_CN_API_KEY";
    if (std.mem.eql(u8, provider, "huggingface")) return "HF_TOKEN";
    if (std.mem.eql(u8, provider, "fireworks")) return "FIREWORKS_API_KEY";
    if (std.mem.eql(u8, provider, "opencode")) return "OPENCODE_API_KEY";
    if (std.mem.eql(u8, provider, "opencode-go")) return "OPENCODE_API_KEY";
    if (std.mem.eql(u8, provider, "kimi")) return "KIMI_API_KEY";
    if (std.mem.eql(u8, provider, "kimi-coding")) return "KIMI_API_KEY";
    return null;
}

test "getEnvApiKey resolves known providers and returns null when missing" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("OPENAI_API_KEY", "openai-key");
    try env_map.put("AZURE_OPENAI_API_KEY", "azure-key");
    try env_map.put("GEMINI_API_KEY", "gemini-key");
    try env_map.put("GROQ_API_KEY", "groq-key");
    try env_map.put("CEREBRAS_API_KEY", "cerebras-key");
    try env_map.put("XAI_API_KEY", "xai-key");
    try env_map.put("OPENROUTER_API_KEY", "openrouter-key");
    try env_map.put("AI_GATEWAY_API_KEY", "gateway-key");
    try env_map.put("ZAI_API_KEY", "zai-key");
    try env_map.put("MISTRAL_API_KEY", "mistral-key");
    try env_map.put("MINIMAX_API_KEY", "minimax-key");
    try env_map.put("MINIMAX_CN_API_KEY", "minimax-cn-key");
    try env_map.put("HF_TOKEN", "hf-key");
    try env_map.put("FIREWORKS_API_KEY", "fireworks-key");
    try env_map.put("OPENCODE_API_KEY", "opencode-key");
    try env_map.put("KIMI_API_KEY", "kimi-key");
    try env_map.put("COPILOT_GITHUB_TOKEN", "copilot-token");
    try env_map.put("GH_TOKEN", "gh-token");
    try env_map.put("GITHUB_TOKEN", "github-token");
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-api-key");
    try env_map.put("ANTHROPIC_OAUTH_TOKEN", "anthropic-oauth-token");
    try env_map.put("AWS_PROFILE", "default");
    try env_map.put("GOOGLE_CLOUD_PROJECT", "project-1");
    try env_map.put("GOOGLE_CLOUD_LOCATION", "us-central1");
    try env_map.put("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/adc.json");

    const mapped_cases = [_]struct {
        provider: []const u8,
        expected: []const u8,
    }{
        .{ .provider = "openai", .expected = "openai-key" },
        .{ .provider = "openai-responses", .expected = "openai-key" },
        .{ .provider = "openai-codex", .expected = "openai-key" },
        .{ .provider = "azure-openai-responses", .expected = "azure-key" },
        .{ .provider = "google", .expected = "gemini-key" },
        .{ .provider = "google-gemini-cli", .expected = "gemini-key" },
        .{ .provider = "groq", .expected = "groq-key" },
        .{ .provider = "cerebras", .expected = "cerebras-key" },
        .{ .provider = "xai", .expected = "xai-key" },
        .{ .provider = "openrouter", .expected = "openrouter-key" },
        .{ .provider = "vercel-ai-gateway", .expected = "gateway-key" },
        .{ .provider = "zai", .expected = "zai-key" },
        .{ .provider = "mistral", .expected = "mistral-key" },
        .{ .provider = "minimax", .expected = "minimax-key" },
        .{ .provider = "minimax-cn", .expected = "minimax-cn-key" },
        .{ .provider = "huggingface", .expected = "hf-key" },
        .{ .provider = "fireworks", .expected = "fireworks-key" },
        .{ .provider = "opencode", .expected = "opencode-key" },
        .{ .provider = "opencode-go", .expected = "opencode-key" },
        .{ .provider = "kimi", .expected = "kimi-key" },
        .{ .provider = "kimi-coding", .expected = "kimi-key" },
        .{ .provider = "github-copilot", .expected = "copilot-token" },
        .{ .provider = "anthropic", .expected = "anthropic-oauth-token" },
        .{ .provider = "amazon-bedrock", .expected = AUTHENTICATED_SENTINEL },
        .{ .provider = "google-vertex", .expected = AUTHENTICATED_SENTINEL },
    };

    for (mapped_cases) |case| {
        const value = try getEnvApiKeyFromMap(allocator, &env_map, case.provider);
        defer if (value) |resolved| allocator.free(resolved);
        try std.testing.expect(value != null);
        try std.testing.expectEqualStrings(case.expected, value.?);
    }

    try env_map.put("GOOGLE_CLOUD_API_KEY", "vertex-api-key");
    const vertex_api_key = try getEnvApiKeyFromMap(allocator, &env_map, "google-vertex");
    defer if (vertex_api_key) |resolved| allocator.free(resolved);
    try std.testing.expectEqualStrings("vertex-api-key", vertex_api_key.?);

    const missing_cases = [_][]const u8{
        "google-antigravity",
        "faux",
        "missing-provider",
    };

    for (missing_cases) |provider| {
        const missing = try getEnvApiKeyFromMap(allocator, &env_map, provider);
        defer if (missing) |resolved| allocator.free(resolved);
        try std.testing.expect(missing == null);
    }
}
