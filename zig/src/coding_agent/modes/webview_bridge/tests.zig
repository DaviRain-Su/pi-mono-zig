const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const bridge_mod = @import("../webview_bridge.zig");
const json_format = @import("../../shared/json_format.zig");
const common = @import("../../tools/common.zig");
const config_mod = @import("../../config/config.zig");
const provider_config = @import("../../providers/provider_config.zig");
const resources_mod = @import("../../resources/resources.zig");
const session_mod = @import("../../sessions/session.zig");
const session_manager_mod = @import("../../sessions/session_manager.zig");

const BridgeHost = bridge_mod.BridgeHost;
const Command = bridge_mod.Command;
const DispatchCounters = bridge_mod.DispatchCounters;
const Permission = bridge_mod.Permission;
const WebViewExtensionCommand = bridge_mod.WebViewExtensionCommand;
const authorizeNavigation = bridge_mod.authorizeNavigation;
const command_table = bridge_mod.command_table;
const isTrustedBridgeOrigin = bridge_mod.isTrustedBridgeOrigin;
const resolveAssetRequest = bridge_mod.resolveAssetRequest;
const trusted_bundle_origin = bridge_mod.trusted_bundle_origin;
const writeJsonString = json_format.writeJsonString;
const bridge_testing = bridge_mod.testing;
const PromptEventCapture = bridge_testing.PromptEventCaptureType;

fn testModel() ai.Model {
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

fn testSession(allocator: std.mem.Allocator) !session_mod.AgentSession {
    return try testSessionWithModel(allocator, testModel());
}

fn testSessionWithModel(allocator: std.mem.Allocator, model: ai.Model) !session_mod.AgentSession {
    return try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/pi-webview-assets",
        .model = model,
    });
}

