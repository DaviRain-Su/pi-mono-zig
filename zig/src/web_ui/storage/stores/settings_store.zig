const common = @import("../../common.zig");
pub const descriptor = common.descriptor("settings-store", "storage/stores/settings-store.ts", .storage);

const types = @import("../types.zig");

pub const STORE_NAME = "settings";

pub fn getConfig() types.StoreConfig {
    return .{ .name = STORE_NAME };
}

test "web-ui settings store has out-of-line keys" {
    const std = @import("std");
    const config = getConfig();
    try std.testing.expectEqualStrings(STORE_NAME, config.name);
    try std.testing.expect(config.key_path == null);
}
