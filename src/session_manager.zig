const std = @import("std");
const json_util = @import("json_util.zig");
const st = @import("session_types.zig");

pub const SessionHeader = st.SessionHeader;
pub const MessageEntry = st.MessageEntry;
pub const ToolCallEntry = st.ToolCallEntry;
pub const ToolResultEntry = st.ToolResultEntry;
pub const Entry = st.Entry;

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
            const stat = try f.stat();
            if (stat.size > 0) return;
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

    pub fn appendToolCall(self: *SessionManager, tool: []const u8, arg: []const u8) !void {
        const entry = ToolCallEntry{
            .id = try self.newId(),
            .timestamp = try nowIso(self.arena),
            .tool = tool,
            .arg = arg,
        };
        try json_util.appendJsonLine(self.session_path, entry);
    }

    pub fn appendToolResult(self: *SessionManager, tool: []const u8, ok: bool, content: []const u8) !void {
        const entry = ToolResultEntry{
            .id = try self.newId(),
            .timestamp = try nowIso(self.arena),
            .tool = tool,
            .ok = ok,
            .content = content,
        };
        try json_util.appendJsonLine(self.session_path, entry);
    }

    pub fn loadEntries(self: *SessionManager) ![]Entry {
        var f = try std.fs.cwd().openFile(self.session_path, .{});
        defer f.close();
        const bytes = try f.readToEndAlloc(self.arena, 64 * 1024 * 1024);

        var out = try std.ArrayList(Entry).initCapacity(self.arena, 0);
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
            const typ = switch (obj.get("type") orelse continue) {
                .string => |s| s,
                else => continue,
            };

            if (std.mem.eql(u8, typ, "message")) {
                const id = switch (obj.get("id") orelse continue) { .string => |s| s, else => continue };
                const ts = switch (obj.get("timestamp") orelse continue) { .string => |s| s, else => continue };
                const role = switch (obj.get("role") orelse continue) { .string => |s| s, else => continue };
                const content = switch (obj.get("content") orelse continue) { .string => |s| s, else => continue };
                try out.append(self.arena, .{ .message = .{ .id = id, .timestamp = ts, .role = role, .content = content } });
                continue;
            }

            if (std.mem.eql(u8, typ, "tool_call")) {
                const id = switch (obj.get("id") orelse continue) { .string => |s| s, else => continue };
                const ts = switch (obj.get("timestamp") orelse continue) { .string => |s| s, else => continue };
                const tool = switch (obj.get("tool") orelse continue) { .string => |s| s, else => continue };
                const arg = switch (obj.get("arg") orelse continue) { .string => |s| s, else => continue };
                try out.append(self.arena, .{ .tool_call = .{ .id = id, .timestamp = ts, .tool = tool, .arg = arg } });
                continue;
            }

            if (std.mem.eql(u8, typ, "tool_result")) {
                const id = switch (obj.get("id") orelse continue) { .string => |s| s, else => continue };
                const ts = switch (obj.get("timestamp") orelse continue) { .string => |s| s, else => continue };
                const tool = switch (obj.get("tool") orelse continue) { .string => |s| s, else => continue };
                const ok = switch (obj.get("ok") orelse continue) { .bool => |b| b, else => continue };
                const content = switch (obj.get("content") orelse continue) { .string => |s| s, else => continue };
                try out.append(self.arena, .{ .tool_result = .{ .id = id, .timestamp = ts, .tool = tool, .ok = ok, .content = content } });
                continue;
            }

            // ignore unknown types for forward compatibility
        }

        return try out.toOwnedSlice(self.arena);
    }

    pub fn loadMessages(self: *SessionManager) ![]MessageEntry {
        // compatibility helper for existing code
        const entries = try self.loadEntries();
        var out = try std.ArrayList(MessageEntry).initCapacity(self.arena, 0);
        defer out.deinit(self.arena);
        for (entries) |e| {
            switch (e) {
                .message => |m| try out.append(self.arena, m),
                else => {},
            }
        }
        return try out.toOwnedSlice(self.arena);
    }
};
