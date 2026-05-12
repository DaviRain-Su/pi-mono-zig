const std = @import("std");
const types = @import("types.zig");
const model_registry = @import("model_registry.zig");

/// Canonical per-provider metadata for the coding_agent layer.
///
/// Consolidates four formerly-separate per-provider tables:
///   - display_name           (was BUILT_IN_PROVIDER_DISPLAY_NAMES)
///   - default_model          (was default_model_per_provider)
///   - missing_api_key_message (was MISSING_API_KEY_MESSAGES)
///   - env_var                (primary single-key env var hint; for providers
///                             with multiple/alternative auth env vars this is
///                             null and the missing_api_key_message text is
///                             the canonical guidance.)
///   - env_vars               (ordered fallback list for providers whose API
///                             key may come from one of several env vars,
///                             tried in declaration order. Only meaningful
///                             when the resolution reduces to a flat ordered
///                             lookup; providers with conditional/ADC/AWS
///                             auth logic keep their bespoke code path in
///                             `env_api_keys.zig`.)
///
/// Adding a new provider in coding_agent now requires one row in PROVIDERS
/// instead of four separate edits. Fields that a provider does not carry are
/// expressed as null; accessor functions fall back to the same defaults the
/// previous standalone lookups used.
pub const ProviderInfo = struct {
    id: []const u8,
    display_name: ?[]const u8 = null,
    default_model: ?[]const u8 = null,
    missing_api_key_message: ?[]const u8 = null,
    env_var: ?[]const u8 = null,
    /// Set for providers whose env auth fits a flat priority-ordered list
    /// where success returns the literal value of the first non-empty env
    /// var (e.g. anthropic, github-copilot). Providers with sentinel-return
    /// semantics, filesystem probes (ADC), or AND-conjunction across
    /// heterogeneous env vars are dispatched in `env_api_keys.zig` -- see
    /// the `google-vertex` and `amazon-bedrock` branches there.
    env_vars: ?[]const []const u8 = null,
    /// Default `Api` identifier used to talk to this provider. Mirrors the
    /// canonical `(provider, api)` pairs in `model_registry.builtInProviderConfigs()`.
    /// `null` for providers that have no built-in `model_registry` entry; the
    /// runtime cross-check test below asserts every populated row agrees with
    /// the registry table.
    default_api: ?types.Api = null,
    /// When `findInitialDefaultModel` would otherwise pick this provider as
    /// the boot-time default, prefer the provider named here first (if its
    /// credentials are also configured). `null` means no preference.
    prefer_initial: ?[]const u8 = null,
    /// Built-in public OAuth client id shipped with the binary for providers
    /// that expose a hard-coded "public" OAuth application (Anthropic Claude
    /// Pro/Max, GitHub Copilot, OpenAI Codex). Providers whose OAuth flow
    /// requires an end-user-supplied client id (e.g. google-gemini-cli with a
    /// user-owned GCP project) leave this `null` and rely on the on-disk
    /// `oauth-clients.json` config; the auth-layer cross-check test asserts
    /// agreement between this field and the `AuthProviderInfo` table.
    oauth_default_client_id: ?[]const u8 = null,
};

