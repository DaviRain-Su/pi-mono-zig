const std = @import("std");

/// Get the API key for a provider from known environment variables.
/// The returned string is owned by the caller and must be freed with `gpa.free`.
/// Returns `null` if no key is found.
/// For some providers (bedrock, vertex), returns an empty string to indicate
/// that credentials are configured via other means.
pub fn getEnvApiKey(gpa: std.mem.Allocator, provider: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, provider, "github-copilot") or std.mem.eql(u8, provider, "github_copilot")) {
        return try getEnvAny(gpa, &.{ "COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN" });
    }

    if (std.mem.eql(u8, provider, "anthropic")) {
        return try getEnvAny(gpa, &.{ "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY" });
    }

    if (std.mem.eql(u8, provider, "google-vertex") or std.mem.eql(u8, provider, "google_vertex")) {
        if (try getEnvOwned(gpa, "GOOGLE_CLOUD_API_KEY")) |key| return key;

        const has_credentials = try hasVertexAdcCredentials(gpa);
        const has_project = try hasEnv("GOOGLE_CLOUD_PROJECT") or try hasEnv("GCLOUD_PROJECT");
        const has_location = try hasEnv("GOOGLE_CLOUD_LOCATION");

        if (has_credentials and has_project and has_location) {
            return try gpa.dupe(u8, "");
        }
        return null;
    }

    if (std.mem.eql(u8, provider, "amazon-bedrock") or std.mem.eql(u8, provider, "amazon_bedrock")) {
        if (try hasEnv("AWS_PROFILE")) return try gpa.dupe(u8, "");
        if ((try hasEnv("AWS_ACCESS_KEY_ID")) and (try hasEnv("AWS_SECRET_ACCESS_KEY"))) return try gpa.dupe(u8, "");
        if (try hasEnv("AWS_BEARER_TOKEN_BEDROCK")) return try gpa.dupe(u8, "");
        if (try hasEnv("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")) return try gpa.dupe(u8, "");
        if (try hasEnv("AWS_CONTAINER_CREDENTIALS_FULL_URI")) return try gpa.dupe(u8, "");
        if (try hasEnv("AWS_WEB_IDENTITY_TOKEN_FILE")) return try gpa.dupe(u8, "");
        return null;
    }

    const map = .{
        .{ "openai", "OPENAI_API_KEY" },
        .{ "azure-openai-responses", "AZURE_OPENAI_API_KEY" },
        .{ "azure_openai_responses", "AZURE_OPENAI_API_KEY" },
        .{ "google", "GEMINI_API_KEY" },
        .{ "groq", "GROQ_API_KEY" },
        .{ "cerebras", "CEREBRAS_API_KEY" },
        .{ "xai", "XAI_API_KEY" },
        .{ "openrouter", "OPENROUTER_API_KEY" },
        .{ "vercel-ai-gateway", "AI_GATEWAY_API_KEY" },
        .{ "vercel_ai_gateway", "AI_GATEWAY_API_KEY" },
        .{ "zai", "ZAI_API_KEY" },
        .{ "mistral", "MISTRAL_API_KEY" },
        .{ "minimax", "MINIMAX_API_KEY" },
        .{ "minimax-cn", "MINIMAX_CN_API_KEY" },
        .{ "minimax_cn", "MINIMAX_CN_API_KEY" },
        .{ "huggingface", "HF_TOKEN" },
        .{ "opencode", "OPENCODE_API_KEY" },
        .{ "opencode-go", "OPENCODE_API_KEY" },
        .{ "opencode_go", "OPENCODE_API_KEY" },
        .{ "kimi-coding", "KIMI_API_KEY" },
        .{ "kimi_coding", "KIMI_API_KEY" },
    };

    inline for (map) |entry| {
        if (std.mem.eql(u8, provider, entry[0])) {
            return try getEnvOwned(gpa, entry[1]);
        }
    }

    return null;
}

fn getEnvAny(gpa: std.mem.Allocator, names: []const []const u8) !?[]const u8 {
    for (names) |name| {
        if (try getEnvOwned(gpa, name)) |value| return value;
    }
    return null;
}

fn getEnvOwned(gpa: std.mem.Allocator, name: []const u8) !?[]const u8 {
    return std.process.getEnvVarOwned(gpa, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
}

fn hasEnv(name: []const u8) !bool {
    _ = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return err,
    };
    return true;
}

fn hasVertexAdcCredentials(gpa: std.mem.Allocator) !bool {
    if (try getEnvOwned(gpa, "GOOGLE_APPLICATION_CREDENTIALS")) |path| {
        defer gpa.free(path);
        const stat = std.fs.cwd().statFile(path) catch return false;
        _ = stat;
        return true;
    }

    const home = std.process.getEnvVarOwned(gpa, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return err,
    };
    defer gpa.free(home);

    const default_path = try std.fs.path.join(gpa, &.{ home, ".config", "gcloud", "application_default_credentials.json" });
    defer gpa.free(default_path);

    const stat = std.fs.cwd().statFile(default_path) catch return false;
    _ = stat;
    return true;
}

test "getEnvApiKey returns known keys" {
    const gpa = std.testing.allocator;
    // We can't guarantee env vars exist, but we can test the bedrock/vertex empty-string cases
    // by setting temporary env vars if we wanted. For now, just ensure compilation.
    _ = try getEnvApiKey(gpa, "openai");
    _ = try getEnvApiKey(gpa, "amazon_bedrock");
    _ = try getEnvApiKey(gpa, "google_vertex");
}
