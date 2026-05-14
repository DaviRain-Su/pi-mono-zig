//! Provider-specific capability flags parsed from `model.compat` JSON.

const std = @import("std");
const types = @import("../types.zig");

pub const AnthropicCompat = struct {
    supports_eager_tool_input_streaming: bool = true,
    supports_long_cache_retention: bool = true,
    send_session_affinity_headers: bool = false,
    supports_cache_control_on_tools: bool = true,
};

fn compatBoolField(compat: ?std.json.Value, key: []const u8) ?bool {
    const value = compat orelse return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field != .bool) return null;
    return field.bool;
}

pub fn getAnthropicCompat(model: types.Model) AnthropicCompat {
    const is_fireworks = std.mem.eql(u8, model.provider, "fireworks");
    const is_cloudflare_ai_gateway_anthropic =
        std.mem.eql(u8, model.provider, "cloudflare-ai-gateway") and
        std.mem.indexOf(u8, model.base_url, "anthropic") != null;

    return .{
        .supports_eager_tool_input_streaming = compatBoolField(model.compat, "supportsEagerToolInputStreaming") orelse !is_fireworks,
        .supports_long_cache_retention = compatBoolField(model.compat, "supportsLongCacheRetention") orelse !is_fireworks,
        .send_session_affinity_headers = compatBoolField(model.compat, "sendSessionAffinityHeaders") orelse (is_fireworks or is_cloudflare_ai_gateway_anthropic),
        .supports_cache_control_on_tools = compatBoolField(model.compat, "supportsCacheControlOnTools") orelse !is_fireworks,
    };
}
