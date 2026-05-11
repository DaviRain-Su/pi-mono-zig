const common = @import("../../common.zig");
pub const descriptor = common.descriptor("provider-keys-store", "storage/stores/provider-keys-store.ts", .storage);

const types = @import("../types.zig");

pub const STORE_NAME = "provider-keys";

pub fn getConfig() types.StoreConfig {
    return .{ .name = STORE_NAME };
}

pub fn keyForProvider(provider: []const u8) []const u8 {
    return provider;
}

test "web-ui provider keys store config matches TS store name" {
    const std = @import("std");
    try std.testing.expectEqualStrings(STORE_NAME, getConfig().name);
}
