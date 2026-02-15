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
        // TS-like: use business-only context for model decisions (structural entries are excluded).
        const entries = try self.session_mgr.buildContextEntries();

        // Find the latest user message id to associate with this turn.
        const user_mid = blk: {
            var i: usize = entries.len;
            while (i > 0) : (i -= 1) {
                const e = entries[i - 1];
                switch (e) {
                    .message => |m| {
                        if (std.mem.eql(u8, m.role, "user")) break :blk m.id;
                    },
                    else => {},
                }
            }
            break :blk null;
        };

        const turn_group = user_mid;

        self.turn += 1;
        _ = try self.session_mgr.appendTurnStart(self.turn, user_mid, turn_group, "step");
        self.bus.emit(.{ .turn_start = .{ .turn = self.turn } });

        const out = try mock_model.next(self.arena, entries);
        switch (out) {
            .final_text => |t| {
                // Best-effort usage estimate for sizing.
                const tokens_est = (t.len + 3) / 4;
                _ = try self.session_mgr.appendMessageWithTokensEst("assistant", t, tokens_est);
                self.bus.emit(.{ .message_append = .{ .role = "assistant", .content = t } });
                _ = try self.session_mgr.appendTurnEnd(self.turn, user_mid, turn_group, "final");
                self.bus.emit(.{ .turn_end = .{ .turn = self.turn } });
                return true;
            },
            .tool_call => |c| {
                // record tool call entry (best-effort tokens)
                const tc_tokens = (c.arg.len + 3) / 4 + 8;
                _ = try self.session_mgr.appendToolCallWithTokensEst(c.tool, c.arg, tc_tokens);
                self.bus.emit(.{ .tool_execution_start = .{ .tool = c.tool, .arg = c.arg } });

                const res = self.tools_reg.execute(c) catch |e| {
                    const err_line = try std.fmt.allocPrint(self.arena, "{s}", .{@errorName(e)});
                    const tr_tokens = (err_line.len + 3) / 4 + 8;
                    _ = try self.session_mgr.appendToolResultWithTokensEst(c.tool, false, err_line, tr_tokens);
                    self.bus.emit(.{ .tool_execution_end = .{ .tool = c.tool, .ok = false, .content = err_line } });
                    _ = try self.session_mgr.appendTurnEnd(self.turn, user_mid, turn_group, "error");
                    self.bus.emit(.{ .turn_end = .{ .turn = self.turn } });
                    return false;
                };

                const tr_tokens = (res.content.len + 3) / 4 + 8;
                _ = try self.session_mgr.appendToolResultWithTokensEst(c.tool, true, res.content, tr_tokens);
                self.bus.emit(.{ .tool_execution_end = .{ .tool = c.tool, .ok = true, .content = res.content } });

                _ = try self.session_mgr.appendTurnEnd(self.turn, user_mid, turn_group, "tool");
                self.bus.emit(.{ .turn_end = .{ .turn = self.turn } });
                return false; // not done, need another model step
            },
        }
    }
};
