const std = @import("std");

/// std.Thread.Mutex API may change between Zig versions (e.g. init() vs .{}).
/// Use this alias + factory so that only one place needs to be updated.
pub const Mutex = std.Thread.Mutex;
pub inline fn createMutex() Mutex {
    return .{};
}

/// std.Thread.Condition API may change between Zig versions.
pub const Condition = std.Thread.Condition;
pub inline fn createCondition() Condition {
    return .{};
}

/// A wrapper around std.ArrayList that binds the allocator at initialization time.
/// This insulates callers from std.ArrayList API churn (e.g. explicit gpa parameters).
pub fn ManagedList(comptime T: type) type {
    return struct {
        const Self = @This();

        // Deliberately no default field initializers: init() is the only supported path.
        inner: std.ArrayList(T),
        gpa: std.mem.Allocator,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .inner = .empty, .gpa = gpa };
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

/// JSON helpers that insulate callers from std.json.Value/ObjectMap init churn.
pub fn jsonNull() std.json.Value {
    return .null;
}

pub fn jsonEmptyObject(gpa: std.mem.Allocator) std.json.Value {
    return .{ .object = std.json.ObjectMap.init(gpa) };
}

pub fn jsonString(s: []const u8) std.json.Value {
    return .{ .string = s };
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