fn testPersistentSessionWithModel(
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

fn testBridge(session: *session_mod.AgentSession) BridgeHost {
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

fn makeBridgeTestTextMessage(allocator: std.mem.Allocator, role: []const u8, text: []const u8, timestamp: i64, model: ai.Model) !agent.AgentMessage {
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

fn extractResultStringField(allocator: std.mem.Allocator, response: []const u8, field_name: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.MissingResult;
    const field = result.object.get(field_name) orelse return error.MissingResultField;
    if (field != .string) return error.InvalidResultField;
    return try allocator.dupe(u8, field.string);
}

fn responseResultBool(response: []const u8, field_name: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.MissingResult;
    const field = result.object.get(field_name) orelse return error.MissingResultField;
    if (field != .bool) return error.InvalidResultField;
    return field.bool;
}

fn waitForTerminalEvents(
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

test "bridge command table exposes approved skeleton commands first" {
    try std.testing.expect(command_table.len >= 4);
    try std.testing.expectEqualStrings("get_state", command_table[0].name);
    try std.testing.expectEqualStrings("get_messages", command_table[1].name);
    try std.testing.expectEqualStrings("prompt", command_table[2].name);
    try std.testing.expectEqualStrings("abort", command_table[3].name);
    try std.testing.expectEqualStrings("get_events", command_table[4].name);
}

test "bridge command table explicitly gates future session mutation commands" {
    try std.testing.expectEqual(@as(usize, 34), command_table.len);
    try std.testing.expectEqualStrings("new_session", command_table[6].name);
    try std.testing.expectEqual(Command.new_session, command_table[6].command);
    try std.testing.expectEqual(Permission.session_mutation, command_table[6].permission);
    try std.testing.expectEqualStrings("resume_session", command_table[7].name);
    try std.testing.expectEqual(Command.resume_session, command_table[7].command);
    try std.testing.expectEqual(Permission.session_mutation, command_table[7].permission);
    try std.testing.expectEqualStrings("switch_session", command_table[8].name);
    try std.testing.expectEqual(Command.switch_session, command_table[8].command);
    try std.testing.expectEqual(Permission.session_mutation, command_table[8].permission);
}

test "bridge command table explicitly gates future model selection command" {
    try std.testing.expectEqualStrings("model_select", command_table[5].name);
    try std.testing.expectEqual(Command.model_select, command_table[5].command);
    try std.testing.expectEqual(Permission.model_selection, command_table[5].permission);
}

test "bridge command table exposes auth status and gates auth mutations" {
    try std.testing.expectEqualStrings("auth_status", command_table[9].name);
    try std.testing.expectEqual(Command.auth_status, command_table[9].command);
    try std.testing.expectEqual(Permission.skeleton_chat, command_table[9].permission);
    try std.testing.expectEqualStrings("start_auth", command_table[10].name);
    try std.testing.expectEqual(Command.start_auth, command_table[10].command);
    try std.testing.expectEqual(Permission.auth_mutation, command_table[10].permission);
    try std.testing.expectEqualStrings("save_api_key", command_table[11].name);
    try std.testing.expectEqual(Command.save_api_key, command_table[11].command);
    try std.testing.expectEqual(Permission.auth_mutation, command_table[11].permission);
    try std.testing.expectEqualStrings("remove_auth", command_table[12].name);
    try std.testing.expectEqual(Command.remove_auth, command_table[12].command);
    try std.testing.expectEqual(Permission.auth_mutation, command_table[12].permission);
}

test "bridge command table exposes settings theme thinking and scoped model commands" {
    try std.testing.expectEqual(@as(usize, 34), command_table.len);
    try std.testing.expectEqualStrings("settings_get", command_table[13].name);
    try std.testing.expectEqual(Command.settings_get, command_table[13].command);
    try std.testing.expectEqual(Permission.skeleton_chat, command_table[13].permission);
    try std.testing.expectEqualStrings("settings_set", command_table[14].name);
    try std.testing.expectEqual(Permission.settings_mutation, command_table[14].permission);
    try std.testing.expectEqualStrings("thinking_set", command_table[15].name);
    try std.testing.expectEqual(Permission.settings_mutation, command_table[15].permission);
    try std.testing.expectEqualStrings("theme_select", command_table[16].name);
    try std.testing.expectEqual(Permission.settings_mutation, command_table[16].permission);
    try std.testing.expectEqualStrings("scoped_models_get", command_table[17].name);
    try std.testing.expectEqual(Permission.skeleton_chat, command_table[17].permission);
    try std.testing.expectEqualStrings("scoped_models_update", command_table[18].name);
    try std.testing.expectEqual(Permission.settings_mutation, command_table[18].permission);
    try std.testing.expectEqualStrings("scoped_models_save", command_table[19].name);
    try std.testing.expectEqual(Permission.settings_mutation, command_table[19].permission);
}

test "bridge command table exposes session tree label navigation and fork commands" {
    try std.testing.expectEqual(@as(usize, 34), command_table.len);
    try std.testing.expectEqualStrings("session_tree_get", command_table[20].name);
    try std.testing.expectEqual(Command.session_tree_get, command_table[20].command);
    try std.testing.expectEqual(Permission.skeleton_chat, command_table[20].permission);
    try std.testing.expectEqualStrings("session_tree_label", command_table[21].name);
    try std.testing.expectEqual(Permission.session_mutation, command_table[21].permission);
    try std.testing.expectEqualStrings("session_tree_navigate", command_table[22].name);
    try std.testing.expectEqual(Permission.session_mutation, command_table[22].permission);
    try std.testing.expectEqualStrings("fork_messages_get", command_table[23].name);
    try std.testing.expectEqual(Permission.skeleton_chat, command_table[23].permission);
    try std.testing.expectEqualStrings("fork_session", command_table[24].name);
    try std.testing.expectEqual(Permission.session_mutation, command_table[24].permission);
}

test "bridge command table exposes command and utility surfaces with explicit permissions" {
    try std.testing.expectEqual(@as(usize, 34), command_table.len);
    try std.testing.expectEqualStrings("command_catalog", command_table[25].name);
    try std.testing.expectEqual(Permission.skeleton_chat, command_table[25].permission);
    try std.testing.expectEqualStrings("copy_session", command_table[26].name);
    try std.testing.expectEqual(Permission.utility_command, command_table[26].permission);
    try std.testing.expectEqualStrings("export_session", command_table[27].name);
    try std.testing.expectEqual(Permission.utility_command, command_table[27].permission);
    try std.testing.expectEqualStrings("import_session", command_table[28].name);
    try std.testing.expectEqual(Permission.session_mutation, command_table[28].permission);
    try std.testing.expectEqualStrings("share_session", command_table[29].name);
    try std.testing.expectEqual(Permission.utility_command, command_table[29].permission);
    try std.testing.expectEqualStrings("bash_execute", command_table[30].name);
    try std.testing.expectEqual(Permission.utility_command, command_table[30].permission);
    try std.testing.expectEqualStrings("prompt_template_dispatch", command_table[31].name);
    try std.testing.expectEqual(Permission.resource_command, command_table[31].permission);
    try std.testing.expectEqualStrings("skill_dispatch", command_table[32].name);
    try std.testing.expectEqual(Permission.resource_command, command_table[32].permission);
    try std.testing.expectEqualStrings("extension_command_dispatch", command_table[33].name);
    try std.testing.expectEqual(Permission.extension_command, command_table[33].permission);
}

test "webview command catalog discovers builtins hidden decisions resources and extensions" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    const prompts = [_]resources_mod.PromptTemplate{.{
        .name = @constCast("review"),
        .description = @constCast("Review code"),
        .argument_hint = @constCast("<scope>"),
        .content = @constCast("Review $@"),
        .file_path = @constCast("/tmp/review.md"),
        .source_info = .{
            .path = @constCast("/tmp/review.md"),
            .source = @constCast("test"),
            .scope = .temporary,
            .origin = .top_level,
        },
    }};
    const skills = [_]resources_mod.Skill{.{
        .name = @constCast("auditor"),
        .description = @constCast("Audit safely"),
        .file_path = @constCast("/tmp/skills/auditor/SKILL.md"),
        .base_dir = @constCast("/tmp/skills/auditor"),
        .source_info = .{
            .path = @constCast("/tmp/skills/auditor/SKILL.md"),
            .source = @constCast("test"),
            .scope = .temporary,
            .origin = .top_level,
        },
    }};
    const extension_commands = [_]WebViewExtensionCommand{.{
        .name = "say",
        .invocation_name = "say",
        .description = "Say from extension",
        .extension_path = "/tmp/ext.ts",
    }};
    bridge.context.prompt_templates = prompts[0..];
    bridge.context.skills = skills[0..];
    bridge.context.extension_commands = extension_commands[0..];

    const response = try bridge.handleRequestJson(allocator, "{\"id\":\"catalog\",\"command\":\"command_catalog\"}", trusted_bundle_origin);
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"builtins\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"help\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"hiddenDecisions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"label\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"bridgeCommand\":\"copy_session\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"prefix\":\"!!\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"command\":\"/review\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"command\":\"/skill:auditor\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"invocationName\":\"say\"") != null);
}

test "webview copy export share and bash utility commands are permissioned and statusful" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sessions");
    try tmp.dir.createDirPath(std.testing.io, "exports");
    const session_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "sessions", allocator);
    defer allocator.free(session_dir);
    const export_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "exports", allocator);
    defer allocator.free(export_dir);

    var session = try testPersistentSessionWithModel(allocator, session_dir, testModel());
    defer session.deinit();
    var user = try makeBridgeTestTextMessage(allocator, "user", "hello", 1, testModel());
    defer session_manager_mod.deinitMessage(allocator, &user);
    var assistant = try makeBridgeTestTextMessage(allocator, "assistant", "world", 2, testModel());
    defer session_manager_mod.deinitMessage(allocator, &assistant);
    _ = try session.session_manager.appendMessage(user);
    _ = try session.session_manager.appendMessage(assistant);
    try session.agent.setMessages(&.{ user, assistant });

    var bridge = testBridge(&session);
    bridge.context.no_session = false;
    const denied = try bridge.handleRequestJson(allocator, "{\"id\":\"copy-denied\",\"command\":\"copy_session\",\"payload\":{\"scope\":\"last\"}}", trusted_bundle_origin);
    defer allocator.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "\"code\":\"permission_denied\"") != null);

    bridge.context.permissions.utility_command = true;
    const copied = try bridge.handleRequestJson(allocator, "{\"id\":\"copy\",\"command\":\"copy_session\",\"payload\":{\"scope\":\"last\"}}", trusted_bundle_origin);
    defer allocator.free(copied);
    try std.testing.expect(std.mem.indexOf(u8, copied, "\"status\":\"prepared\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, copied, "\"text\":\"world\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, copied, "\"tempPath\":null") != null);

    inline for (.{ "html", "jsonl", "json", "md" }) |format| {
        const path = try std.fmt.allocPrint(allocator, "{s}/session.{s}", .{ export_dir, format });
        defer allocator.free(path);
        var request: std.Io.Writer.Allocating = .init(allocator);
        defer request.deinit();
        try request.writer.writeAll("{\"id\":\"export\",\"command\":\"export_session\",\"payload\":{\"format\":");
        try writeJsonString(allocator, &request.writer, format);
        try request.writer.writeAll(",\"path\":");
        try writeJsonString(allocator, &request.writer, path);
        try request.writer.writeAll("}}");
        const exported = try bridge.handleRequestJson(allocator, request.written(), trusted_bundle_origin);
        defer allocator.free(exported);
        try std.testing.expect(std.mem.indexOf(u8, exported, "\"status\":\"exported\"") != null);
        const stat = try std.Io.Dir.statFile(.cwd(), std.testing.io, path, .{});
        try std.testing.expect(stat.size > 0);
    }

    bridge.context.permissions.session_mutation = true;
    const import_path = try std.fmt.allocPrint(allocator, "{s}/session.jsonl", .{export_dir});
    defer allocator.free(import_path);
    var import_request: std.Io.Writer.Allocating = .init(allocator);
    defer import_request.deinit();
    try import_request.writer.writeAll("{\"id\":\"import\",\"command\":\"import_session\",\"payload\":{\"path\":");
    try writeJsonString(allocator, &import_request.writer, import_path);
    try import_request.writer.writeAll("}}");
    const imported = try bridge.handleRequestJson(allocator, import_request.written(), trusted_bundle_origin);
    defer allocator.free(imported);
    try std.testing.expect(std.mem.indexOf(u8, imported, "\"status\":\"imported\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, imported, "\"messages\"") != null);

    const shared = try bridge.handleRequestJson(allocator, "{\"id\":\"share\",\"command\":\"share_session\"}", trusted_bundle_origin);
    defer allocator.free(shared);
    try std.testing.expect(std.mem.indexOf(u8, shared, "\"status\":\"prepared\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, shared, "\"secretEcho\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, shared, "Session ") != null);

    const bash = try bridge.handleRequestJson(allocator, "{\"id\":\"bash\",\"command\":\"bash_execute\",\"payload\":{\"command\":\"printf webview-bash\",\"excludeFromContext\":true}}", trusted_bundle_origin);
    defer allocator.free(bash);
    try std.testing.expect(std.mem.indexOf(u8, bash, "\"status\":\"completed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "webview-bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "\"excludeFromContext\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "\"fullOutputPathExposed\":false") != null);
}

test "webview prompt templates skills and extension commands dispatch through explicit permissions" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "skills/auditor");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "skills/auditor/SKILL.md", .data = "---\ndescription: Audit\n---\nUse safe audit steps." });
    const skill_path = try tmp.dir.realPathFileAlloc(std.testing.io, "skills/auditor/SKILL.md", allocator);
    defer allocator.free(skill_path);
    const skill_base = try tmp.dir.realPathFileAlloc(std.testing.io, "skills/auditor", allocator);
    defer allocator.free(skill_base);

    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    const prompts = [_]resources_mod.PromptTemplate{.{
        .name = @constCast("review"),
        .description = @constCast("Review code"),
        .argument_hint = @constCast("<scope>"),
        .content = @constCast("Review $@ now"),
        .file_path = @constCast("/tmp/review.md"),
        .source_info = .{
            .path = @constCast("/tmp/review.md"),
            .source = @constCast("test"),
            .scope = .temporary,
            .origin = .top_level,
        },
    }};
    const skills = [_]resources_mod.Skill{.{
        .name = @constCast("auditor"),
        .description = @constCast("Audit safely"),
        .file_path = skill_path,
        .base_dir = skill_base,
        .source_info = .{
            .path = skill_path,
            .source = @constCast("test"),
            .scope = .temporary,
            .origin = .top_level,
        },
    }};
    const extension_commands = [_]WebViewExtensionCommand{.{
        .name = "say",
        .invocation_name = "say",
        .description = "Say from extension",
        .extension_path = "/tmp/ext.ts",
    }};
    bridge.context.prompt_templates = prompts[0..];
    bridge.context.skills = skills[0..];
    bridge.context.extension_commands = extension_commands[0..];

    const denied = try bridge.handleRequestJson(allocator, "{\"id\":\"prompt-denied\",\"command\":\"prompt_template_dispatch\",\"payload\":{\"name\":\"review\",\"args\":\"src\"}}", trusted_bundle_origin);
    defer allocator.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "\"code\":\"permission_denied\"") != null);

    bridge.context.permissions.resource_command = true;
    bridge.context.permissions.extension_command = true;
    const prompt = try bridge.handleRequestJson(allocator, "{\"id\":\"prompt\",\"command\":\"prompt_template_dispatch\",\"payload\":{\"name\":\"review\",\"args\":\"src\"}}", trusted_bundle_origin);
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"status\":\"expanded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Review src now") != null);

    const skill = try bridge.handleRequestJson(allocator, "{\"id\":\"skill\",\"command\":\"skill_dispatch\",\"payload\":{\"name\":\"auditor\",\"args\":\"focus\"}}", trusted_bundle_origin);
    defer allocator.free(skill);
    try std.testing.expect(std.mem.indexOf(u8, skill, "\"status\":\"expanded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, skill, "Use safe audit steps.") != null);
    try std.testing.expect(std.mem.indexOf(u8, skill, "focus") != null);

    const ext = try bridge.handleRequestJson(allocator, "{\"id\":\"ext\",\"command\":\"extension_command_dispatch\",\"payload\":{\"name\":\"say\",\"args\":\"hello\"}}", trusted_bundle_origin);
    defer allocator.free(ext);
    try std.testing.expect(std.mem.indexOf(u8, ext, "\"status\":\"dispatched\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ext, "\"permission\":\"extension_command\"") != null);
    var saw_extension_entry = false;
    for (session.session_manager.getEntries()) |entry| {
        if (entry == .custom_message and std.mem.eql(u8, entry.custom_message.custom_type, "extensionCommand")) saw_extension_entry = true;
    }
    try std.testing.expect(saw_extension_entry);
}

test "bridge dispatches every approved skeleton command through command table" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    defer bridge.deinit();
    var counters = DispatchCounters{};
    bridge.dispatch_counters = &counters;

    const state = try bridge.handleRequestJson(allocator, "{\"id\":\"state\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(state);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"id\":\"state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"ok\":true") != null);

    const messages = try bridge.handleRequestJson(allocator, "{\"id\":\"messages\",\"command\":\"get_messages\"}", trusted_bundle_origin);
    defer allocator.free(messages);
    try std.testing.expect(std.mem.indexOf(u8, messages, "\"id\":\"messages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "\"messages\"") != null);

    const prompt = try bridge.handleRequestJson(allocator, "{\"id\":\"prompt\",\"command\":\"prompt\",\"payload\":{\"text\":\"hello\"}}", trusted_bundle_origin);
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"id\":\"prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"status\":\"accepted\"") != null);
    const turn_id = try extractResultStringField(allocator, prompt, "turnId");
    defer allocator.free(turn_id);

    var events_request: std.Io.Writer.Allocating = .init(allocator);
    defer events_request.deinit();
    try events_request.writer.writeAll("{\"id\":\"events\",\"command\":\"get_events\",\"payload\":{\"turnId\":");
    try writeJsonString(allocator, &events_request.writer, turn_id);
    try events_request.writer.writeAll(",\"afterSequence\":0}}");
    const events = try bridge.handleRequestJson(allocator, events_request.written(), trusted_bundle_origin);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"id\":\"events\"") != null);

    const terminal = try waitForTerminalEvents(allocator, &bridge, turn_id);
    defer allocator.free(terminal);

    const abort = try bridge.handleRequestJson(allocator, "{\"id\":\"abort\",\"command\":\"abort\"}", trusted_bundle_origin);
    defer allocator.free(abort);
    try std.testing.expect(std.mem.indexOf(u8, abort, "\"id\":\"abort\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, abort, "\"status\":\"not_running\"") != null);

    try std.testing.expectEqual(@as(usize, 1), counters.get_state);
    try std.testing.expectEqual(@as(usize, 1), counters.get_messages);
    try std.testing.expectEqual(@as(usize, 1), counters.prompt);
    try std.testing.expectEqual(@as(usize, 1), counters.abort);
    try std.testing.expect(counters.get_events >= 2);
}

