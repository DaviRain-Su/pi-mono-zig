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
