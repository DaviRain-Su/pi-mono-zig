const fixtures = @import("common.zig");

const std = fixtures.std;
const ai = fixtures.ai;
const agent = fixtures.agent;
const common = fixtures.common;
const config_mod = fixtures.config_mod;
const provider_config = fixtures.provider_config;
const resources_mod = fixtures.resources_mod;
const session_mod = fixtures.session_mod;
const session_manager_mod = fixtures.session_manager_mod;

const BridgeHost = fixtures.BridgeHost;
const Command = fixtures.Command;
const DispatchCounters = fixtures.DispatchCounters;
const Permission = fixtures.Permission;
const WebViewExtensionCommand = fixtures.WebViewExtensionCommand;
const authorizeNavigation = fixtures.authorizeNavigation;
const command_table = fixtures.command_table;
const isTrustedBridgeOrigin = fixtures.isTrustedBridgeOrigin;
const resolveAssetRequest = fixtures.resolveAssetRequest;
const trusted_bundle_origin = fixtures.trusted_bundle_origin;
const writeJsonString = fixtures.writeJsonString;
const bridge_testing = fixtures.bridge_testing;
const PromptEventCapture = fixtures.PromptEventCapture;

const testModel = fixtures.testModel;
const testSession = fixtures.testSession;
const testSessionWithModel = fixtures.testSessionWithModel;
const testPersistentSessionWithModel = fixtures.testPersistentSessionWithModel;
const testBridge = fixtures.testBridge;
const makeBridgeTestTextMessage = fixtures.makeBridgeTestTextMessage;
const extractResultStringField = fixtures.extractResultStringField;
const waitForTerminalEvents = fixtures.waitForTerminalEvents;
const countDirectoryEntries = fixtures.countDirectoryEntries;

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
