const std = @import("std");
const ai = @import("ai");
const common = @import("tools/common.zig");

const faux = ai.providers.faux;

pub const ResolveProviderError = error{
    MissingApiKey,
    UnknownProvider,
    InvalidFauxStopReason,
    InvalidFauxTokensPerSecond,
    InvalidFauxContextWindow,
    InvalidFauxToolArguments,
};

const OwnedFauxMessage = struct {
    blocks: []faux.FauxContentBlock,

    fn deinit(self: *OwnedFauxMessage, allocator: std.mem.Allocator) void {
        for (self.blocks) |*block| {
            switch (block.*) {
                .tool_call => |*tool_call| {
                    allocator.free(tool_call.id);
                    allocator.free(tool_call.name);
                    common.deinitJsonValue(allocator, tool_call.arguments);
                },
                else => {},
            }
        }
        allocator.free(self.blocks);
        self.* = undefined;
    }
};

pub const ResolvedProviderConfig = struct {
    model: ai.Model,
    api_key: ?[]const u8,
    owned_api_key: ?[]u8 = null,
    faux_registration: ?faux.FauxProviderRegistration = null,
    owned_faux_messages: ?[]OwnedFauxMessage = null,

    pub fn deinit(self: *ResolvedProviderConfig, allocator: std.mem.Allocator) void {
        if (self.faux_registration) |registration| registration.unregister();
        if (self.owned_api_key) |api_key| allocator.free(api_key);
        if (self.owned_faux_messages) |messages| {
            for (messages) |*message| message.deinit(allocator);
            allocator.free(messages);
        }
        self.* = undefined;
    }
};

pub const AvailableModel = struct {
    provider: []const u8,
    model_id: []const u8,
    display_name: []const u8,
    available: bool,
    reasoning: bool,
    supports_images: bool,
    context_window: u32,
    max_tokens: u32,
};

pub const ConfiguredCredentials = struct {
    auth_tokens: ?*const std.StringHashMap([]const u8) = null,
    provider_api_keys: ?*const std.StringHashMap([]const u8) = null,

    pub fn lookup(self: ConfiguredCredentials, provider: []const u8) ?[]const u8 {
        if (self.auth_tokens) |auth_tokens| {
            if (auth_tokens.get(provider)) |value| return value;
        }
        if (self.provider_api_keys) |provider_api_keys| {
            if (provider_api_keys.get(provider)) |value| return value;
        }
        return null;
    }
};

pub fn resolveProviderConfig(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    provider: []const u8,
    model_override: ?[]const u8,
    api_key_override: ?[]const u8,
    configured_api_key: ?[]const u8,
) (ResolveProviderError || std.mem.Allocator.Error || std.fmt.ParseIntError)!ResolvedProviderConfig {
    const descriptor = if (!std.mem.eql(u8, provider, "faux"))
        ai.model_registry.getProviderConfig(provider) orelse return error.UnknownProvider
    else
        null;

    if (std.mem.eql(u8, provider, "faux") or shouldForceFauxProvider(env_map, provider)) {
        return try resolveFauxProvider(allocator, env_map, provider, model_override, descriptor);
    }

    const provider_descriptor = descriptor.?;
    const owned_api_key = if (api_key_override == null)
        try ai.env_api_keys.getEnvApiKeyFromMap(allocator, env_map, provider)
    else
        null;
    errdefer if (owned_api_key) |api_key| allocator.free(api_key);

    const api_key = api_key_override orelse configured_api_key orelse owned_api_key orelse return error.MissingApiKey;
    const model_id = model_override orelse provider_descriptor.default_model_id orelse provider;
    const model = ai.model_registry.find(provider, model_id) orelse fallbackModel(provider_descriptor, model_id);

    return .{
        .model = model,
        .api_key = api_key,
        .owned_api_key = owned_api_key,
    };
}