pub const PROVIDERS: []const ProviderInfo = &.{
    .{
        .id = "amazon-bedrock",
        .display_name = "Amazon Bedrock",
        .default_model = "us.anthropic.claude-opus-4-6-v1",
        .missing_api_key_message = "Amazon Bedrock credentials required.\nRun /login amazon-bedrock to store a proxy/API key, or configure AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, AWS_PROFILE, AWS_BEARER_TOKEN_BEDROCK, or another supported AWS auth source.",
        .default_api = "bedrock-converse-stream",
    },
    .{
        .id = "anthropic",
        .display_name = "Anthropic",
        .default_model = "claude-opus-4-7",
        .missing_api_key_message = "Anthropic credentials required.\nSet ANTHROPIC_OAUTH_TOKEN or ANTHROPIC_API_KEY, pass --api-key, or run /login anthropic.",
        .env_vars = &.{ "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY" },
        .default_api = "anthropic-messages",
        .oauth_default_client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
    },
    .{
        .id = "azure-openai-responses",
        .display_name = "Azure OpenAI Responses",
        .default_model = "gpt-5.4",
        .missing_api_key_message = "Azure OpenAI credentials required.\nSet AZURE_OPENAI_API_KEY, pass --api-key, or run /login azure-openai-responses to save a key.",
        .env_var = "AZURE_OPENAI_API_KEY",
        .default_api = "azure-openai-responses",
    },
    .{
        .id = "cerebras",
        .display_name = "Cerebras",
        .default_model = "zai-glm-4.7",
        .missing_api_key_message = "Cerebras credentials required.\nSet CEREBRAS_API_KEY, pass --api-key, or run /login cerebras.",
        .env_var = "CEREBRAS_API_KEY",
        .default_api = "openai-completions",
    },
    .{
        .id = "cloudflare-ai-gateway",
        .display_name = "Cloudflare AI Gateway",
        .default_model = "workers-ai/@cf/moonshotai/kimi-k2.6",
        .missing_api_key_message = "Cloudflare AI Gateway credentials required.\nSet CLOUDFLARE_API_KEY, CLOUDFLARE_ACCOUNT_ID, and CLOUDFLARE_GATEWAY_ID, pass --api-key, or run /login cloudflare-ai-gateway.",
        .env_var = "CLOUDFLARE_API_KEY",
        .default_api = "openai-completions",
    },
    .{
        .id = "cloudflare-workers-ai",
        .display_name = "Cloudflare Workers AI",
        .default_model = "@cf/moonshotai/kimi-k2.6",
        .missing_api_key_message = "Cloudflare Workers AI credentials required.\nSet CLOUDFLARE_API_KEY and CLOUDFLARE_ACCOUNT_ID, pass --api-key, or run /login cloudflare-workers-ai.",
        .env_var = "CLOUDFLARE_API_KEY",
        .default_api = "openai-completions",
    },
    .{
        .id = "deepseek",
        .display_name = "DeepSeek",
        .default_model = "deepseek-v4-pro",
        .missing_api_key_message = "DeepSeek credentials required.\nSet DEEPSEEK_API_KEY, pass --api-key, or run /login deepseek.",
        .env_var = "DEEPSEEK_API_KEY",
        .default_api = "openai-completions",
    },
    .{
        .id = "fireworks",
        .display_name = "Fireworks",
        .default_model = "accounts/fireworks/models/kimi-k2p6",
        .missing_api_key_message = "Fireworks credentials required.\nSet FIREWORKS_API_KEY, pass --api-key, or run /login fireworks.",
        .env_var = "FIREWORKS_API_KEY",
        .default_api = "anthropic-messages",
    },
    .{
        .id = "github-copilot",
        .display_name = "GitHub Copilot",
        .default_model = "gpt-5.4",
        .missing_api_key_message = "GitHub Copilot credentials required.\nRun /login github-copilot, or set COPILOT_GITHUB_TOKEN, GH_TOKEN, or GITHUB_TOKEN.",
        .env_vars = &.{ "COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN" },
        .default_api = "openai-responses",
        .oauth_default_client_id = "Iv1.b507a08c87ecfe98",
    },
    .{
        .id = "google",
        .display_name = "Google Gemini",
        .default_model = "gemini-3.1-pro-preview",
        .missing_api_key_message = "Google Gemini credentials required.\nSet GEMINI_API_KEY, pass --api-key, or run /login google to save a key.",
        .env_var = "GEMINI_API_KEY",
        .default_api = "google-generative-ai",
    },
    .{
        .id = "google-gemini-cli",
        .display_name = "Google Cloud Code Assist (Gemini CLI)",
        .missing_api_key_message = "Google Cloud Code Assist credentials required.\nRun /login google-gemini-cli. Paid tiers may also require GOOGLE_CLOUD_PROJECT or GOOGLE_CLOUD_PROJECT_ID.",
        .default_api = "google-gemini-cli",
    },
    .{
        .id = "google-vertex",
        .display_name = "Google Vertex AI",
        .default_model = "gemini-3.1-pro-preview",
        .missing_api_key_message = "Google Vertex AI credentials required.\nSet GOOGLE_CLOUD_API_KEY, or configure GOOGLE_APPLICATION_CREDENTIALS with GOOGLE_CLOUD_PROJECT and GOOGLE_CLOUD_LOCATION. /login google-vertex can also store an API key.",
        .default_api = "google-vertex",
    },
    .{
        .id = "groq",
        .display_name = "Groq",
        .default_model = "openai/gpt-oss-120b",
        .missing_api_key_message = "Groq credentials required.\nSet GROQ_API_KEY, pass --api-key, or run /login groq.",
        .env_var = "GROQ_API_KEY",
        .default_api = "openai-completions",
    },
    .{
        .id = "huggingface",
        .display_name = "Hugging Face",
        .default_model = "moonshotai/Kimi-K2.6",
        .missing_api_key_message = "Hugging Face credentials required.\nSet HF_TOKEN, pass --api-key, or run /login huggingface.",
        .env_var = "HF_TOKEN",
        .default_api = "openai-completions",
    },
    .{
        .id = "kimi",
        .display_name = "Kimi",
        .missing_api_key_message = "Kimi credentials required.\nSet MOONSHOT_API_KEY, pass --api-key, or run /login kimi.",
        .env_var = "MOONSHOT_API_KEY",
        .default_api = "kimi-completions",
    },
    .{
        .id = "kimi-code-openai",
        .display_name = "Kimi Code (OpenAI Compatible)",
        .default_model = "kimi-for-coding",
        .missing_api_key_message = "Kimi Code (OpenAI Compatible) credentials required.\nSet KIMI_API_KEY, pass --api-key, or run /login kimi-code-openai.",
        .env_var = "KIMI_API_KEY",
        .default_api = "openai-completions",
        .prefer_initial = "kimi-coding",
    },
    .{
        .id = "kimi-coding",
        .display_name = "Kimi For Coding",
        .default_model = "kimi-for-coding",
        .missing_api_key_message = "Kimi For Coding credentials required.\nSet KIMI_API_KEY, pass --api-key, or run /login kimi-coding.",
        .env_var = "KIMI_API_KEY",
        .default_api = "anthropic-messages",
    },
    .{
        .id = "minimax",
        .display_name = "MiniMax",
        .default_model = "MiniMax-M2.7",
        .missing_api_key_message = "MiniMax credentials required.\nSet MINIMAX_API_KEY, pass --api-key, or run /login minimax.",
        .env_var = "MINIMAX_API_KEY",
        .default_api = "anthropic-messages",
    },
    .{
        .id = "minimax-cn",
        .display_name = "MiniMax (China)",
        .default_model = "MiniMax-M2.7",
        .missing_api_key_message = "MiniMax (China) credentials required.\nSet MINIMAX_CN_API_KEY, pass --api-key, or run /login minimax-cn.",
        .env_var = "MINIMAX_CN_API_KEY",
        .default_api = "anthropic-messages",
    },
    .{
        .id = "mistral",
        .display_name = "Mistral",
        .default_model = "devstral-medium-latest",
        .missing_api_key_message = "Mistral credentials required.\nSet MISTRAL_API_KEY, pass --api-key, or run /login mistral.",
        .env_var = "MISTRAL_API_KEY",
        .default_api = "mistral-conversations",
    },
    .{
        .id = "moonshotai",
        .display_name = "Moonshot AI",
        .default_model = "kimi-k2.6",
        .missing_api_key_message = "Moonshot AI credentials required.\nSet MOONSHOT_API_KEY, pass --api-key, or run /login moonshotai.",
        .env_var = "MOONSHOT_API_KEY",
        .default_api = "openai-completions",
    },
    .{
        .id = "moonshotai-cn",
        .display_name = "Moonshot AI (China)",
        .default_model = "kimi-k2.6",
        .missing_api_key_message = "Moonshot AI (China) credentials required.\nSet MOONSHOT_API_KEY, pass --api-key, or run /login moonshotai-cn.",
        .env_var = "MOONSHOT_API_KEY",
        .default_api = "openai-completions",
    },
    .{
        .id = "opencode",
        .display_name = "OpenCode Zen",
        .default_model = "kimi-k2.6",
        .missing_api_key_message = "OpenCode Zen credentials required.\nSet OPENCODE_API_KEY, pass --api-key, or run /login opencode.",
        .env_var = "OPENCODE_API_KEY",
        .default_api = "openai-completions",
    },
    .{
        .id = "opencode-go",
        .display_name = "OpenCode Go",
        .default_model = "kimi-k2.6",
        .missing_api_key_message = "OpenCode Go credentials required.\nSet OPENCODE_API_KEY, pass --api-key, or run /login opencode-go.",
        .env_var = "OPENCODE_API_KEY",
        .default_api = "openai-completions",
    },
    .{
        .id = "openai",
        .display_name = "OpenAI",
        .default_model = "gpt-5.4",
        .missing_api_key_message = "OpenAI credentials required.\nSet OPENAI_API_KEY, pass --api-key, or run /login openai to save a key.",
        .env_var = "OPENAI_API_KEY",
        .default_api = "openai-responses",
    },
    .{
        .id = "openai-codex",
        .display_name = "OpenAI Codex",
        .default_model = "gpt-5.5",
        .missing_api_key_message = "OpenAI Codex credentials required.\nSet OPENAI_API_KEY, pass --api-key, or run /login openai-codex for ChatGPT Plus/Pro subscription auth.",
        .env_var = "OPENAI_API_KEY",
        .default_api = "openai-codex-responses",
        .oauth_default_client_id = "app_EMoamEEZ73f0CkXaXp7hrann",
    },
    .{
        .id = "openai-responses",
        .display_name = "OpenAI Responses",
        .missing_api_key_message = "OpenAI Responses credentials required.\nSet OPENAI_API_KEY, pass --api-key, or run /login openai-responses to save a key.",
        .env_var = "OPENAI_API_KEY",
        .default_api = "openai-responses",
    },
    .{
        .id = "openrouter",
        .display_name = "OpenRouter",
        .default_model = "moonshotai/kimi-k2.6",
        .missing_api_key_message = "OpenRouter credentials required.\nSet OPENROUTER_API_KEY, pass --api-key, or run /login openrouter.",
        .env_var = "OPENROUTER_API_KEY",
        .default_api = "openai-completions",
    },
    .{
        .id = "together",
        .display_name = "Together AI",
        .default_model = "moonshotai/Kimi-K2.6",
        .missing_api_key_message = "Together AI credentials required.\nSet TOGETHER_API_KEY, pass --api-key, or run /login together.",
        .env_var = "TOGETHER_API_KEY",
        .default_api = "openai-completions",
    },
    .{
        .id = "vercel-ai-gateway",
        .display_name = "Vercel AI Gateway",
        .default_model = "zai/glm-5.1",
        .missing_api_key_message = "Vercel AI Gateway credentials required.\nSet AI_GATEWAY_API_KEY, pass --api-key, or run /login vercel-ai-gateway.",
        .env_var = "AI_GATEWAY_API_KEY",
        .default_api = "anthropic-messages",
    },
    .{
        .id = "xai",
        .display_name = "xAI",
        .default_model = "grok-4.20-0309-reasoning",
        .missing_api_key_message = "xAI credentials required.\nSet XAI_API_KEY, pass --api-key, or run /login xai.",
        .env_var = "XAI_API_KEY",
        .default_api = "openai-completions",
    },
    .{
        .id = "xiaomi",
        .display_name = "Xiaomi MiMo",
        .default_model = "mimo-v2.5-pro",
        .missing_api_key_message = "Xiaomi MiMo credentials required.\nSet XIAOMI_API_KEY, pass --api-key, or run /login xiaomi.",
        .env_var = "XIAOMI_API_KEY",
        .default_api = "anthropic-messages",
    },
    .{
        .id = "xiaomi-token-plan-ams",
        .display_name = "Xiaomi MiMo Token Plan (Amsterdam)",
        .default_model = "mimo-v2.5-pro",
        .missing_api_key_message = "Xiaomi MiMo Token Plan (Amsterdam) credentials required.\nSet XIAOMI_TOKEN_PLAN_AMS_API_KEY, pass --api-key, or run /login xiaomi-token-plan-ams.",
        .env_var = "XIAOMI_TOKEN_PLAN_AMS_API_KEY",
        .default_api = "anthropic-messages",
    },
    .{
        .id = "xiaomi-token-plan-cn",
        .display_name = "Xiaomi MiMo Token Plan (China)",
        .default_model = "mimo-v2.5-pro",
        .missing_api_key_message = "Xiaomi MiMo Token Plan (China) credentials required.\nSet XIAOMI_TOKEN_PLAN_CN_API_KEY, pass --api-key, or run /login xiaomi-token-plan-cn.",
        .env_var = "XIAOMI_TOKEN_PLAN_CN_API_KEY",
        .default_api = "anthropic-messages",
    },
    .{
        .id = "xiaomi-token-plan-sgp",
        .display_name = "Xiaomi MiMo Token Plan (Singapore)",
        .default_model = "mimo-v2.5-pro",
        .missing_api_key_message = "Xiaomi MiMo Token Plan (Singapore) credentials required.\nSet XIAOMI_TOKEN_PLAN_SGP_API_KEY, pass --api-key, or run /login xiaomi-token-plan-sgp.",
        .env_var = "XIAOMI_TOKEN_PLAN_SGP_API_KEY",
        .default_api = "anthropic-messages",
    },
    .{
        .id = "zai",
        .display_name = "ZAI",
        .default_model = "glm-4.7",
        .missing_api_key_message = "ZAI credentials required.\nSet ZAI_API_KEY, pass --api-key, or run /login zai.",
        .env_var = "ZAI_API_KEY",
        .default_api = "openai-completions",
    },
};

