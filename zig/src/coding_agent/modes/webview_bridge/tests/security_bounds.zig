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
