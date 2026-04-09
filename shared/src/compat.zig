const std = @import("std");

/// A wrapper around std.ArrayList that binds the allocator at initialization time.
/// This insulates callers from std.ArrayList API churn (e.g. explicit gpa parameters).
pub fn ManagedList(comptime T: type) type {
    return struct {
        const Self = @This();

        inner: std.ArrayList(T) = .empty,
        gpa: std.mem.Allocator,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit(self.gpa);
        }

        pub fn append(self: *Self, item: T) !void {
            try self.inner.append(self.gpa, item);
        }

        pub fn appendSlice(self: *Self, slice: []const T) !void {
            try self.inner.appendSlice(self.gpa, slice);
        }

        pub fn orderedRemove(self: *Self, i: usize) T {
            return self.inner.orderedRemove(i);
        }

        pub fn toOwnedSlice(self: *Self) ![]T {
            return try self.inner.toOwnedSlice(self.gpa);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.inner.clearRetainingCapacity();
        }

        pub fn items(self: Self) []T {
            return self.inner.items;
        }

        pub fn len(self: Self) usize {
            return self.inner.items.len;
        }
    };
}

/// Encodes the rule: "slices that escape a function must be heap-allocated".
/// At comptime we cannot detect stack vs heap, but the explicit `fromHeap`
/// constructor makes the intent auditable.
pub fn OwnedSlice(comptime T: type) type {
    return struct {
        const Self = @This();

        ptr: []T,
        allocator: std.mem.Allocator,

        pub fn fromHeap(allocator: std.mem.Allocator, source: []const T) !Self {
            const copied = try allocator.alloc(T, source.len);
            @memcpy(copied, source);
            return .{ .ptr = copied, .allocator = allocator };
        }

        pub fn deinit(self: Self) void {
            self.allocator.free(self.ptr);
        }

        pub fn slice(self: Self) []T {
            return self.ptr;
        }

        pub fn constSlice(self: Self) []const T {
            return self.ptr;
        }
    };
}
