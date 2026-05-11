const common = @import("../common.zig");
pub const descriptor = common.descriptor("app-storage", "storage/app-storage.ts", .storage);

const std = @import("std");
const types = @import("types.zig");

pub const AppStorage = struct {
    quota: types.QuotaInfo = .{ .usage = 0, .quota = 0, .percent = 0 },
    persistence_granted: bool = false,

    pub fn getQuotaInfo(self: AppStorage) types.QuotaInfo {
        return self.quota;
    }

    pub fn requestPersistence(self: AppStorage) bool {
        return self.persistence_granted;
    }
};

var global_app_storage: ?*AppStorage = null;

pub fn setAppStorage(storage: *AppStorage) void {
    global_app_storage = storage;
}

pub fn getAppStorage() ?*AppStorage {
    return global_app_storage;
}

pub fn clearAppStorage() void {
    global_app_storage = null;
}

test "web-ui app storage global instance mirrors TS lifecycle" {
    clearAppStorage();
    try std.testing.expect(getAppStorage() == null);
    var storage = AppStorage{ .quota = types.quotaInfo(1, 4), .persistence_granted = true };
    setAppStorage(&storage);
    try std.testing.expectEqual(@as(f64, 25.0), getAppStorage().?.getQuotaInfo().percent);
    try std.testing.expect(getAppStorage().?.requestPersistence());
}
