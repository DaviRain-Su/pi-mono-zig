const std = @import("std");
const compat = @import("compat.zig");

/// A simple event stream channel built on top of compat.Mutex + std.ArrayList.
pub fn EventStream(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: compat.Mutex = compat.createMutex(),
        cond: compat.Condition = compat.createCondition(),
        items: std.ArrayList(T),
        closed: bool = false,
        gpa: std.mem.Allocator,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{
                .items = std.ArrayList(T).init(gpa),
                .gpa = gpa,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.items.deinit();
        }

        pub fn push(self: *Self, item: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.items.append(item) catch @panic("OOM");
            self.cond.signal();
        }

        pub fn next(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.items.items.len == 0 and !self.closed) {
                self.cond.wait(&self.mutex);
            }
            if (self.items.items.len == 0) return null;
            return self.items.orderedRemove(0);
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.cond.broadcast();
        }
    };
}