pub fn listAvailableModels(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ?ai.Model,
    configured_credentials: ConfiguredCredentials,
) ![]AvailableModel {
    const summaries = try ai.model_registry.listSummaries(allocator);
    defer allocator.free(summaries);

    var models = std.ArrayList(AvailableModel).empty;
    errdefer models.deinit(allocator);

    for (summaries) |summary| {
        const credentials_available = try hasProviderCredentials(allocator, env_map, summary.provider, configured_credentials);
        try models.append(allocator, .{
            .provider = summary.provider,
            .model_id = summary.id,
            .display_name = summary.name,
            .available = credentials_available,
            .reasoning = summary.reasoning,
            .supports_images = hasInputType(summary.input_types, "image"),
            .context_window = summary.context_window,
            .max_tokens = summary.max_tokens,
        });
    }

    if (current_model) |model| {
        var seen = false;
        for (models.items) |entry| {
            if (std.mem.eql(u8, entry.provider, model.provider) and std.mem.eql(u8, entry.model_id, model.id)) {
                seen = true;
                break;
            }
        }
        if (!seen) {
            try models.append(allocator, .{
                .provider = model.provider,
                .model_id = model.id,
                .display_name = model.name,
                .available = try hasProviderCredentials(allocator, env_map, model.provider, configured_credentials),
                .reasoning = model.reasoning,
                .supports_images = hasInputType(model.input_types, "image"),
                .context_window = model.context_window,
                .max_tokens = model.max_tokens,
            });
        }
    }

    std.mem.sort(AvailableModel, models.items, {}, lessThanAvailableModel);
    return try models.toOwnedSlice(allocator);
}

pub fn filterConfiguredModels(
    allocator: std.mem.Allocator,
    available: []const AvailableModel,
) ![]AvailableModel {
    var filtered = std.ArrayList(AvailableModel).empty;
    errdefer filtered.deinit(allocator);

    for (available) |entry| {
        if (entry.available) try filtered.append(allocator, entry);
    }

    return try filtered.toOwnedSlice(allocator);
}

pub fn findInitialDefaultModel(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    configured_credentials: ConfiguredCredentials,
) !?ai.Model {
    for (ai.model_registry.builtInProviderConfigs()) |provider| {
        if (std.mem.eql(u8, provider.provider, "faux")) continue;
        if (!try hasProviderCredentials(allocator, env_map, provider.provider, configured_credentials)) continue;

        const model_id = provider.default_model_id orelse provider.provider;
        return ai.model_registry.find(provider.provider, model_id) orelse fallbackModel(provider, model_id);
    }
    return null;
}

pub fn filterAvailableModels(
    allocator: std.mem.Allocator,
    available: []const AvailableModel,
    patterns: []const []const u8,
) ![]AvailableModel {
    if (patterns.len == 0) return allocator.dupe(AvailableModel, available);

    var filtered = std.ArrayList(AvailableModel).empty;
    errdefer filtered.deinit(allocator);

    for (available) |entry| {
        for (patterns) |pattern| {
            if (availableModelMatchesPattern(entry, pattern)) {
                try filtered.append(allocator, entry);
                break;
            }
        }
    }

    return try filtered.toOwnedSlice(allocator);
}

pub fn resolveProviderErrorMessage(err: anyerror, provider: []const u8) []const u8 {
    return switch (err) {
        error.MissingApiKey => missingApiKeyMessage(provider),
        error.UnknownProvider => "Unsupported provider. Supported providers: openai, kimi, anthropic, mistral, openai-responses, azure-openai-responses, openai-codex, github-copilot, google, google-gemini-cli, google-vertex, amazon-bedrock, xai, groq, cerebras, openrouter, vercel-ai-gateway, zai, minimax, minimax-cn, huggingface, fireworks, opencode, opencode-go, kimi-coding, faux.",
        error.InvalidFauxStopReason => "Invalid PI_FAUX_STOP_REASON. Expected stop, length, tool_use, error, or aborted.",
        error.InvalidFauxTokensPerSecond => "Invalid PI_FAUX_TOKENS_PER_SECOND. Expected an integer.",
        error.InvalidFauxContextWindow => "Invalid PI_FAUX_CONTEXT_WINDOW. Expected an integer.",
        error.InvalidFauxToolArguments => "Invalid PI_FAUX_TOOL_ARGS_JSON. Expected a JSON object or value.",
        else => @errorName(err),
    };
}

fn shouldForceFauxProvider(env_map: *const std.process.Environ.Map, provider: []const u8) bool {
    const value = env_map.get("PI_FAUX_FORCE") orelse return false;
    return std.mem.eql(u8, value, "1") or
        std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "*") or
        std.mem.eql(u8, value, provider);
}

