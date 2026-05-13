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