const PROVIDER_INFO_MAP = std.StaticStringMap(*const ProviderInfo).initComptime(blk: {
    var kv: [PROVIDERS.len]struct { []const u8, *const ProviderInfo } = undefined;
    for (PROVIDERS, 0..) |*provider, i| {
        kv[i] = .{ provider.id, provider };
    }
    break :blk kv;
});

pub fn providerInfoFor(id: []const u8) ?*const ProviderInfo {
    return PROVIDER_INFO_MAP.get(id);
}

pub fn displayNameFor(id: []const u8) ?[]const u8 {
    const info = providerInfoFor(id) orelse return null;
    return info.display_name;
}

pub fn defaultModelFor(id: []const u8) ?[]const u8 {
    const info = providerInfoFor(id) orelse return null;
    return info.default_model;
}

pub fn missingApiKeyMessageFor(id: []const u8) ?[]const u8 {
    const info = providerInfoFor(id) orelse return null;
    return info.missing_api_key_message;
}

pub fn envVarFor(id: []const u8) ?[]const u8 {
    const info = providerInfoFor(id) orelse return null;
    return info.env_var;
}

pub fn envVarsFor(id: []const u8) ?[]const []const u8 {
    const info = providerInfoFor(id) orelse return null;
    return info.env_vars;
}