fn lessThanAvailableModel(_: void, lhs: AvailableModel, rhs: AvailableModel) bool {
    const provider_order = std.ascii.orderIgnoreCase(lhs.provider, rhs.provider);
    if (provider_order != .eq) return provider_order == .lt;
    return std.ascii.orderIgnoreCase(lhs.model_id, rhs.model_id) == .lt;
}

fn hasInputType(input_types: []const []const u8, expected: []const u8) bool {
    for (input_types) |input_type| {
        if (std.ascii.eqlIgnoreCase(input_type, expected)) return true;
    }
    return false;
}

fn modelMatchesReference(model: ai.Model, provider: []const u8, model_id: []const u8) bool {
    return std.mem.eql(u8, model.provider, provider) and std.mem.eql(u8, model.id, model_id);
}

fn availableModelMatchesPattern(entry: AvailableModel, raw_pattern: []const u8) bool {
    const pattern = normalizeModelPattern(raw_pattern);
    if (pattern.len == 0) return false;

    if (std.mem.indexOfScalar(u8, pattern, '/')) |slash_index| {
        const provider_pattern = std.mem.trim(u8, pattern[0..slash_index], &std.ascii.whitespace);
        const model_pattern = std.mem.trim(u8, pattern[slash_index + 1 ..], &std.ascii.whitespace);
        if (provider_pattern.len == 0 or model_pattern.len == 0) return false;

        return fieldMatches(entry.provider, provider_pattern, true) and
            (fieldMatches(entry.model_id, model_pattern, false) or
                fieldMatches(entry.display_name, model_pattern, false));
    }

    return fieldMatches(entry.model_id, pattern, false) or
        fieldMatches(entry.display_name, pattern, false) or
        fieldMatches(entry.provider, pattern, false);
}

fn normalizeModelPattern(raw_pattern: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_pattern, &std.ascii.whitespace);
    const colon_index = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return trimmed;
    const suffix = trimmed[colon_index + 1 ..];
    if (isThinkingLevelSuffix(suffix)) return trimmed[0..colon_index];
    return trimmed;
}

fn isThinkingLevelSuffix(value: []const u8) bool {
    return std.mem.eql(u8, value, "off") or
        std.mem.eql(u8, value, "minimal") or
        std.mem.eql(u8, value, "low") or
        std.mem.eql(u8, value, "medium") or
        std.mem.eql(u8, value, "high") or
        std.mem.eql(u8, value, "xhigh");
}

fn fieldMatches(field: []const u8, pattern: []const u8, exact_when_plain: bool) bool {
    if (pattern.len == 0) return false;
    if (hasWildcard(pattern)) return wildcardMatchIgnoreCase(pattern, field);
    if (exact_when_plain) return std.ascii.eqlIgnoreCase(field, pattern);
    return containsIgnoreCase(field, pattern);
}

fn hasWildcard(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "*?[") != null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn wildcardMatchIgnoreCase(pattern: []const u8, text: []const u8) bool {
    return wildcardMatchIgnoreCaseRecursive(pattern, text, 0, 0);
}

fn wildcardMatchIgnoreCaseRecursive(pattern: []const u8, text: []const u8, pattern_index: usize, text_index: usize) bool {
    var p = pattern_index;
    var t = text_index;

    while (p < pattern.len) : (p += 1) {
        switch (pattern[p]) {
            '*' => {
                var next_pattern = p + 1;
                while (next_pattern < pattern.len and pattern[next_pattern] == '*') : (next_pattern += 1) {}
                if (next_pattern == pattern.len) return true;

                var candidate = t;
                while (candidate <= text.len) : (candidate += 1) {
                    if (wildcardMatchIgnoreCaseRecursive(pattern, text, next_pattern, candidate)) return true;
                }
                return false;
            },
            '?' => {
                if (t >= text.len) return false;
                t += 1;
            },
            else => {
                if (t >= text.len) return false;
                if (!std.ascii.eqlIgnoreCase(pattern[p .. p + 1], text[t .. t + 1])) return false;
                t += 1;
            },
        }
    }

    return t == text.len;
}

