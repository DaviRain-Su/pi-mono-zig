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

    fn tokensEstForContextEntry(e: session.Entry) usize {
        return switch (e) {
            .message => |m| m.tokensEst orelse ((m.content.len + 3) / 4),
            .custom_message => |cm| (cm.content.len + 3) / 4,
            .tool_call => |tc| tc.tokensEst orelse (((tc.arg.len + 3) / 4) + 8),
            .tool_result => |tr| tr.tokensEst orelse (((tr.content.len + 3) / 4) + 8),
            .branch_summary => |b| (b.summary.len + 3) / 4,
            .summary => |s| (s.summary.len + 3) / 4,
            else => 0,
        };
    }

    fn latestModelMeta(entries: []const session.Entry) struct { provider: ?[]const u8, model: ?[]const u8 } {
        var provider: ?[]const u8 = null;
        var model: ?[]const u8 = null;

        for (entries) |e| {
            switch (e) {
                .model_change => |m| {
                    provider = m.provider;
                    model = m.modelId;
                },
                .message => |m| {
                    if (!std.mem.eql(u8, m.role, "assistant")) continue;
                    if (m.provider) |p| provider = p;
                    if (m.model) |mid| model = mid;
                },
                else => {},
            }
        }

        return .{ .provider = provider, .model = model };
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
                    .custom_message => |cm| break :blk cm.id,
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
                var usage_total_tokens: usize = tokens_est;
                for (entries) |e| {
                    usage_total_tokens += tokensEstForContextEntry(e);
                }
                const model_meta = latestModelMeta(entries);
                _ = try self.session_mgr.appendMessageWithMetaAndModel(
                    "assistant",
                    t,
                    tokens_est,
                    usage_total_tokens,
                    model_meta.provider,
                    model_meta.model,
                );
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

test "agent loop propagates model-change metadata into assistant turns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realpathAlloc(allocator, ".");
    const session_path = try std.fs.path.join(allocator, &.{ tmp_root, "agent-model.jsonl" });
    var sm = session.SessionManager.init(allocator, session_path, ".");
    try sm.ensure();

    _ = try sm.appendMessage("user", "plan tasks");
    _ = try sm.appendModelChange("openai", "gpt-4.1");

    var bus = events.EventBus.init(allocator);
    var tools_reg = tools.ToolRegistry.init(allocator);
    var loop = AgentLoop.init(allocator, &sm, &tools_reg, &bus);

    const done = try loop.step();
    try std.testing.expect(done);

    const entries = try sm.loadEntries();
    var provider: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    for (entries) |e| {
        if (e == .message) {
            const m = e.message;
            if (std.mem.eql(u8, m.role, "assistant")) {
                provider = m.provider;
                model = m.model;
            }
        }
    }

    try std.testing.expect(provider != null);
    try std.testing.expect(model != null);
    try std.testing.expectEqualStrings("openai", provider.?);
    try std.testing.expectEqualStrings("gpt-4.1", model.?);
}

test "agent loop falls back to latest assistant metadata when no model-change entry exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realpathAlloc(allocator, ".");
    const session_path = try std.fs.path.join(allocator, &.{ tmp_root, "agent-assistant-meta.jsonl" });
    var sm = session.SessionManager.init(allocator, session_path, ".");
    try sm.ensure();

    _ = try sm.appendMessageWithMeta("assistant", "prefill", null, null);
    // attach model metadata to latest assistant context to validate fallback behavior
    const raw = try sm.appendMessageWithMetaAndModel("assistant", "prefill", null, null, "local", "mini");
    _ = raw;
    _ = try sm.appendMessage("user", "next task");

    var bus = events.EventBus.init(allocator);
    var tools_reg = tools.ToolRegistry.init(allocator);
    var loop = AgentLoop.init(allocator, &sm, &tools_reg, &bus);

    const done = try loop.step();
    try std.testing.expect(done);

    const entries = try sm.loadEntries();
    var provider: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    for (entries) |e| {
        if (e == .message) {
            const m = e.message;
            if (std.mem.eql(u8, m.role, "assistant")) {
                provider = m.provider;
                model = m.model;
            }
        }
    }

    try std.testing.expect(provider != null);
    try std.testing.expect(model != null);
    try std.testing.expectEqualStrings("local", provider.?);
    try std.testing.expectEqualStrings("mini", model.?);
}
