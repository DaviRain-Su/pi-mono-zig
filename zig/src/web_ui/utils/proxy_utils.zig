const common = @import("../common.zig");
pub const descriptor = common.descriptor("proxy-utils", "utils/proxy-utils.ts", .util);

const std = @import("std");

pub const ModelProxyInfo = struct {
    provider: []const u8,
    base_url: ?[]const u8 = null,
};

pub fn shouldUseProxyForProvider(provider: []const u8, api_key: []const u8) bool {
    if (asciiEqlIgnoreCase(provider, "zai")) return true;
    if (asciiEqlIgnoreCase(provider, "anthropic")) {
        return std.mem.startsWith(u8, api_key, "sk-ant-oat") or std.mem.startsWith(u8, api_key, "{");
    }
    if (asciiEqlIgnoreCase(provider, "openai-codex")) return true;
    return false;
}

pub fn applyProxyBaseUrl(allocator: std.mem.Allocator, model: ModelProxyInfo, api_key: []const u8, proxy_url: ?[]const u8) !?[]u8 {
    const base_url = model.base_url orelse return null;
    const proxy = proxy_url orelse return allocator.dupe(u8, base_url);
    if (!shouldUseProxyForProvider(model.provider, api_key)) return allocator.dupe(u8, base_url);
    const encoded = try percentEncode(allocator, base_url);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "{s}/?url={s}", .{ proxy, encoded });
}

pub fn isCorsError(name: []const u8, message: []const u8) bool {
    var buffer: [512]u8 = undefined;
    const lower = asciiLowerBounded(message, &buffer);
    return (std.mem.eql(u8, name, "TypeError") and std.mem.indexOf(u8, lower, "failed to fetch") != null) or
        std.mem.eql(u8, name, "NetworkError") or
        std.mem.indexOf(u8, lower, "cors") != null or
        std.mem.indexOf(u8, lower, "cross-origin") != null;
}

pub fn joinProxyPath(base: []const u8, path: []const u8) struct { base: []const u8, path: []const u8 } {
    return .{ .base = base, .path = path };
}

fn asciiEqlIgnoreCase(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn asciiLowerBounded(value: []const u8, buffer: []u8) []const u8 {
    const len = @min(value.len, buffer.len);
    for (value[0..len], 0..) |byte, index| buffer[index] = std.ascii.toLower(byte);
    return buffer[0..len];
}

fn percentEncode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try out.writer.writeByte(byte);
        } else {
            try out.writer.print("%{X:0>2}", .{byte});
        }
    }
    return out.toOwnedSlice();
}

test "web-ui proxy rules match TS provider decisions" {
    try std.testing.expect(shouldUseProxyForProvider("zai", "key"));
    try std.testing.expect(shouldUseProxyForProvider("anthropic", "sk-ant-oat-token"));
    try std.testing.expect(!shouldUseProxyForProvider("anthropic", "sk-ant-api-token"));
    try std.testing.expect(!shouldUseProxyForProvider("openai", "sk-key"));
}

test "web-ui proxy applies encoded base url only when needed" {
    const allocator = std.testing.allocator;
    const proxied = (try applyProxyBaseUrl(allocator, .{ .provider = "zai", .base_url = "https://api.example/v1" }, "key", "https://proxy")) orelse unreachable;
    defer allocator.free(proxied);
    try std.testing.expectEqualStrings("https://proxy/?url=https%3A%2F%2Fapi.example%2Fv1", proxied);
}