fn resolveFauxProvider(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    provider: []const u8,
    model_override: ?[]const u8,
    descriptor: ?ai.model_registry.ProviderConfig,
) (ResolveProviderError || std.mem.Allocator.Error || std.fmt.ParseIntError)!ResolvedProviderConfig {
    const tokens_per_second = if (env_map.get("PI_FAUX_TOKENS_PER_SECOND")) |value|
        std.fmt.parseInt(u32, value, 10) catch return error.InvalidFauxTokensPerSecond
    else
        null;

    const context_window = if (env_map.get("PI_FAUX_CONTEXT_WINDOW")) |value|
        std.fmt.parseInt(u32, value, 10) catch return error.InvalidFauxContextWindow
    else
        null;

    const selected_model_id = model_override orelse if (descriptor) |provider_descriptor|
        provider_descriptor.default_model_id orelse provider
    else
        provider;
    const registered_model = ai.model_registry.find(provider, selected_model_id);

    var faux_model_definition: ?faux.FauxModelDefinition = null;
    if (descriptor != null or model_override != null or context_window != null) {
        faux_model_definition = .{
            .id = selected_model_id,
            .name = if (registered_model) |model| model.name else selected_model_id,
            .reasoning = if (registered_model) |model| model.reasoning else false,
            .input = if (registered_model) |model| model.input_types else null,
            .cost = if (registered_model) |model| model.cost else null,
            .context_window = context_window orelse if (registered_model) |model| model.context_window else null,
            .max_tokens = if (registered_model) |model| model.max_tokens else null,
        };
    }

    var faux_model_definitions: [1]faux.FauxModelDefinition = undefined;
    const faux_models: ?[]const faux.FauxModelDefinition = if (faux_model_definition) |definition| blk: {
        faux_model_definitions[0] = definition;
        break :blk faux_model_definitions[0..];
    } else null;

    const registration = try faux.registerFauxProvider(allocator, .{
        .api = if (descriptor) |provider_descriptor| provider_descriptor.api else null,
        .provider = provider,
        .models = faux_models,
        .tokens_per_second = tokens_per_second,
    });
    errdefer registration.unregister();

    const owned_messages = try buildOwnedFauxMessages(allocator, env_map);
    errdefer {
        for (owned_messages) |*message| message.deinit(allocator);
        allocator.free(owned_messages);
    }

    if (owned_messages.len == 1) {
        try registration.setResponses(&[_]faux.FauxResponseStep{
            .{ .message = faux.fauxAssistantMessage(owned_messages[0].blocks, .{
                .stop_reason = parseFauxStopReason(env_map.get("PI_FAUX_STOP_REASON") orelse "stop") orelse
                    return error.InvalidFauxStopReason,
                .error_message = env_map.get("PI_FAUX_ERROR_MESSAGE") orelse defaultFauxErrorMessage(
                    parseFauxStopReason(env_map.get("PI_FAUX_STOP_REASON") orelse "stop") orelse .stop,
                ),
            }) },
        });
    } else {
        const final_stop_reason = parseFauxStopReason(env_map.get("PI_FAUX_STOP_REASON") orelse "stop") orelse
            return error.InvalidFauxStopReason;
        try registration.setResponses(&[_]faux.FauxResponseStep{
            .{ .message = faux.fauxAssistantMessage(owned_messages[0].blocks, .{
                .stop_reason = .tool_use,
            }) },
            .{ .message = faux.fauxAssistantMessage(owned_messages[1].blocks, .{
                .stop_reason = final_stop_reason,
                .error_message = env_map.get("PI_FAUX_ERROR_MESSAGE") orelse defaultFauxErrorMessage(final_stop_reason),
            }) },
        });
    }

    return .{
        .model = registration.getModel(),
        .api_key = null,
        .faux_registration = registration,
        .owned_faux_messages = owned_messages,
    };
}

fn buildOwnedFauxMessages(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
) (ResolveProviderError || std.mem.Allocator.Error)![]OwnedFauxMessage {
    if (env_map.get("PI_FAUX_TOOL_NAME")) |tool_name| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, env_map.get("PI_FAUX_TOOL_ARGS_JSON") orelse "{}", .{}) catch
            return error.InvalidFauxToolArguments;
        defer parsed.deinit();

        const first_blocks = try allocator.alloc(faux.FauxContentBlock, 1);
        const tool_args = try common.cloneJsonValue(allocator, parsed.value);
        defer common.deinitJsonValue(allocator, tool_args);
        first_blocks[0] = faux.fauxToolCall(allocator, tool_name, tool_args, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidFauxToolArguments,
        };

        const second_blocks = try allocator.alloc(faux.FauxContentBlock, 1);
        second_blocks[0] = faux.fauxText(env_map.get("PI_FAUX_TOOL_FINAL_RESPONSE") orelse "Tool execution complete");

        const messages = try allocator.alloc(OwnedFauxMessage, 2);
        messages[0] = .{ .blocks = first_blocks };
        messages[1] = .{ .blocks = second_blocks };
        return messages;
    }

    const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
    blocks[0] = faux.fauxText(env_map.get("PI_FAUX_RESPONSE") orelse "faux response");

    const messages = try allocator.alloc(OwnedFauxMessage, 1);
    messages[0] = .{ .blocks = blocks };
    return messages;
}