test "webview prompt runs through AgentSession and returns ordered correlated events" {
    const allocator = std.testing.allocator;
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();
    const blocks = [_]faux.FauxContentBlock{faux.fauxText("webview answer")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks[0..], .{}) },
    });

    var session = try testSessionWithModel(allocator, registration.getModel());
    defer session.deinit();
    var bridge = testBridge(&session);
    defer bridge.deinit();
    bridge.context.model = registration.getModel();

    const before = try bridge.handleRequestJson(allocator, "{\"id\":\"before\",\"command\":\"get_messages\"}", trusted_bundle_origin);
    defer allocator.free(before);
    try std.testing.expect(std.mem.indexOf(u8, before, "\"messages\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, before, "\"messages\":[]") != null);

    const prompt = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"prompt\",\"command\":\"prompt\",\"payload\":{\"text\":\"hello from webview\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"id\":\"prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"status\":\"accepted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"turnId\":\"webview-turn-0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"events\":[]") != null);
    const turn_id = try extractResultStringField(allocator, prompt, "turnId");
    defer allocator.free(turn_id);
    const events = try waitForTerminalEvents(allocator, &bridge, turn_id);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"sequence\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"terminal\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"terminalOutcome\":\"success\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "webview answer") != null);

    const after = try bridge.handleRequestJson(allocator, "{\"id\":\"after\",\"command\":\"get_messages\"}", trusted_bundle_origin);
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "hello from webview") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "webview answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "webview-turn-0") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"sequence\"") == null);
}

test "webview message summaries preserve structured assistant content separately" {
    const allocator = std.testing.allocator;
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    var arguments = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try common.putString(allocator, &arguments, "command", "printf structured");
    const arguments_value = std.json.Value{ .object = arguments };
    defer ai.provider_json.freeValue(allocator, arguments_value);

    const tool_call = try faux.fauxToolCall(allocator, "bash", arguments_value, .{ .id = "tool-structured" });
    defer switch (tool_call) {
        .tool_call => |value| {
            allocator.free(value.id);
            allocator.free(value.name);
            ai.provider_json.freeValue(allocator, value.arguments);
        },
        else => unreachable,
    };
    const blocks = [_]faux.FauxContentBlock{
        faux.fauxThinking("internal hidden reasoning"),
        faux.fauxText("visible structured answer"),
        tool_call,
    };
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks[0..], .{ .stop_reason = .tool_use }) },
    });

    var session = try testSessionWithModel(allocator, registration.getModel());
    defer session.deinit();
    var bridge = testBridge(&session);
    defer bridge.deinit();
    bridge.context.model = registration.getModel();

    const prompt = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"prompt\",\"command\":\"prompt\",\"payload\":{\"text\":\"structured\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(prompt);
    const turn_id = try extractResultStringField(allocator, prompt, "turnId");
    defer allocator.free(turn_id);
    const events = try waitForTerminalEvents(allocator, &bridge, turn_id);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"type\":\"thinking_delta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"type\":\"text_delta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"type\":\"toolcall_delta\"") != null);

    const messages = try bridge.handleRequestJson(allocator, "{\"id\":\"messages\",\"command\":\"get_messages\"}", trusted_bundle_origin);
    defer allocator.free(messages);
    try std.testing.expect(std.mem.indexOf(u8, messages, "\"text\":\"visible structured answer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "\"thinking\":\"internal hidden reasoning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "\"type\":\"toolCall\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "\"text\":\"internal hidden reasoning\"") == null);
}

test "webview prompt accepts asynchronously and polls ordered incremental events" {
    const allocator = std.testing.allocator;
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(allocator, .{
        .tokens_per_second = 20,
        .token_size = .{ .min = 1, .max = 1 },
    });
    defer registration.unregister();
    const blocks = [_]faux.FauxContentBlock{faux.fauxText("async webview streaming answer")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks[0..], .{}) },
    });

    var session = try testSessionWithModel(allocator, registration.getModel());
    defer session.deinit();
    var bridge = testBridge(&session);
    defer bridge.deinit();
    bridge.context.model = registration.getModel();

    const before_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    const prompt = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"async-prompt\",\"command\":\"prompt\",\"payload\":{\"text\":\"stream async\"}}",
        trusted_bundle_origin,
    );
    const after_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"status\":\"accepted\"") != null);
    try std.testing.expect(after_ns - before_ns < 100 * std.time.ns_per_ms);
    try std.testing.expect(bridge.active_generation.load(.seq_cst));
    const turn_id = try extractResultStringField(allocator, prompt, "turnId");
    defer allocator.free(turn_id);

    const state = try bridge.handleRequestJson(allocator, "{\"id\":\"state-active\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(state);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"busy\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"activeTurnId\"") != null);

    const terminal = try waitForTerminalEvents(allocator, &bridge, turn_id);
    defer allocator.free(terminal);
    try std.testing.expect(std.mem.indexOf(u8, terminal, "\"terminalOutcome\":\"success\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal, "\"sequence\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal, "\"sequence\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal, "async webview streaming answer") != null);

    var after_request: std.Io.Writer.Allocating = .init(allocator);
    defer after_request.deinit();
    try after_request.writer.writeAll("{\"id\":\"events-after-one\",\"command\":\"get_events\",\"payload\":{\"turnId\":");
    try writeJsonString(allocator, &after_request.writer, turn_id);
    try after_request.writer.writeAll(",\"afterSequence\":1}}");
    const after_events = try bridge.handleRequestJson(allocator, after_request.written(), trusted_bundle_origin);
    defer allocator.free(after_events);
    try std.testing.expect(std.mem.indexOf(u8, after_events, "\"sequence\":1,") == null);
    try std.testing.expect(std.mem.indexOf(u8, after_events, "\"terminal\":true") != null);
}

test "webview get_state mirrors existing session without mutating persisted state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sessions");
    const session_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "sessions", allocator);
    defer allocator.free(session_dir);

    var session = try testPersistentSessionWithModel(allocator, session_dir, testModel());
    defer session.deinit();
    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);
    const session_id = try allocator.dupe(u8, session.session_manager.getSessionId());
    defer allocator.free(session_id);

    var bridge = testBridge(&session);
    defer bridge.deinit();
    bridge.context.no_session = false;
    const before = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(before);

    const first = try bridge.handleRequestJson(allocator, "{\"id\":\"state-1\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(first);
    const second = try bridge.handleRequestJson(allocator, "{\"id\":\"state-2\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(second);

    const after = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"sessionId\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, session_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"noSession\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, session_id) != null);
    try std.testing.expectEqualSlices(u8, before, after);
}

test "webview get_state exposes resolver model metadata without secrets" {
    const allocator = std.testing.allocator;
    var secret_model = testModel();
    secret_model.id = "sentinel-model";
    secret_model.name = "Sentinel Display";
    secret_model.api = "openai-responses";
    secret_model.provider = "sentinel-provider";
    secret_model.base_url = "https://example.invalid/sk-webview-secret";

    var session = try testSessionWithModel(allocator, secret_model);
    defer session.deinit();
    var bridge = testBridge(&session);
    bridge.context.provider = "sentinel-provider";
    bridge.context.model = secret_model;
    bridge.context.api_key_present = true;

    const response = try bridge.handleRequestJson(allocator, "{\"id\":\"state-model\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"provider\":\"sentinel-provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"model\":\"sentinel-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"modelProvider\":\"sentinel-provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"modelName\":\"Sentinel Display\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"modelApi\":\"openai-responses\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"apiKeyPresent\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "sk-webview-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "base_url") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "baseUrl") == null);
}

test "webview get_state exposes configured model choices without credential values" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    const available_models = [_]provider_config.AvailableModel{
        .{
            .provider = "faux",
            .model_id = "faux-model",
            .display_name = "Faux Model",
            .available = true,
            .auth_status = .local,
            .reasoning = false,
            .tool_calling = true,
            .loaded = false,
            .supports_images = false,
            .context_window = 128000,
            .max_tokens = 4096,
        },
        .{
            .provider = "openai",
            .model_id = "gpt-5.4",
            .display_name = "GPT-5.4",
            .available = true,
            .auth_status = .stored,
            .reasoning = true,
            .tool_calling = true,
            .loaded = false,
            .supports_images = true,
            .context_window = 272000,
            .max_tokens = 128000,
        },
    };
    bridge.context.available_models = available_models[0..];

    const response = try bridge.handleRequestJson(allocator, "{\"id\":\"state-models\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"modelSelection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"availableModels\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"provider\":\"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"model\":\"gpt-5.4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"authStatus\":\"stored\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"current\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "sk-webview-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "authorization") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "baseUrl") == null);
}

test "webview get_state exposes structured settings thinking theme and scoped model state" {
    const allocator = std.testing.allocator;
    var thinking_model = testModel();
    thinking_model.reasoning = true;
    thinking_model.input_types = &.{ "text", "image" };

    var session = try testSessionWithModel(allocator, thinking_model);
    defer session.deinit();
    var bridge = testBridge(&session);
    defer bridge.deinit();
    bridge.context.model = thinking_model;
    bridge.context.permissions.settings_mutation = true;
    const available_models = [_]provider_config.AvailableModel{
        .{
            .provider = "faux",
            .model_id = "faux-model",
            .display_name = "Faux Model",
            .available = true,
            .auth_status = .local,
            .reasoning = true,
            .tool_calling = true,
            .loaded = false,
            .supports_images = true,
            .context_window = 128000,
            .max_tokens = 4096,
        },
    };
    bridge.context.available_models = available_models[0..];

    const response = try bridge.handleRequestJson(allocator, "{\"id\":\"state-panels\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"settingsPanel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"label\":\"Auto-compact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"label\":\"Show images\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"label\":\"Theme\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"thinkingSelection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"xhigh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"available\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"themeSelection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"dark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"scopedModels\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"toggle\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"fullId\":\"faux/faux-model\"") != null);
}

test "webview settings mutations are permission gated and persist theme and rows" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    const agent_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "agent", allocator);
    defer allocator.free(agent_dir);
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "project", allocator);
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    var runtime = try config_mod.loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime.deinit();

    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    defer bridge.deinit();
    bridge.context.runtime_config = &runtime;

    const denied = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"settings-denied\",\"command\":\"settings_set\",\"payload\":{\"id\":\"hide_thinking\",\"value\":\"true\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "\"code\":\"permission_denied\"") != null);

    bridge.context.permissions.settings_mutation = true;
    const saved = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"settings-save\",\"command\":\"settings_set\",\"payload\":{\"id\":\"hide_thinking\",\"value\":\"true\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"status\":\"saved\"") != null);
    try std.testing.expect(runtime.hideThinkingBlock());

    const theme = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"theme-save\",\"command\":\"theme_select\",\"payload\":{\"theme\":\"light\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(theme);
    try std.testing.expect(std.mem.indexOf(u8, theme, "\"status\":\"selected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, theme, "\"theme\":\"light\"") != null);

    const settings_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, settings_path, allocator, .unlimited);
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"hideThinkingBlock\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"theme\": \"light\"") != null);
}

