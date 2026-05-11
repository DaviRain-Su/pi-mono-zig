const common = @import("../common.zig");
pub const descriptor = common.descriptor("auth-token", "utils/auth-token.ts", .util);

pub const AUTH_TOKEN_STORAGE_KEY = "auth-token";

pub fn hasBearerPrefix(value: []const u8) bool {
    const std = @import("std");
    return std.mem.startsWith(u8, value, "Bearer ");
}

pub fn trimAuthToken(value: []const u8) []const u8 {
    const std = @import("std");
    return std.mem.trim(u8, value, " \t\r\n");
}

test "web-ui auth token trimming mirrors prompt input handling" {
    const std = @import("std");
    try std.testing.expectEqualStrings("token", trimAuthToken("  token\n"));
}