fn parseFauxStopReason(value: []const u8) ?ai.StopReason {
    if (std.mem.eql(u8, value, "stop")) return .stop;
    if (std.mem.eql(u8, value, "length")) return .length;
    if (std.mem.eql(u8, value, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, value, "error")) return .error_reason;
    if (std.mem.eql(u8, value, "error_reason")) return .error_reason;
    if (std.mem.eql(u8, value, "aborted")) return .aborted;
    return null;
}

fn defaultFauxErrorMessage(stop_reason: ai.StopReason) ?[]const u8 {
    return switch (stop_reason) {
        .error_reason => "Faux response failed",
        .aborted => "Request was aborted",
        else => null,
    };
}

fn fallbackModel(descriptor: ai.model_registry.ProviderConfig, model_id: []const u8) ai.Model {
    return .{
        .id = model_id,
        .name = model_id,
        .api = descriptor.api,
        .provider = descriptor.provider,
        .base_url = descriptor.base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };
}

fn hasProviderCredentials(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    provider: []const u8,
    configured_credentials: ConfiguredCredentials,
) !bool {
    if (std.mem.eql(u8, provider, "faux")) return true;
    if (shouldForceFauxProvider(env_map, provider)) return true;
    if (configured_credentials.lookup(provider) != null) return true;

    const api_key = try ai.env_api_keys.getEnvApiKeyFromMap(allocator, env_map, provider);
    defer if (api_key) |value| allocator.free(value);
    return api_key != null;
}

fn missingApiKeyMessage(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "openai") or
        std.mem.eql(u8, provider, "openai-responses") or
        std.mem.eql(u8, provider, "openai-codex"))
    {
        return "API key required. Use --api-key or set OPENAI_API_KEY.";
    }
    if (std.mem.eql(u8, provider, "azure-openai-responses")) {
        return "API key required. Use --api-key or set AZURE_OPENAI_API_KEY.";
    }
    if (std.mem.eql(u8, provider, "google")) {
        return "API key required. Use --api-key or set GEMINI_API_KEY.";
    }
    if (std.mem.eql(u8, provider, "google-gemini-cli")) {
        return "OAuth authentication required. Use /login to authenticate with Google Cloud Code Assist.";
    }
    if (std.mem.eql(u8, provider, "google-vertex")) {
        return "Credentials required. Use --api-key, set GOOGLE_CLOUD_API_KEY, or configure GOOGLE_APPLICATION_CREDENTIALS with GOOGLE_CLOUD_PROJECT and GOOGLE_CLOUD_LOCATION.";
    }
    if (std.mem.eql(u8, provider, "anthropic")) {
        return "API key required. Use --api-key or set ANTHROPIC_API_KEY or ANTHROPIC_OAUTH_TOKEN.";
    }
    if (std.mem.eql(u8, provider, "github-copilot")) {
        return "API key required. Use --api-key or set COPILOT_GITHUB_TOKEN, GH_TOKEN, or GITHUB_TOKEN.";
    }
    if (std.mem.eql(u8, provider, "amazon-bedrock")) {
        return "Credentials required. Use --api-key or configure AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, AWS_PROFILE, or another supported AWS auth source.";
    }
    if (std.mem.eql(u8, provider, "mistral")) {
        return "API key required. Use --api-key or set MISTRAL_API_KEY.";
    }
    if (std.mem.eql(u8, provider, "groq")) {
        return "API key required. Use --api-key or set GROQ_API_KEY.";
    }
    if (std.mem.eql(u8, provider, "cerebras")) {
        return "API key required. Use --api-key or set CEREBRAS_API_KEY.";
    }
    if (std.mem.eql(u8, provider, "xai")) {
        return "API key required. Use --api-key or set XAI_API_KEY.";
    }
    if (std.mem.eql(u8, provider, "openrouter")) {
        return "API key required. Use --api-key or set OPENROUTER_API_KEY.";
    }
    if (std.mem.eql(u8, provider, "vercel-ai-gateway")) {
        return "API key required. Use --api-key or set AI_GATEWAY_API_KEY.";
    }
    if (std.mem.eql(u8, provider, "zai")) {
        return "API key required. Use --api-key or set ZAI_API_KEY.";
    }
    if (std.mem.eql(u8, provider, "minimax")) {
        return "API key required. Use --api-key or set MINIMAX_API_KEY.";
    }
    if (std.mem.eql(u8, provider, "minimax-cn")) {
        return "API key required. Use --api-key or set MINIMAX_CN_API_KEY.";
    }
    if (std.mem.eql(u8, provider, "huggingface")) {
        return "API key required. Use --api-key or set HF_TOKEN.";
    }
    if (std.mem.eql(u8, provider, "fireworks")) {
        return "API key required. Use --api-key or set FIREWORKS_API_KEY.";
    }
    if (std.mem.eql(u8, provider, "opencode") or std.mem.eql(u8, provider, "opencode-go")) {
        return "API key required. Use --api-key or set OPENCODE_API_KEY.";
    }
    if (std.mem.eql(u8, provider, "kimi-coding")) {
        return "API key required. Use --api-key or set KIMI_API_KEY.";
    }
    if (std.mem.eql(u8, provider, "kimi")) {
        return "API key required. Use --api-key or set MOONSHOT_API_KEY.";
    }
    return "API credentials required. Use --api-key or configure the provider environment variables.";
}