test "webview thinking levels respect model capability awareness" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    bridge.context.permissions.settings_mutation = true;

    const unsupported = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"thinking-high\",\"command\":\"thinking_set\",\"payload\":{\"level\":\"high\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(unsupported);
    try std.testing.expect(std.mem.indexOf(u8, unsupported, "\"status\":\"unsupported\"") != null);
    try std.testing.expectEqual(agent.ThinkingLevel.off, session.agent.getThinkingLevel());

    var thinking_model = testModel();
    thinking_model.reasoning = true;
    bridge.context.model = thinking_model;
    try session.setModel(thinking_model);
    const selected = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"thinking-high\",\"command\":\"thinking_set\",\"payload\":{\"level\":\"high\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(selected);
    try std.testing.expect(std.mem.indexOf(u8, selected, "\"status\":\"selected\"") != null);
    try std.testing.expectEqual(agent.ThinkingLevel.high, session.agent.getThinkingLevel());
}

test "webview scoped model controls toggle bulk provider reorder and save" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    const agent_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "agent", allocator);
    defer allocator.free(agent_dir);
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "project", allocator);
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    var runtime = try config_mod.loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime.deinit();

    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    defer bridge.deinit();
    bridge.context.runtime_config = &runtime;
    bridge.context.permissions.settings_mutation = true;
    const available_models = [_]provider_config.AvailableModel{
        .{ .provider = "faux", .model_id = "faux-model", .display_name = "Faux Model", .available = true, .auth_status = .local, .reasoning = false, .tool_calling = true, .loaded = false, .supports_images = false, .context_window = 128000, .max_tokens = 4096 },
        .{ .provider = "faux", .model_id = "faux-alt", .display_name = "Faux Alt", .available = true, .auth_status = .local, .reasoning = false, .tool_calling = true, .loaded = false, .supports_images = false, .context_window = 128000, .max_tokens = 4096 },
        .{ .provider = "local", .model_id = "local-one", .display_name = "Local One", .available = true, .auth_status = .local, .reasoning = true, .tool_calling = false, .loaded = true, .supports_images = false, .context_window = 8192, .max_tokens = 1024 },
    };
    bridge.context.available_models = available_models[0..];

    const toggled = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"scoped-toggle\",\"command\":\"scoped_models_update\",\"payload\":{\"action\":\"toggle\",\"fullId\":\"faux/faux-model\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(toggled);
    try std.testing.expect(std.mem.indexOf(u8, toggled, "\"dirty\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, toggled, "\"fullId\":\"faux/faux-model\",\"provider\":\"faux\"") != null);

    const provider_toggle = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"scoped-provider\",\"command\":\"scoped_models_update\",\"payload\":{\"action\":\"provider_toggle\",\"provider\":\"faux\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(provider_toggle);
    try std.testing.expect(std.mem.indexOf(u8, provider_toggle, "\"status\":\"updated\"") != null);

    const reorder = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"scoped-reorder\",\"command\":\"scoped_models_update\",\"payload\":{\"action\":\"reorder\",\"fullId\":\"local/local-one\",\"direction\":\"up\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(reorder);
    try std.testing.expect(std.mem.indexOf(u8, reorder, "\"status\":\"updated\"") != null);

    const enable = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"scoped-enable\",\"command\":\"scoped_models_update\",\"payload\":{\"action\":\"enable_all\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(enable);
    try std.testing.expect(std.mem.indexOf(u8, enable, "\"allEnabled\":true") != null);

    const clear = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"scoped-clear\",\"command\":\"scoped_models_update\",\"payload\":{\"action\":\"clear_all\",\"targets\":[\"faux/faux-model\"]}}",
        trusted_bundle_origin,
    );
    defer allocator.free(clear);
    try std.testing.expect(std.mem.indexOf(u8, clear, "\"allEnabled\":false") != null);

    const saved = try bridge.handleRequestJson(allocator, "{\"id\":\"scoped-save\",\"command\":\"scoped_models_save\"}", trusted_bundle_origin);
    defer allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"status\":\"saved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"dirty\":false") != null);

    const settings_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, settings_path, allocator, .unlimited);
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"enabledModels\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "local/local-one") != null);
}

test "webview auth status exposes minimal storage-derived state without secrets" {
    const allocator = std.testing.allocator;
    var secret_model = testModel();
    secret_model.provider = "openai";
    secret_model.id = "gpt-5.4";
    secret_model.name = "GPT-5.4";
    secret_model.api = "openai-responses";
    secret_model.base_url = "https://api.openai.com/v1/sk-webview-secret";

    var session = try testSessionWithModel(allocator, secret_model);
    defer session.deinit();
    var bridge = testBridge(&session);
    bridge.context.provider = "openai";
    bridge.context.model = secret_model;
    bridge.context.auth_status = .stored;
    bridge.context.api_key_present = true;

    const state = try bridge.handleRequestJson(allocator, "{\"id\":\"state-auth\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(state);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"auth\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"provider\":\"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"displayName\":\"OpenAI\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"status\":\"stored\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"statusLabel\":\"saved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"apiKeyPresent\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"required\":false") != null);

    const status = try bridge.handleRequestJson(allocator, "{\"id\":\"auth\",\"command\":\"auth_status\"}", trusted_bundle_origin);
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"id\":\"auth\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"status\":\"stored\"") != null);

    try std.testing.expect(std.mem.indexOf(u8, state, "sk-webview-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, status, "sk-webview-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, state, "auth.json") == null);
    try std.testing.expect(std.mem.indexOf(u8, status, "auth.json") == null);
    try std.testing.expect(std.mem.indexOf(u8, state, "Authorization") == null);
    try std.testing.expect(std.mem.indexOf(u8, status, "Authorization") == null);
}

test "webview missing credentials report auth required and reject prompts before provider calls" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    bridge.context.provider = "openai";
    bridge.context.auth_status = .missing;
    bridge.context.api_key_present = false;
    var counters = DispatchCounters{};
    bridge.dispatch_counters = &counters;

    const state = try bridge.handleRequestJson(allocator, "{\"id\":\"state-auth-required\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(state);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"status\":\"missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"required\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"promptEnabled\":false") != null);

    const prompt = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"prompt-auth-required\",\"command\":\"prompt\",\"payload\":{\"text\":\"do not call provider\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"status\":\"auth_required\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"accepted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"events\"") == null);

    const messages = try bridge.handleRequestJson(allocator, "{\"id\":\"messages-auth-required\",\"command\":\"get_messages\"}", trusted_bundle_origin);
    defer allocator.free(messages);
    try std.testing.expect(std.mem.indexOf(u8, messages, "\"messages\":[]") != null);
    try std.testing.expectEqual(@as(usize, 1), counters.prompt);
}

test "webview model selection command is permission gated and preserves state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sessions");
    const session_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "sessions", allocator);
    defer allocator.free(session_dir);

    var session = try testPersistentSessionWithModel(allocator, session_dir, testModel());
    defer session.deinit();
    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);
    const session_id = try allocator.dupe(u8, session.session_manager.getSessionId());
    defer allocator.free(session_id);
    var bridge = testBridge(&session);
    bridge.context.no_session = false;
    var counters = DispatchCounters{};
    bridge.dispatch_counters = &counters;

    const before_file = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(before_file);

    const before = try bridge.handleRequestJson(allocator, "{\"id\":\"before\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(before);

    const response = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"select-denied\",\"command\":\"model_select\",\"payload\":{\"provider\":\"faux\",\"model\":\"faux-model\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"select-denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":\"permission_denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "model selection") != null);

    const after = try bridge.handleRequestJson(allocator, "{\"id\":\"after\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(after);
    const after_file = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(after_file);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"provider\":\"faux\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"model\":\"faux-model\"") != null);
    try std.testing.expectEqualStrings(session_id, session.session_manager.getSessionId());
    try std.testing.expectEqualSlices(u8, before_file, after_file);
    try std.testing.expectEqual(@as(usize, 2), counters.get_state);
    try std.testing.expectEqual(@as(usize, 0), counters.model_select);
}

test "webview model selection validates provider model pairs before dispatch" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    var counters = DispatchCounters{};
    bridge.dispatch_counters = &counters;

    const response = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"bad-model\",\"command\":\"model_select\",\"payload\":{\"provider\":\"faux\",\"model\":\"missing-model\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"bad-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":\"invalid_payload\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "provider/model") != null);
    try std.testing.expectEqual(@as(usize, 0), bridge_testing.dispatchCounterTotal(counters));
}

test "webview model selection during active generation is blocked without changing model" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    bridge.context.permissions.model_selection = true;
    bridge.active_generation.store(true, .seq_cst);

    const response = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"select-active\",\"command\":\"model_select\",\"payload\":{\"provider\":\"faux\",\"model\":\"faux-model\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"select-active\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"busy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"accepted\":false") != null);
    try std.testing.expectEqualStrings("faux-model", bridge.context.model.id);
}

test "webview model selection permission updates active session model safely" {
    const allocator = std.testing.allocator;
    defer ai.model_registry.resetForTesting();
    try ai.model_registry.registerProvider(.{
        .provider = "webview-local-model-provider",
        .api = "openai-completions",
        .base_url = "http://localhost:4321/v1",
        .default_model_id = "webview-local-model",
    });
    try ai.model_registry.registerModel(.{
        .id = "webview-local-model",
        .name = "WebView Local Model",
        .api = "openai-completions",
        .provider = "webview-local-model-provider",
        .base_url = "http://localhost:4321/v1",
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 8192,
        .max_tokens = 1024,
        .reasoning = true,
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sessions");
    const session_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "sessions", allocator);
    defer allocator.free(session_dir);
    var session = try testPersistentSessionWithModel(allocator, session_dir, testModel());
    defer session.deinit();
    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);
    var bridge = testBridge(&session);
    defer bridge.deinit();
    bridge.context.no_session = false;
    bridge.context.permissions.model_selection = true;
    const available_models = [_]provider_config.AvailableModel{.{
        .provider = "webview-local-model-provider",
        .model_id = "webview-local-model",
        .display_name = "WebView Local Model",
        .available = true,
        .auth_status = .local,
        .reasoning = true,
        .tool_calling = false,
        .loaded = false,
        .supports_images = true,
        .context_window = 8192,
        .max_tokens = 1024,
    }};
    bridge.context.available_models = available_models[0..];

    const response = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"select-local\",\"command\":\"model_select\",\"payload\":{\"provider\":\"webview-local-model-provider\",\"model\":\"webview-local-model\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"selected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"permissionRequired\":false") != null);
    try std.testing.expectEqualStrings("webview-local-model", session.agent.getModel().id);
    try std.testing.expectEqualStrings("webview-local-model-provider", bridge.context.provider);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"model_change\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "webview-local-model") != null);
}