pub fn defaultApiFor(id: []const u8) ?types.Api {
    const info = providerInfoFor(id) orelse return null;
    return info.default_api;
}

pub fn preferInitialFor(id: []const u8) ?[]const u8 {
    const info = providerInfoFor(id) orelse return null;
    return info.prefer_initial;
}

pub fn oauthDefaultClientIdFor(id: []const u8) ?[]const u8 {
    const info = providerInfoFor(id) orelse return null;
    return info.oauth_default_client_id;
}

test "providerInfoFor returns canonical row for a known provider" {
    const info = providerInfoFor("openai").?;
    try std.testing.expectEqualStrings("openai", info.id);
    try std.testing.expectEqualStrings("OpenAI", info.display_name.?);
    try std.testing.expectEqualStrings("gpt-5.4", info.default_model.?);
    try std.testing.expect(std.mem.indexOf(u8, info.missing_api_key_message.?, "OPENAI_API_KEY") != null);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", info.env_var.?);
}

test "providerInfoFor returns null for unknown providers" {
    try std.testing.expectEqual(@as(?*const ProviderInfo, null), providerInfoFor("totally-unknown-provider"));
}

test "providers with partial coverage expose null fields" {
    const github = providerInfoFor("github-copilot").?;
    try std.testing.expectEqualStrings("GitHub Copilot", github.display_name.?);
    try std.testing.expectEqualStrings("gpt-5.4", github.default_model.?);

    const gemini_cli = providerInfoFor("google-gemini-cli").?;
    try std.testing.expectEqualStrings("Google Cloud Code Assist (Gemini CLI)", gemini_cli.display_name.?);
    try std.testing.expectEqual(@as(?[]const u8, null), gemini_cli.default_model);
    try std.testing.expect(gemini_cli.missing_api_key_message != null);

    const responses = providerInfoFor("openai-responses").?;
    try std.testing.expectEqualStrings("OpenAI Responses", responses.display_name.?);
    try std.testing.expectEqual(@as(?[]const u8, null), responses.default_model);
}