test "resolveProviderConfig uses canonical defaults from model registry" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("OPENAI_API_KEY", "openai-key");

    var resolved = try resolveProviderConfig(allocator, &env_map, "openai", null, null, null);
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("openai-key", resolved.api_key.?);
    try std.testing.expectEqualStrings("gpt-5.4", resolved.model.id);
    try std.testing.expectEqualStrings("GPT-5.4", resolved.model.name);
    try std.testing.expectEqualStrings("openai-completions", resolved.model.api);
    try std.testing.expectEqualStrings("https://api.openai.com/v1", resolved.model.base_url);
    try std.testing.expectEqual(@as(u32, 400000), resolved.model.context_window);
    try std.testing.expectEqual(@as(u32, 128000), resolved.model.max_tokens);
    try std.testing.expectEqual(@as(usize, 2), resolved.model.input_types.len);
    try std.testing.expectEqualStrings("image", resolved.model.input_types[1]);
}

test "resolveProviderConfig supports non-legacy built-in providers" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("MISTRAL_API_KEY", "mistral-key");

    var resolved = try resolveProviderConfig(allocator, &env_map, "mistral", "devstral-medium-latest", null, null);
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("mistral-key", resolved.api_key.?);
    try std.testing.expectEqualStrings("devstral-medium-latest", resolved.model.id);
    try std.testing.expectEqualStrings("Devstral Medium Latest", resolved.model.name);
    try std.testing.expectEqualStrings("mistral-conversations", resolved.model.api);
    try std.testing.expectEqualStrings("mistral", resolved.model.provider);
}

test "resolveProviderConfig uses configured api key when env is missing" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var resolved = try resolveProviderConfig(allocator, &env_map, "openai", null, null, "configured-openai-key");
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("configured-openai-key", resolved.api_key.?);
    try std.testing.expectEqualStrings("gpt-5.4", resolved.model.id);
}

test "resolveProviderConfig can force faux responses for built-in providers" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("PI_FAUX_FORCE", "1");
    try env_map.put("PI_FAUX_RESPONSE", "forced faux response");

    var resolved = try resolveProviderConfig(allocator, &env_map, "openai", null, null, null);
    defer resolved.deinit(allocator);

    try std.testing.expectEqual(@as(?[]const u8, null), resolved.api_key);
    try std.testing.expect(resolved.faux_registration != null);
    try std.testing.expectEqualStrings("openai", resolved.model.provider);
    try std.testing.expectEqualStrings("openai-completions", resolved.model.api);
    try std.testing.expectEqualStrings("gpt-5.4", resolved.model.id);
}

