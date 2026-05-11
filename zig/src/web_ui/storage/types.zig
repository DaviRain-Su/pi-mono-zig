const common = @import("../common.zig");
pub const descriptor = common.descriptor("types", "storage/types.ts", .storage);

const std = @import("std");

pub const StorageScope = enum {
    session,
    local,
};

pub const SortDirection = enum {
    asc,
    desc,
};

pub const TransactionMode = enum {
    readonly,
    readwrite,
};

pub const IndexConfig = struct {
    name: []const u8,
    key_path: []const u8,
    unique: bool = false,
};

pub const StoreConfig = struct {
    name: []const u8,
    key_path: ?[]const u8 = null,
    auto_increment: bool = false,
    indices: []const IndexConfig = &.{},
};

pub const UsageCost = struct {
    input: f64 = 0,
    output: f64 = 0,
    cache_read: f64 = 0,
    cache_write: f64 = 0,
    total: f64 = 0,
};

pub const UsageSummary = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    total_tokens: u64 = 0,
    cost: UsageCost = .{},
};

pub const SessionMetadata = struct {
    id: []const u8,
    title: []const u8,
    created_at: []const u8,
    last_modified: []const u8,
    message_count: usize = 0,
    usage: UsageSummary = .{},
    thinking_level: []const u8 = "off",
    preview: []const u8 = "",
};

pub const SessionData = struct {
    id: []const u8,
    title: []const u8,
    model_id: []const u8,
    thinking_level: []const u8 = "off",
    created_at: []const u8,
    last_modified: []const u8,
};

pub const IndexedDBConfig = struct {
    db_name: []const u8,
    version: u32,
    stores: []const StoreConfig,
};

pub const QuotaInfo = struct {
    usage: u64,
    quota: u64,
    percent: f64,
};

pub fn quotaInfo(usage: u64, quota: u64) QuotaInfo {
    return .{
        .usage = usage,
        .quota = quota,
        .percent = if (quota == 0) 0 else @as(f64, @floatFromInt(usage)) / @as(f64, @floatFromInt(quota)) * 100.0,
    };
}

test "web-ui storage quota computes percentage" {
    try std.testing.expectEqual(@as(f64, 25.0), quotaInfo(25, 100).percent);
}
