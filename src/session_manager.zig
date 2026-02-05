const std = @import("std");
const json_util = @import("json_util.zig");

pub const SessionHeader = struct {
    type: []const u8 = "session",
    version: u32 = 1,
    id: []const u8,
    timestamp: []const u8,
    cwd: []const u8,
};

pub const MessageEntry = struct {
    type: []const u8 = "message",
    id: []const u8,
    timestamp: []const u8,
    role: []const u8, // user|assistant|tool
    content: []const u8,
};

pub const SessionManager = struct {
    arena: std.mem.Allocator,
    session_path: []const u8,
    cwd: []const u8,
    seq: u64 = 0,

    pub fn init(arena: std.mem.Allocator, session_path: []const u8, cwd: []const u8) SessionManager {
        return .{ .arena = arena, .session_path = session_path, .cwd = cwd };
    }

    fn nowIso(arena: std.mem.Allocator) ![]const u8 {
        // good enough for MVP: unixms as string
        return try std.fmt.allocPrint(arena, "{d}", .{std.time.milliTimestamp()});
    }

    fn newId(self: *SessionManager) ![]const u8 {
        self.seq += 1;
        return try std.fmt.allocPrint(self.arena, "e_{d}_{d}", .{ std.time.milliTimestamp(), self.seq });
    }

    pub fn ensure(self: *SessionManager) !void {
        // if file exists and non-empty, assume ok
        const stat_res = std.fs.cwd().statFile(self.session_path);
        if (stat_res) |_| {
            // If empty, rewrite header
            const f = try std.fs.cwd().openFile(self.session_path, .{});
            defer f.close();
            const st = try f.stat();
            if (st.size > 0) return;
        } else |_| {
            // create parent dir
            if (std.fs.path.dirname(self.session_path)) |dir| {
                std.fs.cwd().makePath(dir) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return e,
                };
            }
            _ = try std.fs.cwd().createFile(self.session_path, .{ .truncate = true });
        }

        // write header line
        const sid = try std.fmt.allocPrint(self.arena, "s_{d}", .{std.time.milliTimestamp()});
        const header = SessionHeader{
            .id = sid,
            .timestamp = try nowIso(self.arena),
            .cwd = self.cwd,
        };
        try json_util.writeJsonLine(self.session_path, header);
    }

    pub fn appendMessage(self: *SessionManager, role: []const u8, content: []const u8) !void {
        const entry = MessageEntry{
            .id = try self.newId(),
            .timestamp = try nowIso(self.arena),
            .role = role,
            .content = content,
        };
        try json_util.appendJsonLine(self.session_path, entry);
    }

    pub fn loadMessages(self: *SessionManager) ![]MessageEntry {
        var f = try std.fs.cwd().openFile(self.session_path, .{});
        defer f.close();
        const bytes = try f.readToEndAlloc(self.arena, 64 * 1024 * 1024);

        var out = try std.ArrayList(MessageEntry).initCapacity(self.arena, 0);
        defer out.deinit(self.arena);

        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            var parsed = try json_util.parseJson(self.arena, line);
            defer parsed.deinit();
            const obj = switch (parsed.value) {
                .object => |o| o,
                else => continue,
            };
            const type_v = obj.get("type") orelse continue;
            const typ = switch (type_v) {
                .string => |s| s,
                else => continue,
            };
            if (!std.mem.eql(u8, typ, "message")) continue;

            const id = switch (obj.get("id") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const ts = switch (obj.get("timestamp") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const role = switch (obj.get("role") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const content = switch (obj.get("content") orelse continue) {
                .string => |s| s,
                else => continue,
            };

            try out.append(self.arena, .{ .id = id, .timestamp = ts, .role = role, .content = content });
        }

        return try out.toOwnedSlice(self.arena);
    }
};