test "resolveProviderConfig applies faux context window overrides" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("PI_FAUX_FORCE", "1");
    try env_map.put("PI_FAUX_CONTEXT_WINDOW", "48");
    try env_map.put("PI_FAUX_RESPONSE", "forced faux response");

    var resolved = try resolveProviderConfig(allocator, &env_map, "anthropic", null, null, null);
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("anthropic", resolved.model.provider);
    try std.testing.expectEqualStrings("claude-opus-4-7", resolved.model.id);
    try std.testing.expectEqual(@as(u32, 48), resolved.model.context_window);
}

test "listAvailableModels enumerates all built-in providers" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const current_model = ai.model_registry.find("faux", "faux-1").?;
    const models = try listAvailableModels(allocator, &env_map, current_model, .{});
    defer allocator.free(models);

    var found_openai = false;
    var found_anthropic = false;
    var found_google = false;
    var found_github_copilot = false;
    var found_groq = false;
    var found_cerebras = false;
    var found_xai = false;
    var found_fireworks = false;
    var found_huggingface = false;
    var found_openrouter = false;
    var found_faux = false;
    var openai_count: usize = 0;

    for (models) |entry| {
        if (std.mem.eql(u8, entry.provider, "openai")) {
            found_openai = true;
            openai_count += 1;
            if (std.mem.eql(u8, entry.model_id, "gpt-5.4")) {
                try std.testing.expectEqualStrings("GPT-5.4", entry.display_name);
                try std.testing.expect(!entry.available);
                try std.testing.expect(entry.supports_images);
            }
        } else if (std.mem.eql(u8, entry.provider, "anthropic")) {
            found_anthropic = true;
            if (std.mem.eql(u8, entry.model_id, "claude-opus-4-7")) {
                try std.testing.expect(entry.reasoning);
            }
        } else if (std.mem.eql(u8, entry.provider, "google")) {
            found_google = true;
        } else if (std.mem.eql(u8, entry.provider, "github-copilot")) {
            found_github_copilot = true;
            if (std.mem.eql(u8, entry.model_id, "gpt-5.4")) {
                try std.testing.expect(entry.supports_images);
                try std.testing.expect(entry.reasoning);
            }
        } else if (std.mem.eql(u8, entry.provider, "groq")) {
            found_groq = true;
        } else if (std.mem.eql(u8, entry.provider, "cerebras")) {
            found_cerebras = true;
        } else if (std.mem.eql(u8, entry.provider, "xai")) {
            found_xai = true;
        } else if (std.mem.eql(u8, entry.provider, "fireworks")) {
            found_fireworks = true;
        } else if (std.mem.eql(u8, entry.provider, "huggingface")) {
            found_huggingface = true;
        } else if (std.mem.eql(u8, entry.provider, "openrouter")) {
            found_openrouter = true;
            if (std.mem.eql(u8, entry.model_id, "qwen/qwen3-coder:exacto")) {
                try std.testing.expect(!entry.supports_images);
            }
        } else if (std.mem.eql(u8, entry.provider, "faux")) {
            found_faux = true;
            try std.testing.expect(entry.available);
        }
    }

    try std.testing.expect(found_openai);
    try std.testing.expect(found_anthropic);
    try std.testing.expect(found_google);
    try std.testing.expect(found_github_copilot);
    try std.testing.expect(found_groq);
    try std.testing.expect(found_cerebras);
    try std.testing.expect(found_xai);
    try std.testing.expect(found_fireworks);
    try std.testing.expect(found_huggingface);
    try std.testing.expect(found_openrouter);
    try std.testing.expect(found_faux);
    try std.testing.expect(openai_count >= 3);
    try std.testing.expect(models.len >= 20);
}

test "listAvailableModels does not treat GEMINI_API_KEY as google-gemini-cli auth" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("GEMINI_API_KEY", "gemini-key");

    const current_model = ai.model_registry.find("faux", "faux-1").?;
    const models = try listAvailableModels(allocator, &env_map, current_model, .{});
    defer allocator.free(models);

    var saw_google = false;
    var saw_google_gemini_cli = false;

    for (models) |entry| {
        if (std.mem.eql(u8, entry.provider, "google") and std.mem.eql(u8, entry.model_id, "gemini-2.5-pro")) {
            saw_google = true;
            try std.testing.expect(entry.available);
        }
        if (std.mem.eql(u8, entry.provider, "google-gemini-cli") and std.mem.eql(u8, entry.model_id, "gemini-3.1-pro-preview")) {
            saw_google_gemini_cli = true;
            try std.testing.expect(!entry.available);
        }
    }

    try std.testing.expect(saw_google);
    try std.testing.expect(saw_google_gemini_cli);
}

