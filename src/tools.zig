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
            const io = std.Io.Threaded.global_single_threaded.io();
            const result = try std.process.run(
                self.arena,
                io,
                .{
                    .argv = &.{ "sh", "-lc", call.arg },
                    .cwd = null,
                    .max_output_bytes = 1024 * 1024,
                },
            );
            defer self.arena.free(result.stdout);
            defer self.arena.free(result.stderr);

            switch (result.term) {
                .exited => |code| if (code != 0) return error.ShellCommandFailed,
                else => return error.ShellCommandFailed,
            }
            return .{ .ok = true, .content = result.stdout };
        }

        return error.UnknownTool;
    }
};