test "webview model selection owns selected clone after response allocation failure" {
    const allocator = std.testing.allocator;
    defer ai.model_registry.resetForTesting();
    try ai.model_registry.registerProvider(.{
        .provider = "webview-owned-model-provider",
        .api = "openai-completions",
        .base_url = "http://localhost:4322/v1",
        .default_model_id = "webview-owned-model",
    });
    try ai.model_registry.registerModel(.{
        .id = "webview-owned-model",
        .name = "WebView Owned Model",
        .api = "openai-completions",
        .provider = "webview-owned-model-provider",
        .base_url = "http://localhost:4322/v1",
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 8192,
        .max_tokens = 1024,
        .reasoning = true,
    });

    const available_models = [_]provider_config.AvailableModel{.{
        .provider = "webview-owned-model-provider",
        .model_id = "webview-owned-model",
        .display_name = "WebView Owned Model",
        .available = true,
        .auth_status = .local,
        .reasoning = true,
        .tool_calling = false,
        .loaded = false,
        .supports_images = true,
        .context_window = 8192,
        .max_tokens = 1024,
    }};

    var saw_post_transfer_oom = false;
    var fail_index: usize = 0;
    while (fail_index < 128 and !saw_post_transfer_oom) : (fail_index += 1) {
        var session = try testSession(allocator);
        defer session.deinit();
        var bridge = testBridge(&session);
        defer bridge.deinit();
        bridge.context.permissions.model_selection = true;
        bridge.context.available_models = available_models[0..];

        var failing_state = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_state.allocator();
        if (bridge.handleRequestJson(
            failing_allocator,
            "{\"id\":\"select-owned\",\"command\":\"model_select\",\"payload\":{\"provider\":\"webview-owned-model-provider\",\"model\":\"webview-owned-model\"}}",
            trusted_bundle_origin,
        )) |response| {
            failing_allocator.free(response);
        } else |_| {
            saw_post_transfer_oom = std.mem.eql(u8, bridge.context.model.id, "webview-owned-model");
        }
    }

    try std.testing.expect(saw_post_transfer_oom);
}

test "webview permitted model selection gates missing auth visibly" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    bridge.context.permissions.model_selection = true;
    const available_models = [_]provider_config.AvailableModel{.{
        .provider = "openai",
        .model_id = "gpt-5.4",
        .display_name = "GPT-5.4",
        .available = false,
        .auth_status = .missing,
        .reasoning = true,
        .tool_calling = true,
        .loaded = false,
        .supports_images = true,
        .context_window = 272000,
        .max_tokens = 128000,
    }};
    bridge.context.available_models = available_models[0..];

    const response = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"select-missing\",\"command\":\"model_select\",\"payload\":{\"provider\":\"openai\",\"model\":\"gpt-5.4\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"auth_required\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"promptEnabled\":false") != null);
    try std.testing.expectEqualStrings("faux-model", session.agent.getModel().id);
}

test "webview session mutation commands deny without permission and preserve session file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sessions");
    const session_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "sessions", allocator);
    defer allocator.free(session_dir);

    var session = try testPersistentSessionWithModel(allocator, session_dir, testModel());
    defer session.deinit();
    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);
    const session_id = try allocator.dupe(u8, session.session_manager.getSessionId());
    defer allocator.free(session_id);

    var bridge = testBridge(&session);
    bridge.context.no_session = false;
    var counters = DispatchCounters{};
    bridge.dispatch_counters = &counters;

    const before = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(before);

    var request: std.Io.Writer.Allocating = .init(allocator);
    defer request.deinit();
    try request.writer.writeAll("{\"id\":\"switch-denied\",\"command\":\"switch_session\",\"payload\":{\"sessionPath\":");
    try writeJsonString(allocator, &request.writer, session_file);
    try request.writer.writeAll("}}");

    const response = try bridge.handleRequestJson(allocator, request.written(), trusted_bundle_origin);
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"switch-denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":\"permission_denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "session mutation") != null);

    const after = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(session_id, session.session_manager.getSessionId());
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expectEqual(@as(usize, 0), bridge_testing.dispatchCounterTotal(counters));
}

test "webview session selector exposes controls and permitted switch/new flows" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sessions");
    const session_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "sessions", allocator);
    defer allocator.free(session_dir);

    var first = try testPersistentSessionWithModel(allocator, session_dir, testModel());
    const first_path = try allocator.dupe(u8, first.session_manager.getSessionFile().?);
    defer allocator.free(first_path);
    _ = try first.session_manager.appendSessionInfo("First Session");
    first.deinit();

    var second = try testPersistentSessionWithModel(allocator, session_dir, testModel());
    const second_path = try allocator.dupe(u8, second.session_manager.getSessionFile().?);
    defer allocator.free(second_path);
    _ = try second.session_manager.appendSessionInfo("Second Session");
    var bridge = testBridge(&second);
    bridge.context.no_session = false;
    bridge.context.permissions.session_mutation = true;
    defer second.deinit();

    const state = try bridge.handleRequestJson(allocator, "{\"id\":\"sessions\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(state);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"sessionSelection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"scopes\":[\"current\",\"all\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"sorts\":[\"threaded\",\"recent\",\"relevance\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"nameFilters\":[\"all\",\"named\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"pathToggle\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "First Session") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "Second Session") != null);

    var switch_request: std.Io.Writer.Allocating = .init(allocator);
    defer switch_request.deinit();
    try switch_request.writer.writeAll("{\"id\":\"switch\",\"command\":\"switch_session\",\"payload\":{\"sessionPath\":");
    try writeJsonString(allocator, &switch_request.writer, first_path);
    try switch_request.writer.writeAll("}}");
    const switched = try bridge.handleRequestJson(allocator, switch_request.written(), trusted_bundle_origin);
    defer allocator.free(switched);
    try std.testing.expect(std.mem.indexOf(u8, switched, "\"status\":\"switched\"") != null);
    try std.testing.expectEqualStrings(first_path, second.session_manager.getSessionFile().?);

    const created = try bridge.handleRequestJson(allocator, "{\"id\":\"new\",\"command\":\"new_session\",\"payload\":{}}", trusted_bundle_origin);
    defer allocator.free(created);
    try std.testing.expect(std.mem.indexOf(u8, created, "\"status\":\"created\"") != null);
    try std.testing.expect(!std.mem.eql(u8, first_path, second.session_manager.getSessionFile().?));
}

test "webview session tree exposes active path filters fold markers and persists labels" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sessions");
    const session_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "sessions", allocator);
    defer allocator.free(session_dir);

    var session = try testPersistentSessionWithModel(allocator, session_dir, testModel());
    defer session.deinit();
    var root = try makeBridgeTestTextMessage(allocator, "user", "root prompt", 1, testModel());
    defer session_manager_mod.deinitMessage(allocator, &root);
    const root_id = try session.session_manager.appendMessage(root);
    var main = try makeBridgeTestTextMessage(allocator, "assistant", "main branch", 2, testModel());
    defer session_manager_mod.deinitMessage(allocator, &main);
    _ = try session.session_manager.appendMessage(main);
    try session.session_manager.branch(root_id);
    var alternate = try makeBridgeTestTextMessage(allocator, "assistant", "alternate branch", 3, testModel());
    defer session_manager_mod.deinitMessage(allocator, &alternate);
    const alternate_id = try session.session_manager.appendMessage(alternate);

    var bridge = testBridge(&session);
    bridge.context.no_session = false;
    bridge.context.permissions.session_mutation = true;

    const state = try bridge.handleRequestJson(allocator, "{\"id\":\"tree\",\"command\":\"session_tree_get\"}", trusted_bundle_origin);
    defer allocator.free(state);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"session_tree_get\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"filters\":[\"default\",\"no-tools\",\"user-only\",\"labeled-only\",\"all\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"display\":\"assistant: alternate branch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"hasChildren\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"activePath\":true") != null);

    var label_request: std.Io.Writer.Allocating = .init(allocator);
    defer label_request.deinit();
    try label_request.writer.writeAll("{\"id\":\"label\",\"command\":\"session_tree_label\",\"payload\":{\"entryId\":");
    try writeJsonString(allocator, &label_request.writer, alternate_id);
    try label_request.writer.writeAll(",\"label\":\"  bookmark  \"}}");
    const labeled = try bridge.handleRequestJson(allocator, label_request.written(), trusted_bundle_origin);
    defer allocator.free(labeled);
    try std.testing.expect(std.mem.indexOf(u8, labeled, "\"status\":\"saved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, labeled, "\"label\":\"bookmark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, labeled, "\"labelTimestamp\"") != null);
    try std.testing.expectEqualStrings("bookmark", session.session_manager.getLabel(alternate_id).?);

    const session_file = session.session_manager.getSessionFile().?;
    var reopened = try session_manager_mod.SessionManager.open(allocator, std.testing.io, session_file, null);
    defer reopened.deinit();
    try std.testing.expectEqualStrings("bookmark", reopened.getLabel(alternate_id).?);
}

