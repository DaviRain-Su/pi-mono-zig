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
