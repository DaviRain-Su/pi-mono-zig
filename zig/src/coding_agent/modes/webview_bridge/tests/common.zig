pub const std = @import("std");
pub const ai = @import("ai");
pub const agent = @import("agent");
pub const bridge_mod = @import("../../webview_bridge.zig");
pub const json_format = @import("../../../shared/json_format.zig");
pub const common = @import("../../../tools/common.zig");
pub const config_mod = @import("../../../config/config.zig");
pub const provider_config = @import("../../../providers/provider_config.zig");
pub const resources_mod = @import("../../../resources/resources.zig");
pub const session_mod = @import("../../../sessions/session.zig");
pub const session_manager_mod = @import("../../../sessions/session_manager.zig");

pub const BridgeHost = bridge_mod.BridgeHost;
pub const Command = bridge_mod.Command;
pub const DispatchCounters = bridge_mod.DispatchCounters;
pub const Permission = bridge_mod.Permission;
pub const WebViewExtensionCommand = bridge_mod.WebViewExtensionCommand;
pub const authorizeNavigation = bridge_mod.authorizeNavigation;
pub const command_table = bridge_mod.command_table;
pub const isTrustedBridgeOrigin = bridge_mod.isTrustedBridgeOrigin;
pub const resolveAssetRequest = bridge_mod.resolveAssetRequest;
pub const trusted_bundle_origin = bridge_mod.trusted_bundle_origin;
pub const writeJsonString = json_format.writeJsonString;
pub const bridge_testing = bridge_mod.testing;
pub const PromptEventCapture = bridge_testing.PromptEventCaptureType;

pub fn testModel() ai.Model {
    return .{
        .id = "faux-model",
        .name = "Faux Model",
        .provider = "faux",
        .api = "faux",
        .base_url = "https://faux.invalid",
        .input_types = &.{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
    };
}

pub fn testSession(allocator: std.mem.Allocator) !session_mod.AgentSession {
    return try testSessionWithModel(allocator, testModel());
}

pub fn testSessionWithModel(allocator: std.mem.Allocator, model: ai.Model) !session_mod.AgentSession {
    return try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/pi-webview-assets",
        .model = model,
    });
}

pub fn testPersistentSessionWithModel(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    model: ai.Model,
) !session_mod.AgentSession {
    return try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/pi-webview-assets",
        .model = model,
        .session_dir = session_dir,
    });
}

pub fn testBridge(session: *session_mod.AgentSession) BridgeHost {
    const model = ai.Model{
        .id = "faux-model",
        .name = "Faux Model",
        .provider = "faux",
        .api = "faux",
        .base_url = "https://faux.invalid",
        .input_types = &.{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
    };
    return BridgeHost.init(.{
        .cwd = "/tmp/pi-webview-assets",
        .trusted_asset_root = "/tmp/pi-webview-assets",
        .provider = "faux",
        .model = model,
        .no_session = true,
        .api_key_present = false,
        .auth_status = .local,
        .selected_tools = .{ .disable_all = true },
        .active_tool_count = 0,
        .session = session,
    });
}

pub fn makeBridgeTestTextMessage(allocator: std.mem.Allocator, role: []const u8, text: []const u8, timestamp: i64, model: ai.Model) !agent.AgentMessage {
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    if (std.mem.eql(u8, role, "user")) {
        return .{ .user = .{
            .role = try allocator.dupe(u8, "user"),
            .content = blocks,
            .timestamp = timestamp,
        } };
    }
    return .{ .assistant = .{
        .role = try allocator.dupe(u8, "assistant"),
        .content = blocks,
        .tool_calls = null,
        .api = try allocator.dupe(u8, model.api),
        .provider = try allocator.dupe(u8, model.provider),
        .model = try allocator.dupe(u8, model.id),
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = timestamp,
    } };
}

pub fn extractResultStringField(allocator: std.mem.Allocator, response: []const u8, field_name: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.MissingResult;
    const field = result.object.get(field_name) orelse return error.MissingResultField;
    if (field != .string) return error.InvalidResultField;
    return try allocator.dupe(u8, field.string);
}

pub fn responseResultBool(response: []const u8, field_name: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.MissingResult;
    const field = result.object.get(field_name) orelse return error.MissingResultField;
    if (field != .bool) return error.InvalidResultField;
    return field.bool;
}

pub fn waitForTerminalEvents(
    allocator: std.mem.Allocator,
    bridge: *BridgeHost,
    turn_id: []const u8,
) ![]u8 {
    var request: std.Io.Writer.Allocating = .init(allocator);
    defer request.deinit();
    try request.writer.writeAll("{\"id\":\"events\",\"command\":\"get_events\",\"payload\":{\"turnId\":");
    try writeJsonString(allocator, &request.writer, turn_id);
    try request.writer.writeAll(",\"afterSequence\":0}}");

    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) {
        const response = try bridge.handleRequestJson(allocator, request.written(), trusted_bundle_origin);
        if (try responseResultBool(response, "terminal")) return response;
        allocator.free(response);
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    return error.TestTimeout;
}

pub fn countDirectoryEntries(path: []const u8) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, path, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| {
        count += 1;
    }
    return count;
}