test "webview session tree navigation prompts for branch summary and can summarize or skip" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var root = try makeBridgeTestTextMessage(allocator, "user", "root prompt", 1, testModel());
    defer session_manager_mod.deinitMessage(allocator, &root);
    const root_id = try session.session_manager.appendMessage(root);
    var main = try makeBridgeTestTextMessage(allocator, "assistant", "main branch", 2, testModel());
    defer session_manager_mod.deinitMessage(allocator, &main);
    const main_id = try session.session_manager.appendMessage(main);
    try session.session_manager.branch(root_id);
    var alternate = try makeBridgeTestTextMessage(allocator, "assistant", "alternate branch", 3, testModel());
    defer session_manager_mod.deinitMessage(allocator, &alternate);
    const alternate_id = try session.session_manager.appendMessage(alternate);

    var bridge = testBridge(&session);
    bridge.context.permissions.session_mutation = true;

    var prompt_request: std.Io.Writer.Allocating = .init(allocator);
    defer prompt_request.deinit();
    try prompt_request.writer.writeAll("{\"id\":\"nav-prompt\",\"command\":\"session_tree_navigate\",\"payload\":{\"entryId\":");
    try writeJsonString(allocator, &prompt_request.writer, main_id);
    try prompt_request.writer.writeAll("}}");
    const prompt = try bridge.handleRequestJson(allocator, prompt_request.written(), trusted_bundle_origin);
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"status\":\"summary_required\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"choices\":[\"skip\",\"summarize\",\"summarize-custom\"]") != null);
    try std.testing.expectEqualStrings(alternate_id, session.session_manager.getLeafId().?);

    var navigate_request: std.Io.Writer.Allocating = .init(allocator);
    defer navigate_request.deinit();
    try navigate_request.writer.writeAll("{\"id\":\"nav-summary\",\"command\":\"session_tree_navigate\",\"payload\":{\"entryId\":");
    try writeJsonString(allocator, &navigate_request.writer, main_id);
    try navigate_request.writer.writeAll(",\"summarize\":true,\"summaryText\":\"webview branch summary\"}}");
    const navigated = try bridge.handleRequestJson(allocator, navigate_request.written(), trusted_bundle_origin);
    defer allocator.free(navigated);
    try std.testing.expect(std.mem.indexOf(u8, navigated, "\"status\":\"navigated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, navigated, "\"summaryEntryId\":null") == null);
    try std.testing.expect(std.mem.indexOf(u8, navigated, "webview branch summary") != null);
    const leaf = session.session_manager.getLeafId().?;
    const leaf_entry = session.session_manager.getEntry(leaf).?;
    try std.testing.expect(leaf_entry.* == .branch_summary);

    var skip_request: std.Io.Writer.Allocating = .init(allocator);
    defer skip_request.deinit();
    try skip_request.writer.writeAll("{\"id\":\"nav-skip\",\"command\":\"session_tree_navigate\",\"payload\":{\"entryId\":");
    try writeJsonString(allocator, &skip_request.writer, root_id);
    try skip_request.writer.writeAll(",\"summarize\":false}}");
    const skipped = try bridge.handleRequestJson(allocator, skip_request.written(), trusted_bundle_origin);
    defer allocator.free(skipped);
    try std.testing.expect(std.mem.indexOf(u8, skipped, "\"status\":\"navigated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, skipped, "\"summaryEntryId\":null") != null);
}

test "webview fork panel lists user messages and forks selected entry" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sessions");
    const session_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "sessions", allocator);
    defer allocator.free(session_dir);

    var session = try testPersistentSessionWithModel(allocator, session_dir, testModel());
    defer session.deinit();
    const original_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(original_file);
    var first_user = try makeBridgeTestTextMessage(allocator, "user", "first prompt", 1, testModel());
    defer session_manager_mod.deinitMessage(allocator, &first_user);
    _ = try session.session_manager.appendMessage(first_user);
    var first_assistant = try makeBridgeTestTextMessage(allocator, "assistant", "first answer", 2, testModel());
    defer session_manager_mod.deinitMessage(allocator, &first_assistant);
    _ = try session.session_manager.appendMessage(first_assistant);
    var second_user = try makeBridgeTestTextMessage(allocator, "user", "second prompt", 3, testModel());
    defer session_manager_mod.deinitMessage(allocator, &second_user);
    const second_user_id = try session.session_manager.appendMessage(second_user);
    var second_assistant = try makeBridgeTestTextMessage(allocator, "assistant", "second answer", 4, testModel());
    defer session_manager_mod.deinitMessage(allocator, &second_assistant);
    _ = try session.session_manager.appendMessage(second_assistant);

    var bridge = testBridge(&session);
    bridge.context.no_session = false;
    bridge.context.permissions.session_mutation = true;

    const panel = try bridge.handleRequestJson(allocator, "{\"id\":\"forks\",\"command\":\"fork_messages_get\"}", trusted_bundle_origin);
    defer allocator.free(panel);
    try std.testing.expect(std.mem.indexOf(u8, panel, "\"messages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, panel, "first prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, panel, "second prompt") != null);

    var fork_request: std.Io.Writer.Allocating = .init(allocator);
    defer fork_request.deinit();
    try fork_request.writer.writeAll("{\"id\":\"fork\",\"command\":\"fork_session\",\"payload\":{\"entryId\":");
    try writeJsonString(allocator, &fork_request.writer, second_user_id);
    try fork_request.writer.writeAll("}}");
    const forked = try bridge.handleRequestJson(allocator, fork_request.written(), trusted_bundle_origin);
    defer allocator.free(forked);
    try std.testing.expect(std.mem.indexOf(u8, forked, "\"status\":\"forked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, forked, "\"editorText\":\"second prompt\"") != null);
    try std.testing.expect(session.session_manager.getSessionFile() != null);
    try std.testing.expect(!std.mem.eql(u8, original_file, session.session_manager.getSessionFile().?));

    const messages = try bridge.handleRequestJson(allocator, "{\"id\":\"after-fork\",\"command\":\"get_messages\"}", trusted_bundle_origin);
    defer allocator.free(messages);
    try std.testing.expect(std.mem.indexOf(u8, messages, "first prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "first answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "second prompt") == null);
}

test "webview auth mutation commands deny without echoing credential payloads" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sessions");
    const session_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "sessions", allocator);
    defer allocator.free(session_dir);

    var session = try testPersistentSessionWithModel(allocator, session_dir, testModel());
    defer session.deinit();
    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);

    var bridge = testBridge(&session);
    bridge.context.no_session = false;
    bridge.context.provider = "openai";
    bridge.context.auth_status = .missing;
    var counters = DispatchCounters{};
    bridge.dispatch_counters = &counters;

    const before = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(before);

    const response = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"save-secret\",\"command\":\"save_api_key\",\"payload\":{\"provider\":\"openai\",\"apiKey\":\"sk-webview-secret\",\"path\":\"/Users/alice/.pi/agent/auth.json\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"save-secret\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":\"permission_denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "auth mutation") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "sk-webview-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "auth.json") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/Users/alice") == null);

    const after = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expectEqual(@as(usize, 0), counters.save_api_key);
    try std.testing.expectEqual(@as(usize, 0), bridge_testing.dispatchCounterTotal(counters));
}

test "webview auth mutation save and remove are permissioned and secret safe" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sessions");
    try tmp.dir.createDirPath(std.testing.io, "agent");
    const session_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "sessions", allocator);
    defer allocator.free(session_dir);
    const agent_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "agent", allocator);
    defer allocator.free(agent_dir);
    const auth_path = try std.fs.path.join(allocator, &.{ agent_dir, "auth.json" });
    defer allocator.free(auth_path);

    var session = try testPersistentSessionWithModel(allocator, session_dir, testModel());
    defer session.deinit();
    var bridge = testBridge(&session);
    defer bridge.deinit();
    bridge.context.provider = "openai";
    bridge.context.auth_status = .missing;
    bridge.context.api_key_present = false;
    bridge.context.no_session = false;
    bridge.context.permissions.auth_mutation = true;
    bridge.context.auth_path = auth_path;
    const sentinel = "sk-webview-secret-sentinel";

    const saved = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"save-secret\",\"command\":\"save_api_key\",\"payload\":{\"provider\":\"openai\",\"apiKey\":\"sk-webview-secret-sentinel\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"status\":\"saved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"secretEcho\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, sentinel) == null);
    try std.testing.expectEqual(provider_config.ProviderAuthStatus.stored, bridge.context.auth_status);
    try std.testing.expect(bridge.context.api_key_present);

    const removed = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"remove-secret\",\"command\":\"remove_auth\",\"payload\":{\"provider\":\"openai\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(removed);
    try std.testing.expect(std.mem.indexOf(u8, removed, "\"status\":\"removed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, removed, sentinel) == null);
    try std.testing.expectEqual(provider_config.ProviderAuthStatus.missing, bridge.context.auth_status);
    try std.testing.expect(!bridge.context.api_key_present);
}

test "webview session mutation commands validate targets before permission gate" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    var counters = DispatchCounters{};
    bridge.dispatch_counters = &counters;

    const before = try bridge.handleRequestJson(allocator, "{\"id\":\"before\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(before);

    const response = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"bad-switch\",\"command\":\"switch_session\",\"payload\":{\"sessionPath\":\"\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"bad-switch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":\"invalid_payload\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "session target") != null);

    const after = try bridge.handleRequestJson(allocator, "{\"id\":\"after\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"busy\":false") != null);
    try std.testing.expectEqual(@as(usize, 2), counters.get_state);
    try std.testing.expectEqual(@as(usize, 0), counters.get_messages);
    try std.testing.expectEqual(@as(usize, 0), counters.prompt);
    try std.testing.expectEqual(@as(usize, 0), counters.abort);
}

test "webview no-session prompt remains in memory without session file persistence" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sessions");
    const session_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "sessions", allocator);
    defer allocator.free(session_dir);

    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();
    const blocks = [_]faux.FauxContentBlock{faux.fauxText("ephemeral answer")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks[0..], .{}) },
    });

    var session = try testSessionWithModel(allocator, registration.getModel());
    defer session.deinit();
    var bridge = testBridge(&session);
    defer bridge.deinit();
    bridge.context.model = registration.getModel();
    bridge.context.no_session = true;

    const prompt = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"prompt\",\"command\":\"prompt\",\"payload\":{\"text\":\"ephemeral prompt\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"status\":\"accepted\"") != null);
    const turn_id = try extractResultStringField(allocator, prompt, "turnId");
    defer allocator.free(turn_id);
    const events = try waitForTerminalEvents(allocator, &bridge, turn_id);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"terminalOutcome\":\"success\"") != null);

    const messages = try bridge.handleRequestJson(allocator, "{\"id\":\"messages\",\"command\":\"get_messages\"}", trusted_bundle_origin);
    defer allocator.free(messages);
    try std.testing.expect(std.mem.indexOf(u8, messages, "ephemeral prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "ephemeral answer") != null);
    try std.testing.expect(session.session_manager.getSessionFile() == null);
    try std.testing.expectEqual(@as(usize, 0), try countDirectoryEntries(session_dir));
}

test "webview prompt denies concurrent active turn deterministically" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    bridge.active_turn_id = "active-turn";
    bridge.active_generation.store(true, .seq_cst);

    const response = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"busy\",\"command\":\"prompt\",\"payload\":{\"text\":\"second\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"busy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"accepted\":false") != null);
}

