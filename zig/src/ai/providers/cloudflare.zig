const std = @import("std");
const types = @import("../types.zig");

/// Workers AI direct endpoint.
pub const CLOUDFLARE_WORKERS_AI_BASE_URL = "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1";

/// AI Gateway Unified API. https://developers.cloudflare.com/ai-gateway/usage/unified-api/
pub const CLOUDFLARE_AI_GATEWAY_COMPAT_BASE_URL = "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/compat";

/// AI Gateway → OpenAI passthrough. Used until /compat supports /v1/responses.
pub const CLOUDFLARE_AI_GATEWAY_OPENAI_BASE_URL = "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/openai";

/// AI Gateway → Anthropic passthrough.
pub const CLOUDFLARE_AI_GATEWAY_ANTHROPIC_BASE_URL = "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/anthropic";

/// Check if the provider is a Cloudflare provider.
pub fn isCloudflareProvider(provider: []const u8) bool {
    return std.mem.eql(u8, provider, "cloudflare-workers-ai") or
        std.mem.eql(u8, provider, "cloudflare-ai-gateway");
}

/// Substitute `{VAR}` placeholders in a Cloudflare baseUrl from environment variables.
/// Returns an error if a required environment variable is not set.
pub fn resolveCloudflareBaseUrl(
    allocator: std.mem.Allocator,
    model: types.Model,
) ![]const u8 {
    const url = model.base_url;
    if (std.mem.indexOf(u8, url, "{") == null) {
        return url;
    }

    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < url.len) {
        if (url[i] == '{') {
            const start = i + 1;
            i = start;
            while (i < url.len and url[i] != '}') : (i += 1) {}
            if (i >= url.len) {
                return error.InvalidPlaceholder;
            }
            const var_name = url[start..i];
            i += 1; // skip '}'

            const env_value = std.process.getEnv(var_name) catch null;
            if (env_value == null) {
                return error.EnvironmentVariableNotFound;
            }
            try result.appendSlice(env_value.?);
        } else {
            try result.append(url[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}