test "every PROVIDERS row has a unique id" {
    for (PROVIDERS, 0..) |provider, i| {
        for (PROVIDERS[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, provider.id, other.id));
        }
    }
}

test "oauthDefaultClientIdFor returns the canonical public client ids" {
    try std.testing.expectEqualStrings(
        "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        oauthDefaultClientIdFor("anthropic").?,
    );
    try std.testing.expectEqualStrings(
        "Iv1.b507a08c87ecfe98",
        oauthDefaultClientIdFor("github-copilot").?,
    );
    try std.testing.expectEqualStrings(
        "app_EMoamEEZ73f0CkXaXp7hrann",
        oauthDefaultClientIdFor("openai-codex").?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), oauthDefaultClientIdFor("google-gemini-cli"));
    try std.testing.expectEqual(@as(?[]const u8, null), oauthDefaultClientIdFor("openai"));
}

test "provider_info default_api matches model_registry built-ins" {
    for (model_registry.builtInProviderConfigs()) |cfg| {
        // The `faux` provider is registered in model_registry for tests but
        // intentionally has no provider_info row.
        if (std.mem.eql(u8, cfg.provider, "faux")) continue;

        const info = providerInfoFor(cfg.provider) orelse {
            std.debug.print(
                "provider_info missing row for model_registry provider '{s}'\n",
                .{cfg.provider},
            );
            return error.TestExpectedEqual;
        };
        const default_api = info.default_api orelse {
            std.debug.print(
                "provider_info row for '{s}' has null default_api but model_registry says api='{s}'\n",
                .{ cfg.provider, cfg.api },
            );
            return error.TestExpectedEqual;
        };
        if (!std.mem.eql(u8, default_api, cfg.api)) {
            std.debug.print(
                "default_api mismatch for provider '{s}': provider_info='{s}' model_registry='{s}'\n",
                .{ cfg.provider, default_api, cfg.api },
            );
            return error.TestExpectedEqual;
        }
    }
}