test "webview provider error is surfaced safely and bridge remains usable" {
    const allocator = std.testing.allocator;
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();
    const blocks = [_]faux.FauxContentBlock{faux.fauxText("partial before error")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks[0..], .{
            .stop_reason = .error_reason,
            .error_message = "faux provider failed safely",
        }) },
    });

    var session = try testSessionWithModel(allocator, registration.getModel());
    defer session.deinit();
    var bridge = testBridge(&session);
    defer bridge.deinit();
    bridge.context.model = registration.getModel();

    const prompt = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"prompt-error\",\"command\":\"prompt\",\"payload\":{\"text\":\"trigger error\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"status\":\"accepted\"") != null);
    const turn_id = try extractResultStringField(allocator, prompt, "turnId");
    defer allocator.free(turn_id);
    const events = try waitForTerminalEvents(allocator, &bridge, turn_id);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"terminalOutcome\":\"provider_error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "faux provider failed safely") != null);

    const state = try bridge.handleRequestJson(allocator, "{\"id\":\"after-error\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(state);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"id\":\"after-error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"busy\":false") != null);
}

test "webview provider error persists explicit canonical policy for non-webview readers" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sessions");
    const session_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "sessions", allocator);
    defer allocator.free(session_dir);

    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();
    const blocks = [_]faux.FauxContentBlock{faux.fauxText("partial before persisted error")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks[0..], .{
            .stop_reason = .error_reason,
            .error_message = "persisted provider error",
        }) },
    });

    var session = try testPersistentSessionWithModel(allocator, session_dir, registration.getModel());
    defer session.deinit();
    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);
    var bridge = testBridge(&session);
    defer bridge.deinit();
    bridge.context.model = registration.getModel();
    bridge.context.no_session = false;

    const prompt = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"prompt-error\",\"command\":\"prompt\",\"payload\":{\"text\":\"persist failing turn\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"status\":\"accepted\"") != null);
    const turn_id = try extractResultStringField(allocator, prompt, "turnId");
    defer allocator.free(turn_id);
    const events = try waitForTerminalEvents(allocator, &bridge, turn_id);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"terminalOutcome\":\"provider_error\"") != null);

    const messages = try bridge.handleRequestJson(allocator, "{\"id\":\"messages-after-error\",\"command\":\"get_messages\"}", trusted_bundle_origin);
    defer allocator.free(messages);
    try std.testing.expect(std.mem.indexOf(u8, messages, "persist failing turn") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "partial before persisted error") == null);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "persist failing turn") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "partial before persisted error") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"stopReason\":\"error\"") != null);

    var reopened = try session_mod.AgentSession.open(allocator, std.testing.io, .{
        .session_file = session_file,
        .system_prompt = "",
        .model = registration.getModel(),
    });
    defer reopened.deinit();
    const replayed = reopened.agent.getMessages();
    try std.testing.expectEqual(@as(usize, 1), replayed.len);
    try std.testing.expectEqualStrings("persist failing turn", replayed[0].user.content[0].text.text);
}

test "webview abort without active generation is safe no-op" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);

    const before = try bridge.handleRequestJson(allocator, "{\"id\":\"before\",\"command\":\"get_messages\"}", trusted_bundle_origin);
    defer allocator.free(before);

    const abort = try bridge.handleRequestJson(allocator, "{\"id\":\"abort-idle\",\"command\":\"abort\"}", trusted_bundle_origin);
    defer allocator.free(abort);
    try std.testing.expect(std.mem.indexOf(u8, abort, "\"status\":\"not_running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, abort, "\"aborted\":false") != null);

    const after = try bridge.handleRequestJson(allocator, "{\"id\":\"after\",\"command\":\"get_messages\"}", trusted_bundle_origin);
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"messages\":[]") != null);
}

test "webview abort cancels active generation suppresses late events and supports retry" {
    const allocator = std.testing.allocator;
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(allocator, .{
        .tokens_per_second = 5,
        .token_size = .{ .min = 1, .max = 1 },
    });
    defer registration.unregister();
    const slow_text = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz";
    const slow_blocks = [_]faux.FauxContentBlock{faux.fauxText(slow_text)};
    const retry_blocks = [_]faux.FauxContentBlock{faux.fauxText("retry succeeded")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(slow_blocks[0..], .{}) },
        .{ .message = faux.fauxAssistantMessage(retry_blocks[0..], .{}) },
    });

    var session = try testSessionWithModel(allocator, registration.getModel());
    defer session.deinit();
    var bridge = testBridge(&session);
    defer bridge.deinit();
    bridge.context.model = registration.getModel();

    const prompt = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"abort-prompt\",\"command\":\"prompt\",\"payload\":{\"text\":\"abort me\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"status\":\"accepted\"") != null);
    const turn_id = try extractResultStringField(allocator, prompt, "turnId");
    defer allocator.free(turn_id);
    try std.testing.expect(bridge.active_generation.load(.seq_cst));
    std.Io.sleep(std.testing.io, .fromMilliseconds(250), .awake) catch {};

    const abort = try bridge.handleRequestJson(allocator, "{\"id\":\"abort-active\",\"command\":\"abort\"}", trusted_bundle_origin);
    defer allocator.free(abort);
    try std.testing.expect(std.mem.indexOf(u8, abort, "\"status\":\"abort_requested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, abort, "\"aborted\":true") != null);

    const aborted_events = try waitForTerminalEvents(allocator, &bridge, turn_id);
    defer allocator.free(aborted_events);
    try std.testing.expect(std.mem.indexOf(u8, aborted_events, "\"terminalOutcome\":\"abort\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aborted_events, "\"terminal\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, aborted_events, slow_text) == null);
    try std.testing.expect(!bridge.active_generation.load(.seq_cst));

    var capture_host = testBridge(&session);
    capture_host.worker_allocator = allocator;
    defer capture_host.deinit();
    var capture = PromptEventCapture.init(allocator, &capture_host, "session", "turn");
    defer capture.deinit();
    try capture.appendSyntheticTerminal("abort", "Request was aborted");
    try capture.appendEvent(.{ .event_type = .message_update });
    try std.testing.expectEqual(@as(usize, 1), bridge_testing.eventFrameCount(&capture_host));

    const retry = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"retry-prompt\",\"command\":\"prompt\",\"payload\":{\"text\":\"try again\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(retry);
    try std.testing.expect(std.mem.indexOf(u8, retry, "\"status\":\"accepted\"") != null);
    const retry_turn_id = try extractResultStringField(allocator, retry, "turnId");
    defer allocator.free(retry_turn_id);
    const retry_events = try waitForTerminalEvents(allocator, &bridge, retry_turn_id);
    defer allocator.free(retry_events);
    try std.testing.expect(std.mem.indexOf(u8, retry_events, "\"terminalOutcome\":\"success\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, retry_events, "retry succeeded") != null);
}

test "webview queued events ignore post-terminal assistant mutations" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    bridge.worker_allocator = allocator;
    defer bridge.deinit();

    var capture = PromptEventCapture.init(allocator, &bridge, "session", "turn");
    defer capture.deinit();
    try capture.appendSyntheticTerminal("abort", "Request was aborted");
    try bridge_testing.enqueueEventFrame(
        &bridge,
        try allocator.dupe(u8, "{\"sessionId\":\"session\",\"turnId\":\"turn\",\"sequence\":2,\"type\":\"message_update\",\"terminal\":false,\"event\":{\"assistantMessageEvent\":{\"delta\":\"late full content\"}}}"),
        2,
        false,
        "success",
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), bridge_testing.eventFrameCount(&bridge));
    try std.testing.expect(std.mem.indexOf(u8, bridge_testing.eventFrameBytes(&bridge, 0), "Request was aborted") != null);
    try std.testing.expect(std.mem.indexOf(u8, bridge_testing.eventFrameBytes(&bridge, 0), "late full content") == null);
}

test "webview provider error returns retry-ready promptly" {
    const allocator = std.testing.allocator;
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();
    const error_blocks = [_]faux.FauxContentBlock{faux.fauxText("partial before retryable error")};
    const retry_blocks = [_]faux.FauxContentBlock{faux.fauxText("retry after provider error succeeded")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(error_blocks[0..], .{
            .stop_reason = .error_reason,
            .error_message = "retryable provider error",
        }) },
        .{ .message = faux.fauxAssistantMessage(retry_blocks[0..], .{}) },
    });

    var session = try testSessionWithModel(allocator, registration.getModel());
    defer session.deinit();
    var bridge = testBridge(&session);
    defer bridge.deinit();
    bridge.context.model = registration.getModel();

    const prompt = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"prompt-error\",\"command\":\"prompt\",\"payload\":{\"text\":\"trigger retryable error\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(prompt);
    const turn_id = try extractResultStringField(allocator, prompt, "turnId");
    defer allocator.free(turn_id);
    const events = try waitForTerminalEvents(allocator, &bridge, turn_id);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"terminalOutcome\":\"provider_error\"") != null);

    const retry_deadline_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds + 500 * std.time.ns_per_ms;
    var retry_response: ?[]u8 = null;
    while (std.Io.Clock.now(.awake, std.testing.io).nanoseconds < retry_deadline_ns) {
        const retry = try bridge.handleRequestJson(
            allocator,
            "{\"id\":\"retry-after-error\",\"command\":\"prompt\",\"payload\":{\"text\":\"retry after error\"}}",
            trusted_bundle_origin,
        );
        if (std.mem.indexOf(u8, retry, "\"status\":\"accepted\"") != null) {
            retry_response = retry;
            break;
        }
        allocator.free(retry);
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    const accepted_retry = retry_response orelse return error.TestTimeout;
    defer allocator.free(accepted_retry);
    const retry_turn_id = try extractResultStringField(allocator, accepted_retry, "turnId");
    defer allocator.free(retry_turn_id);
    const retry_events = try waitForTerminalEvents(allocator, &bridge, retry_turn_id);
    defer allocator.free(retry_events);
    try std.testing.expect(std.mem.indexOf(u8, retry_events, "\"terminalOutcome\":\"success\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, retry_events, "retry after provider error succeeded") != null);
}

test "webview close aborts active generation cleanup path" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);

    try std.testing.expect(!bridge.closeAndAbortActiveWork());
    bridge.active_generation.store(true, .seq_cst);
    try std.testing.expect(bridge.closeAndAbortActiveWork());
    try std.testing.expect(bridge.close_requested.load(.seq_cst));
}

test "webview state surfaces prepared initial input without bridge metadata" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    bridge.context.initial_prompt = "draft prompt";
    bridge.context.initial_messages = &[_][]const u8{ "positional one", "positional two" };
    bridge.context.initial_images_count = 1;

    const response = try bridge.handleRequestJson(allocator, "{\"id\":\"state\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"initialInput\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "draft prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"imagesCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"turnId\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"sequence\"") == null);
}

test "bridge envelopes correlate success responses and omit secrets" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);

    const response = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"req-1\",\"command\":\"get_state\",\"payload\":{\"ignored\":\"sk-webview-secret\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"req-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"provider\":\"faux\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "sk-webview-secret") == null);
}

