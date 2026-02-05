const std = @import("std");

pub const ToolCall = struct {
    tool: []const u8,
    // for MVP: a single string arg
    arg: []const u8,
};

pub const ToolResult = struct {
    ok: bool,
    content: []const u8,
};

pub const ToolRegistry = struct {
    arena: std.mem.Allocator,
    allow_shell: bool = false,

    pub fn init(arena: std.mem.Allocator) ToolRegistry {
        return .{ .arena = arena };
    }

    pub fn execute(self: *ToolRegistry, call: ToolCall) !ToolResult {
        if (std.mem.eql(u8, call.tool, "echo")) {
            return .{ .ok = true, .content = call.arg };
        }
        if (std.mem.eql(u8, call.tool, "shell")) {
            if (!self.allow_shell) return error.ShellDisabled;
            // very MVP: run `sh -lc <arg>` and capture stdout
            var child = std.process.Child.init(&.{ "sh", "-lc", call.arg }, self.arena);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;
            try child.spawn();
            var r = std.fs.File.deprecatedReader(child.stdout.?);
            const out_bytes = try r.readAllAlloc(self.arena, 1024 * 1024);
            _ = try child.wait();
            return .{ .ok = true, .content = out_bytes };
        }

        return error.UnknownTool;
    }
};