test "listAvailableModels treats configured credentials as available" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var auth_tokens = std.StringHashMap([]const u8).init(allocator);
    defer auth_tokens.deinit();
    try auth_tokens.put("kimi", "stored-kimi-key");

    const models = try listAvailableModels(allocator, &env_map, null, .{ .auth_tokens = &auth_tokens });
    defer allocator.free(models);

    var saw_kimi = false;
    for (models) |entry| {
        if (std.mem.eql(u8, entry.provider, "kimi") and std.mem.eql(u8, entry.model_id, "kimi-k2.6")) {
            saw_kimi = true;
            try std.testing.expect(entry.available);
        }
    }

    try std.testing.expect(saw_kimi);
}

test "findInitialDefaultModel uses configured kimi credentials" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var auth_tokens = std.StringHashMap([]const u8).init(allocator);
    defer auth_tokens.deinit();
    try auth_tokens.put("kimi", "stored-kimi-key");

    const model = (try findInitialDefaultModel(allocator, &env_map, .{ .auth_tokens = &auth_tokens })).?;
    try std.testing.expectEqualStrings("kimi", model.provider);
    try std.testing.expectEqualStrings("kimi-k2.6", model.id);
}

test "KIMI_API_KEY configures kimi-coding only" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("KIMI_API_KEY", "kimi-key");

    const models = try listAvailableModels(allocator, &env_map, null, .{});
    defer allocator.free(models);

    var saw_kimi = false;
    var saw_kimi_coding = false;
    for (models) |entry| {
        if (std.mem.eql(u8, entry.provider, "kimi") and std.mem.eql(u8, entry.model_id, "kimi-k2.6")) {
            saw_kimi = true;
            try std.testing.expect(!entry.available);
        }
        if (std.mem.eql(u8, entry.provider, "kimi-coding") and std.mem.eql(u8, entry.model_id, "kimi-for-coding")) {
            saw_kimi_coding = true;
            try std.testing.expect(entry.available);
        }
    }

    try std.testing.expect(saw_kimi);
    try std.testing.expect(saw_kimi_coding);

    const model = (try findInitialDefaultModel(allocator, &env_map, .{})).?;
    try std.testing.expectEqualStrings("kimi-coding", model.provider);
    try std.testing.expectEqualStrings("kimi-for-coding", model.id);
}

test "resolveProviderErrorMessage guides google-gemini-cli users to login" {
    try std.testing.expectEqualStrings(
        "OAuth authentication required. Use /login to authenticate with Google Cloud Code Assist.",
        resolveProviderErrorMessage(error.MissingApiKey, "google-gemini-cli"),
    );
}

test "filterAvailableModels supports scoped glob fuzzy and thinking suffix patterns" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const available = try listAvailableModels(allocator, &env_map, ai.model_registry.find("faux", "faux-1").?, .{});
    defer allocator.free(available);

    const anthropic_only = try filterAvailableModels(allocator, available, &.{"anthropic/sonnet"});
    defer allocator.free(anthropic_only);
    try std.testing.expectEqual(@as(usize, 2), anthropic_only.len);
    for (anthropic_only) |entry| {
        try std.testing.expectEqualStrings("anthropic", entry.provider);
        try std.testing.expect(containsIgnoreCase(entry.model_id, "sonnet"));
    }

    const globbed = try filterAvailableModels(allocator, available, &.{"openrouter/*exacto"});
    defer allocator.free(globbed);
    try std.testing.expectEqual(@as(usize, 1), globbed.len);
    try std.testing.expectEqualStrings("openrouter", globbed[0].provider);
    try std.testing.expectEqualStrings("qwen/qwen3-coder:exacto", globbed[0].model_id);

    const with_thinking = try filterAvailableModels(allocator, available, &.{"claude-sonnet:high"});
    defer allocator.free(with_thinking);
    try std.testing.expectEqual(@as(usize, 2), with_thinking.len);
}
