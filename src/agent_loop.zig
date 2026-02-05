const std = @import("std");
const session = @import("session_manager.zig");
const tools = @import("tools.zig");
const mock_model = @import("mock_model.zig");
const events = @import("events.zig");

pub const AgentLoop = struct {
    arena: std.mem.Allocator,
    session_mgr: *session.SessionManager,
    tools_reg: *tools.ToolRegistry,
    bus: *events.EventBus,
    turn: u64 = 0,

    pub fn init(
        arena: std.mem.Allocator,
        session_mgr: *session.SessionManager,
        tools_reg: *tools.ToolRegistry,
        bus: *events.EventBus,
    ) AgentLoop {
        return .{ .arena = arena, .session_mgr = session_mgr, .tools_reg = tools_reg, .bus = bus };
    }

    pub fn step(self: *AgentLoop) !bool {
        // Load full entry list (MVP). Later we can incrementally track.
        const entries = try self.session_mgr.loadEntries();

        self.turn += 1;
        self.bus.emit(.{ .turn_start = .{ .turn = self.turn } });

        const out = try mock_model.next(self.arena, entries);
        switch (out) {
            .final_text => |t| {
                _ = try self.session_mgr.appendMessage("assistant", t);
                self.bus.emit(.{ .message_append = .{ .role = "assistant", .content = t } });
                self.bus.emit(.{ .turn_end = .{ .turn = self.turn } });
                return true;
            },
            .tool_call => |c| {
                // record tool call entry
                _ = try self.session_mgr.appendToolCall(c.tool, c.arg);
                self.bus.emit(.{ .tool_execution_start = .{ .tool = c.tool, .arg = c.arg } });

                const res = self.tools_reg.execute(c) catch |e| {
                    const err_line = try std.fmt.allocPrint(self.arena, "{s}", .{@errorName(e)});
                    _ = try self.session_mgr.appendToolResult(c.tool, false, err_line);
                    self.bus.emit(.{ .tool_execution_end = .{ .tool = c.tool, .ok = false, .content = err_line } });
                    self.bus.emit(.{ .turn_end = .{ .turn = self.turn } });
                    return false;
                };

                _ = try self.session_mgr.appendToolResult(c.tool, true, res.content);
                self.bus.emit(.{ .tool_execution_end = .{ .tool = c.tool, .ok = true, .content = res.content } });

                self.bus.emit(.{ .turn_end = .{ .turn = self.turn } });
                return false; // not done, need another model step
            },
        }
    }
};
