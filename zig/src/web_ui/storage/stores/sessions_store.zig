const common = @import("../../common.zig");
pub const descriptor = common.descriptor("sessions-store", "storage/stores/sessions-store.ts", .storage);

const std = @import("std");
const types = @import("../types.zig");

pub const SESSIONS_STORE_NAME = "sessions";
pub const METADATA_STORE_NAME = "sessions-metadata";

const last_modified_index = [_]types.IndexConfig{.{ .name = "lastModified", .key_path = "lastModified" }};

pub fn getConfig() types.StoreConfig {
    return .{
        .name = SESSIONS_STORE_NAME,
        .key_path = "id",
        .indices = &last_modified_index,
    };
}

pub fn getMetadataConfig() types.StoreConfig {
    return .{
        .name = METADATA_STORE_NAME,
        .key_path = "id",
        .indices = &last_modified_index,
    };
}

pub fn latestSessionId(metadata: []const types.SessionMetadata) ?[]const u8 {
    if (metadata.len == 0) return null;
    var latest = metadata[0];
    for (metadata[1..]) |item| {
        if (std.mem.order(u8, item.last_modified, latest.last_modified) == .gt) latest = item;
    }
    return latest.id;
}

pub fn metadataFromState(id: []const u8, title: []const u8, now_iso: []const u8, message_count: usize, thinking_level: ?[]const u8) types.SessionMetadata {
    return .{
        .id = id,
        .title = title,
        .created_at = now_iso,
        .last_modified = now_iso,
        .message_count = message_count,
        .thinking_level = thinking_level orelse "off",
    };
}

test "web-ui sessions store configs include metadata store and lastModified index" {
    try std.testing.expectEqualStrings(SESSIONS_STORE_NAME, getConfig().name);
    try std.testing.expectEqualStrings(METADATA_STORE_NAME, getMetadataConfig().name);
    try std.testing.expectEqualStrings("lastModified", getConfig().indices[0].name);
}

test "web-ui sessions latest id sorts by ISO timestamp strings" {
    const items = [_]types.SessionMetadata{
        .{ .id = "a", .title = "A", .created_at = "2026-01-01T00:00:00Z", .last_modified = "2026-01-02T00:00:00Z" },
        .{ .id = "b", .title = "B", .created_at = "2026-01-01T00:00:00Z", .last_modified = "2026-01-03T00:00:00Z" },
    };
    try std.testing.expectEqualStrings("b", latestSessionId(&items).?);
}