test "bridge denies unknown commands before dispatch" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    var counters = DispatchCounters{};
    bridge.dispatch_counters = &counters;

    const response = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"req-unknown\",\"command\":\"native_shell\",\"payload\":{}}",
        trusted_bundle_origin,
    );
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"req-unknown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":\"unknown_command\"") != null);
    try std.testing.expectEqual(@as(usize, 0), bridge_testing.dispatchCounterTotal(counters));
}

test "bridge malformed errors do not poison subsequent valid requests" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);

    const malformed = try bridge.handleRequestJson(allocator, "{\"id\":\"bad\"", trusted_bundle_origin);
    defer allocator.free(malformed);
    try std.testing.expect(std.mem.indexOf(u8, malformed, "\"code\":\"malformed_json\"") != null);

    const valid = try bridge.handleRequestJson(allocator, "{\"id\":\"req-2\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(valid);
    try std.testing.expect(std.mem.indexOf(u8, valid, "\"id\":\"req-2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, valid, "\"ok\":true") != null);
}

test "bridge handler failures return structured errors and host remains usable" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    var counters = DispatchCounters{};
    bridge.dispatch_counters = &counters;
    bridge.injected_handler_error = error.InjectedBridgeHandlerFailure;

    const failure = try bridge.handleRequestJson(allocator, "{\"id\":\"req-fail\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(failure);
    try std.testing.expect(std.mem.indexOf(u8, failure, "\"id\":\"req-fail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure, "\"code\":\"handler_error\"") != null);
    try std.testing.expectEqual(@as(usize, 1), counters.get_state);

    bridge.injected_handler_error = null;
    const valid = try bridge.handleRequestJson(allocator, "{\"id\":\"req-after-fail\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(valid);
    try std.testing.expect(std.mem.indexOf(u8, valid, "\"id\":\"req-after-fail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, valid, "\"ok\":true") != null);
    try std.testing.expectEqual(@as(usize, 2), counters.get_state);
}

test "bridge validates request envelope and payload shape before dispatch" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    var counters = DispatchCounters{};
    bridge.dispatch_counters = &counters;

    const not_object = try bridge.handleRequestJson(allocator, "[]", trusted_bundle_origin);
    defer allocator.free(not_object);
    try std.testing.expect(std.mem.indexOf(u8, not_object, "\"id\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, not_object, "\"code\":\"invalid_envelope\"") != null);

    const missing_id = try bridge.handleRequestJson(allocator, "{\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(missing_id);
    try std.testing.expect(std.mem.indexOf(u8, missing_id, "\"id\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing_id, "\"code\":\"invalid_request_id\"") != null);

    const numeric_id = try bridge.handleRequestJson(allocator, "{\"id\":7,\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(numeric_id);
    try std.testing.expect(std.mem.indexOf(u8, numeric_id, "\"id\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, numeric_id, "\"code\":\"invalid_request_id\"") != null);

    const numeric_command = try bridge.handleRequestJson(allocator, "{\"id\":\"bad-command\",\"command\":7}", trusted_bundle_origin);
    defer allocator.free(numeric_command);
    try std.testing.expect(std.mem.indexOf(u8, numeric_command, "\"id\":\"bad-command\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, numeric_command, "\"code\":\"invalid_command\"") != null);

    const missing_prompt_text = try bridge.handleRequestJson(allocator, "{\"id\":\"bad-prompt\",\"command\":\"prompt\",\"payload\":{}}", trusted_bundle_origin);
    defer allocator.free(missing_prompt_text);
    try std.testing.expect(std.mem.indexOf(u8, missing_prompt_text, "\"id\":\"bad-prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing_prompt_text, "\"code\":\"invalid_payload\"") != null);

    const non_string_prompt = try bridge.handleRequestJson(allocator, "{\"id\":\"bad-text\",\"command\":\"prompt\",\"payload\":{\"text\":42}}", trusted_bundle_origin);
    defer allocator.free(non_string_prompt);
    try std.testing.expect(std.mem.indexOf(u8, non_string_prompt, "\"id\":\"bad-text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, non_string_prompt, "\"code\":\"invalid_payload\"") != null);

    try std.testing.expectEqual(@as(usize, 0), bridge_testing.dispatchCounterTotal(counters));
}

test "bridge bounds payloads before dispatch" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    var counters = DispatchCounters{};
    bridge.dispatch_counters = &counters;
    bridge.limits.max_request_bytes = 32;

    const oversized = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"req-large\",\"command\":\"get_state\",\"payload\":{\"padding\":\"1234567890\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(oversized);
    try std.testing.expect(std.mem.indexOf(u8, oversized, "\"code\":\"payload_too_large\"") != null);
    try std.testing.expectEqual(@as(usize, 0), bridge_testing.dispatchCounterTotal(counters));
}

test "bridge enforces prompt text limit before dispatch" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    var counters = DispatchCounters{};
    bridge.dispatch_counters = &counters;
    bridge.limits.max_prompt_bytes = 4;

    const response = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"req-prompt-large\",\"command\":\"prompt\",\"payload\":{\"text\":\"12345\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"req-prompt-large\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":\"payload_too_large\"") != null);
    try std.testing.expectEqual(@as(usize, 0), bridge_testing.dispatchCounterTotal(counters));
}

test "bridge rejects deeply nested payloads before dispatch" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    var counters = DispatchCounters{};
    bridge.dispatch_counters = &counters;
    bridge.limits.max_depth = 3;

    const response = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"req-deep\",\"command\":\"get_state\",\"payload\":{\"a\":{\"b\":{\"c\":{\"d\":1}}}}}",
        trusted_bundle_origin,
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":\"payload_too_deep\"") != null);
    try std.testing.expectEqual(@as(usize, 0), bridge_testing.dispatchCounterTotal(counters));
}

test "bridge rejects untrusted origins before dispatch" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
    var counters = DispatchCounters{};
    bridge.dispatch_counters = &counters;

    const response = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"req-origin\",\"command\":\"get_state\"}",
        "https://example.invalid",
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":\"untrusted_origin\"") != null);
    try std.testing.expectEqual(@as(usize, 0), bridge_testing.dispatchCounterTotal(counters));
}

test "bridge trusts only bundled and constrained file origins" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "assets");
    try tmp.dir.createDirPath(std.testing.io, "outside");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "assets/index.html", .data = "<!doctype html>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside/index.html", .data = "<!doctype html>" });

    const asset_root = try tmp.dir.realPathFileAlloc(std.testing.io, "assets", allocator);
    defer allocator.free(asset_root);
    const index = try tmp.dir.realPathFileAlloc(std.testing.io, "assets/index.html", allocator);
    defer allocator.free(index);
    const outside = try tmp.dir.realPathFileAlloc(std.testing.io, "outside/index.html", allocator);
    defer allocator.free(outside);

    const trusted_url = try std.fmt.allocPrint(allocator, "file://{s}", .{index});
    defer allocator.free(trusted_url);
    const outside_url = try std.fmt.allocPrint(allocator, "file://{s}", .{outside});
    defer allocator.free(outside_url);
    const query_url = try std.fmt.allocPrint(allocator, "file://{s}?access_token=sk-webview-secret", .{index});
    defer allocator.free(query_url);

    try std.testing.expect(isTrustedBridgeOrigin(trusted_bundle_origin, asset_root));
    try std.testing.expect(isTrustedBridgeOrigin(trusted_url, asset_root));
    try std.testing.expect(!isTrustedBridgeOrigin(outside_url, asset_root));
    try std.testing.expect(!isTrustedBridgeOrigin(query_url, asset_root));
    try std.testing.expect(!isTrustedBridgeOrigin("file:///tmp/pi-webview-assets/%2e%2e/secret.txt", asset_root));
    try std.testing.expect(!isTrustedBridgeOrigin("https://example.invalid", asset_root));
}

test "navigation policy allows bundled assets and denies external popups" {
    try std.testing.expect(authorizeNavigation("file:///tmp/pi-webview-assets/index.html", "/tmp/pi-webview-assets", .navigation) == .allow);
    try std.testing.expect(authorizeNavigation("file:///tmp/pi-webview-assets/index.html?token=sk-secret", "/tmp/pi-webview-assets", .navigation) == .deny);
    try std.testing.expect(authorizeNavigation("https://example.invalid", "/tmp/pi-webview-assets", .navigation) == .deny);
    try std.testing.expect(authorizeNavigation("file:///tmp/pi-webview-assets/index.html", "/tmp/pi-webview-assets", .popup) == .deny);
}

test "asset request resolver denies traversal and symlink escapes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "assets");
    try tmp.dir.createDirPath(std.testing.io, "outside");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "assets/index.html", .data = "<!doctype html>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside/secret.txt", .data = "secret" });
    try tmp.dir.symLink(std.testing.io, "../outside/secret.txt", "assets/link.txt", .{});

    const asset_root = try tmp.dir.realPathFileAlloc(std.testing.io, "assets", allocator);
    defer allocator.free(asset_root);

    const index = try resolveAssetRequest(allocator, asset_root, "index.html");
    defer allocator.free(index);
    try std.testing.expect(std.mem.endsWith(u8, index, "assets/index.html"));

    try std.testing.expectError(error.AssetPathDenied, resolveAssetRequest(allocator, asset_root, ""));
    try std.testing.expectError(error.AssetPathDenied, resolveAssetRequest(allocator, asset_root, "."));
    try std.testing.expectError(error.AssetPathDenied, resolveAssetRequest(allocator, asset_root, "./index.html"));
    try std.testing.expectError(error.AssetPathDenied, resolveAssetRequest(allocator, asset_root, "nested/../index.html"));
    try std.testing.expectError(error.AssetPathDenied, resolveAssetRequest(allocator, asset_root, index));
    try std.testing.expectError(error.AssetPathDenied, resolveAssetRequest(allocator, asset_root, "../outside/secret.txt"));
    try std.testing.expectError(error.AssetPathDenied, resolveAssetRequest(allocator, asset_root, "link.txt"));
    try std.testing.expectError(error.FileNotFound, resolveAssetRequest(allocator, asset_root, "missing.txt"));
}

test "bridge diagnostics do not echo credential-shaped input" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);

    const response = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"req-secret\",\"command\":\"sk-live-webview-secret\",\"payload\":{\"authorization\":\"Bearer sk-webview-secret\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "sk-live-webview-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "sk-webview-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":\"unknown_command\"") != null);
}

fn countDirectoryEntries(path: []const u8) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, path, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| {
        count += 1;
    }
    return count;
}
