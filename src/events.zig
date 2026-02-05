const std = @import("std");

pub const Event = union(enum) {
    turn_start: struct { turn: u64 },
    turn_end: struct { turn: u64 },

    message_append: struct { role: []const u8, content: []const u8 },

    tool_execution_start: struct { tool: []const u8, arg: []const u8 },
    tool_execution_end: struct { tool: []const u8, ok: bool, content: []const u8 },
};

pub const Listener = *const fn (ctx: *anyopaque, ev: Event) void;

pub const EventBus = struct {
    arena: std.mem.Allocator,
    listeners: []Listener = &.{},
    listener_ctx: []*anyopaque = &.{},

    pub fn init(arena: std.mem.Allocator) EventBus {
        return .{ .arena = arena };
    }

    pub fn subscribe(self: *EventBus, ctx: *anyopaque, f: Listener) !void {
        const n = self.listeners.len;
        const new_ls = try self.arena.alloc(Listener, n + 1);
        const new_ctx = try self.arena.alloc(*anyopaque, n + 1);
        @memcpy(new_ls[0..n], self.listeners);
        @memcpy(new_ctx[0..n], self.listener_ctx);
        new_ls[n] = f;
        new_ctx[n] = ctx;
        self.listeners = new_ls;
        self.listener_ctx = new_ctx;
    }

    pub fn emit(self: *EventBus, ev: Event) void {
        for (self.listeners, 0..) |f, i| {
            f(self.listener_ctx[i], ev);
        }
    }
};
