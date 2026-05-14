//! Owned `StringHashMap` header helpers for Anthropic HTTP requests and `on_response` normalization.

const std = @import("std");
const asciiLowerAlloc = @import("../shared/string_utils.zig").asciiLowerAlloc;

pub fn putOwnedHeader(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    name: []const u8,
    value: []const u8,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    if (try headers.fetchPut(owned_name, owned_value)) |previous| {
        allocator.free(previous.key);
        allocator.free(previous.value);
    }
}

pub fn mergeHeaders(
    allocator: std.mem.Allocator,
    target: *std.StringHashMap([]const u8),
    source: ?std.StringHashMap([]const u8),
) !void {
    if (source) |headers| {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            try putOwnedHeader(allocator, target, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

pub fn deinitOwnedHeaders(allocator: std.mem.Allocator, headers: *std.StringHashMap([]const u8)) void {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    headers.deinit();
}

/// Normalize response header names to TypeScript-compatible lowercase keys
/// before invoking `on_response` callbacks. Mirrors the OpenAI Chat path so
/// callbacks can rely on consistent lookup semantics regardless of the
/// on-the-wire casing emitted by the upstream server.
pub fn normalizedResponseHeaders(
    allocator: std.mem.Allocator,
    maybe_headers: ?std.StringHashMap([]const u8),
) !std.StringHashMap([]const u8) {
    var normalized = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitOwnedHeaders(allocator, &normalized);

    if (maybe_headers) |headers| {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            const lower = try asciiLowerAlloc(allocator, entry.key_ptr.*);
            defer allocator.free(lower);
            try putOwnedHeader(allocator, &normalized, lower, entry.value_ptr.*);
        }
    }

    return normalized;
}
