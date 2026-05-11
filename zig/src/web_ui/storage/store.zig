const common = @import("../common.zig");
pub const descriptor = common.descriptor("store", "storage/store.ts", .storage);

const types = @import("types.zig");

pub const Store = struct {
    config: types.StoreConfig,
    backend_set: bool = false,

    pub fn setBackend(self: *Store) void {
        self.backend_set = true;
    }

    pub fn hasBackend(self: Store) bool {
        return self.backend_set;
    }
};

pub fn makeStore(config: types.StoreConfig) Store {
    return .{ .config = config };
}

test "web-ui base store records backend initialization" {
    const std = @import("std");
    var store = makeStore(.{ .name = "settings" });
    try std.testing.expect(!store.hasBackend());
    store.setBackend();
    try std.testing.expect(store.hasBackend());
}
