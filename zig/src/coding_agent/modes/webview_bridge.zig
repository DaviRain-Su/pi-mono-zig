const std = @import("std");
const ai = @import("ai");
const session_mod = @import("../sessions/session.zig");
const tool_selection = @import("../tool_selection.zig");

pub const trusted_bundle_origin = "pi-webview://bundle";

pub const Limits = struct {
    max_request_bytes: usize = 64 * 1024,
    max_depth: usize = 32,
    max_string_bytes: usize = 8 * 1024,
    max_request_id_bytes: usize = 128,
    max_command_bytes: usize = 64,
    max_prompt_bytes: usize = 32 * 1024,
};

pub const Command = enum {
    get_state,
    get_messages,
    prompt,
    abort,
};

pub const Permission = enum {
    skeleton_chat,
};

pub const CommandSpec = struct {
    name: []const u8,
    command: Command,
    permission: Permission,
};

pub const command_table = [_]CommandSpec{
    .{ .name = "get_state", .command = .get_state, .permission = .skeleton_chat },
    .{ .name = "get_messages", .command = .get_messages, .permission = .skeleton_chat },
    .{ .name = "prompt", .command = .prompt, .permission = .skeleton_chat },
    .{ .name = "abort", .command = .abort, .permission = .skeleton_chat },
};

pub const BridgeContext = struct {
    cwd: []const u8,
    trusted_asset_root: []const u8,
    provider: []const u8,
    model: ai.Model,
    no_session: bool,
    api_key_present: bool,
    selected_tools: tool_selection.ToolSelection,
    active_tool_count: usize,
    session: *const session_mod.AgentSession,
};

pub const DispatchCounters = struct {
    get_state: usize = 0,
    get_messages: usize = 0,
    prompt: usize = 0,
    abort: usize = 0,

    fn increment(self: *DispatchCounters, command: Command) void {
        switch (command) {
            .get_state => self.get_state += 1,
            .get_messages => self.get_messages += 1,
            .prompt => self.prompt += 1,
            .abort => self.abort += 1,
        }
    }

    fn total(self: DispatchCounters) usize {
        return self.get_state + self.get_messages + self.prompt + self.abort;
    }
};

pub const BridgeHost = struct {
    context: BridgeContext,
    limits: Limits = .{},
    dispatch_counters: ?*DispatchCounters = null,
    injected_handler_error: ?anyerror = null,

    pub fn init(context: BridgeContext) BridgeHost {
        return .{ .context = context };
    }

    pub fn handleRequestJson(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        request_json: []const u8,
        origin: []const u8,
    ) ![]u8 {
        if (request_json.len > self.limits.max_request_bytes) {
            return writeErrorResponseAlloc(
                allocator,
                null,
                "payload_too_large",
                "Bridge request exceeds the configured payload limit",
            );
        }

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, request_json, .{}) catch {
            return writeErrorResponseAlloc(allocator, null, "malformed_json", "Bridge request is not valid JSON");
        };
        defer parsed.deinit();

        validateValueBounds(parsed.value, self.limits, 0) catch |err| switch (err) {
            error.PayloadTooDeep => return writeErrorResponseAlloc(
                allocator,
                null,
                "payload_too_deep",
                "Bridge request exceeds the configured nesting limit",
            ),
            error.StringTooLong => return writeErrorResponseAlloc(
                allocator,
                null,
                "string_too_large",
                "Bridge request contains a string that exceeds the configured limit",
            ),
        };

        const object = switch (parsed.value) {
            .object => |value| value,
            else => return writeErrorResponseAlloc(allocator, null, "invalid_envelope", "Bridge request envelope must be an object"),
        };

        const request_id = getObjectString(object, "id") orelse return writeErrorResponseAlloc(
            allocator,
            null,
            "invalid_request_id",
            "Bridge request id is required and must be a string",
        );
        if (request_id.len == 0 or request_id.len > self.limits.max_request_id_bytes) {
            return writeErrorResponseAlloc(
                allocator,
                null,
                "invalid_request_id",
                "Bridge request id length is outside the allowed bounds",
            );
        }

        const command_name = getObjectString(object, "command") orelse return writeErrorResponseAlloc(
            allocator,
            request_id,
            "invalid_command",
            "Bridge command is required and must be a string",
        );
        if (command_name.len == 0 or command_name.len > self.limits.max_command_bytes) {
            return writeErrorResponseAlloc(
                allocator,
                request_id,
                "invalid_command",
                "Bridge command length is outside the allowed bounds",
            );
        }

        if (!isTrustedBridgeOrigin(origin, self.context.trusted_asset_root)) {
            return writeErrorResponseAlloc(
                allocator,
                request_id,
                "untrusted_origin",
                "Bridge access is restricted to the bundled WebView frontend",
            );
        }

        const spec = lookupCommand(command_name) orelse return writeErrorResponseAlloc(
            allocator,
            request_id,
            "unknown_command",
            "Command is not exposed by the WebView bridge",
        );

        const payload = object.get("payload");
        if (!payloadShapeAllowed(spec.command, payload)) {
            return writeErrorResponseAlloc(
                allocator,
                request_id,
                "invalid_payload",
                "Bridge command payload does not match the expected schema",
            );
        }
        validateCommandPayloadBounds(spec.command, payload, self.limits) catch |err| switch (err) {
            error.PromptTooLarge => return writeErrorResponseAlloc(
                allocator,
                request_id,
                "payload_too_large",
                "Bridge command payload exceeds the configured command limit",
            ),
        };

        if (self.dispatch_counters) |counters| counters.increment(spec.command);
        return self.dispatch(allocator, request_id, spec.command, payload) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => writeErrorResponseAlloc(
                allocator,
                request_id,
                "handler_error",
                "Bridge command failed without crashing the WebView host",
            ),
        };
    }

    fn dispatch(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        request_id: []const u8,
        command: Command,
        payload: ?std.json.Value,
    ) ![]u8 {
        if (self.injected_handler_error) |err| return err;

        var writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer writer.deinit();

        try writer.writer.writeAll("{");
        try writeJsonString(allocator, &writer.writer, "id");
        try writer.writer.writeAll(":");
        try writeJsonString(allocator, &writer.writer, request_id);
        try writer.writer.writeAll(",\"ok\":true,\"result\":");

        switch (command) {
            .get_state => try self.writeStateResult(allocator, &writer.writer),
            .get_messages => try self.writeMessagesResult(allocator, &writer.writer),
            .prompt => try writePromptResult(allocator, &writer.writer, payload.?),
            .abort => try writer.writer.writeAll("{\"status\":\"not_running\",\"aborted\":false}"),
        }

        try writer.writer.writeAll("}");
        return try writer.toOwnedSlice();
    }

    fn writeStateResult(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !void {
        try writer.writeAll("{");
        try writeStringField(allocator, writer, "provider", self.context.provider, false);
        try writeStringField(allocator, writer, "model", self.context.model.id, true);
        try writeStringField(allocator, writer, "sessionId", self.context.session.session_manager.getSessionId(), true);
        try writeBoolField(writer, "noSession", self.context.no_session, true);
        try writeBoolField(writer, "apiKeyPresent", self.context.api_key_present, true);
        try writeBoolField(writer, "toolsDisabled", self.context.selected_tools.disable_all, true);
        try writeUsizeField(writer, "activeToolCount", self.context.active_tool_count, true);
        try writer.writeAll("}");
    }

    fn writeMessagesResult(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !void {
        var context = try self.context.session.session_manager.buildSessionContext(allocator);
        defer context.deinit(allocator);

        try writer.writeAll("{\"messages\":[");
        for (context.messages, 0..) |message, index| {
            if (index > 0) try writer.writeAll(",");
            try writeMessageSummary(allocator, writer, message);
        }
        try writer.writeAll("]}");
    }
};

pub const NavigationKind = enum {
    navigation,
    popup,
};

pub const SecurityDecision = union(enum) {
    allow,
    deny: []const u8,
};

pub fn isTrustedBridgeOrigin(origin: []const u8, asset_root: []const u8) bool {
    if (std.mem.eql(u8, origin, trusted_bundle_origin)) return true;
    return isTrustedFileUrl(origin, asset_root);
}

pub fn authorizeNavigation(url: []const u8, asset_root: []const u8, kind: NavigationKind) SecurityDecision {
    if (kind == .popup) {
        return .{ .deny = "WebView popups are disabled and cannot receive bridge access" };
    }
    if (isTrustedFileUrl(url, asset_root)) return .allow;
    return .{ .deny = "WebView navigation is restricted to bundled local assets" };
}

pub fn resolveAssetRequest(
    allocator: std.mem.Allocator,
    asset_root: []const u8,
    request_path: []const u8,
) ![]u8 {
    if (request_path.len == 0 or std.fs.path.isAbsolute(request_path)) return error.AssetPathDenied;
    var parts = std.mem.splitScalar(u8, request_path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
            return error.AssetPathDenied;
        }
    }

    const joined = try std.fs.path.join(allocator, &.{ asset_root, request_path });
    defer allocator.free(joined);

    const root_real = try realpathAlloc(allocator, asset_root);
    errdefer allocator.free(root_real);
    const candidate_real = try realpathAlloc(allocator, joined);
    errdefer allocator.free(candidate_real);

    if (!ai.shared.sandbox.isPathWithinSandbox(root_real, candidate_real)) {
        return error.AssetPathDenied;
    }
    allocator.free(root_real);
    return candidate_real;
}

fn lookupCommand(command_name: []const u8) ?CommandSpec {
    for (command_table) |spec| {
        if (std.mem.eql(u8, spec.name, command_name)) return spec;
    }
    return null;
}

fn payloadShapeAllowed(command: Command, payload: ?std.json.Value) bool {
    const value = payload orelse return command != .prompt;
    if (value == .null) return command != .prompt;
    if (value != .object) return false;
    return switch (command) {
        .get_state, .get_messages, .abort => true,
        .prompt => value.object.get("text") != null and value.object.get("text").? == .string,
    };
}

fn validateCommandPayloadBounds(
    command: Command,
    payload: ?std.json.Value,
    limits: Limits,
) error{PromptTooLarge}!void {
    if (command != .prompt) return;
    const value = payload orelse return;
    const text = value.object.get("text").?.string;
    if (text.len > limits.max_prompt_bytes) return error.PromptTooLarge;
}

fn validateValueBounds(value: std.json.Value, limits: Limits, depth: usize) error{ PayloadTooDeep, StringTooLong }!void {
    if (depth > limits.max_depth) return error.PayloadTooDeep;
    switch (value) {
        .string => |text| if (text.len > limits.max_string_bytes) return error.StringTooLong,
        .number_string => |text| if (text.len > limits.max_string_bytes) return error.StringTooLong,
        .array => |array| {
            for (array.items) |item| try validateValueBounds(item, limits, depth + 1);
        },
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (entry.key_ptr.*.len > limits.max_string_bytes) return error.StringTooLong;
                try validateValueBounds(entry.value_ptr.*, limits, depth + 1);
            }
        },
        else => {},
    }
}

fn getObjectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn writeErrorResponseAlloc(
    allocator: std.mem.Allocator,
    request_id: ?[]const u8,
    code: []const u8,
    message: []const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    try writer.writer.writeAll("{\"id\":");
    if (request_id) |id| {
        try writeJsonString(allocator, &writer.writer, id);
    } else {
        try writer.writer.writeAll("null");
    }
    try writer.writer.writeAll(",\"ok\":false,\"error\":{\"code\":");
    try writeJsonString(allocator, &writer.writer, code);
    try writer.writer.writeAll(",\"message\":");
    if (ai.shared.string_utils.isSensitiveDiagnosticString(message)) {
        try writeJsonString(allocator, &writer.writer, "[REDACTED]");
    } else {
        try writeJsonString(allocator, &writer.writer, message);
    }
    try writer.writer.writeAll("}}");
    return try writer.toOwnedSlice();
}

fn writePromptResult(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    payload: std.json.Value,
) !void {
    const text = payload.object.get("text").?.string;
    try writer.writeAll("{\"status\":\"accepted_by_bridge\",\"queued\":false,\"implemented\":false,\"textLength\":");
    try writer.print("{d}", .{text.len});
    try writer.writeAll(",\"message\":");
    try writeJsonString(allocator, writer, "Prompt command is exposed but agent execution is implemented by the chat milestone");
    try writer.writeAll("}");
}

fn writeMessageSummary(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: ai.Message,
) !void {
    try writer.writeAll("{\"role\":");
    switch (message) {
        .user => |user| {
            try writeJsonString(allocator, writer, "user");
            try writer.writeAll(",\"timestamp\":");
            try writer.print("{d}", .{user.timestamp});
            try writer.writeAll(",\"text\":");
            try writeJsonString(allocator, writer, firstTextContent(user.content) orelse "");
        },
        .assistant => |assistant| {
            try writeJsonString(allocator, writer, "assistant");
            try writer.writeAll(",\"timestamp\":");
            try writer.print("{d}", .{assistant.timestamp});
            try writer.writeAll(",\"text\":");
            try writeJsonString(allocator, writer, firstTextContent(assistant.content) orelse "");
            try writer.writeAll(",\"stopReason\":");
            try writeJsonString(allocator, writer, @tagName(assistant.stop_reason));
        },
        .tool_result => |tool_result| {
            try writeJsonString(allocator, writer, "toolResult");
            try writer.writeAll(",\"timestamp\":");
            try writer.print("{d}", .{tool_result.timestamp});
            try writer.writeAll(",\"text\":");
            try writeJsonString(allocator, writer, firstTextContent(tool_result.content) orelse "");
            try writer.writeAll(",\"isError\":");
            try writer.writeAll(if (tool_result.is_error) "true" else "false");
        },
    }
    try writer.writeAll("}");
}

fn firstTextContent(blocks: []const ai.ContentBlock) ?[]const u8 {
    for (blocks) |block| {
        if (block == .text) return block.text.text;
    }
    return null;
}

fn writeStringField(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    name: []const u8,
    value: []const u8,
    comma: bool,
) !void {
    if (comma) try writer.writeAll(",");
    try writeJsonString(allocator, writer, name);
    try writer.writeAll(":");
    try writeJsonString(allocator, writer, value);
}

fn writeBoolField(
    writer: *std.Io.Writer,
    name: []const u8,
    value: bool,
    comma: bool,
) !void {
    if (comma) try writer.writeAll(",");
    try writer.print("\"{s}\":{s}", .{ name, if (value) "true" else "false" });
}

fn writeUsizeField(
    writer: *std.Io.Writer,
    name: []const u8,
    value: usize,
    comma: bool,
) !void {
    if (comma) try writer.writeAll(",");
    try writer.print("\"{s}\":{d}", .{ name, value });
}

fn writeJsonString(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    value: []const u8,
) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = value }, .{});
    defer allocator.free(encoded);
    try writer.writeAll(encoded);
}

fn isTrustedFileUrl(url: []const u8, asset_root: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "file://")) return false;
    const path = url["file://".len..];
    if (path.len == 0 or
        std.mem.indexOfScalar(u8, path, '%') != null or
        std.mem.indexOfScalar(u8, path, '?') != null or
        std.mem.indexOfScalar(u8, path, '#') != null)
    {
        return false;
    }
    return ai.shared.sandbox.isPathWithinSandbox(asset_root, path);
}

fn realpathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = std.c.realpath(z_path.ptr, &buffer) orelse return error.FileNotFound;
    return try allocator.dupe(u8, std.mem.span(resolved));
}

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
    return try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/pi-webview-assets",
        .model = testModel(),
    });
}

fn testBridge(session: *const session_mod.AgentSession) BridgeHost {
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
        .selected_tools = .{ .disable_all = true },
        .active_tool_count = 0,
        .session = session,
    });
}

test "bridge command table exposes only approved skeleton commands" {
    try std.testing.expectEqual(@as(usize, 4), command_table.len);
    try std.testing.expectEqualStrings("get_state", command_table[0].name);
    try std.testing.expectEqualStrings("get_messages", command_table[1].name);
    try std.testing.expectEqualStrings("prompt", command_table[2].name);
    try std.testing.expectEqualStrings("abort", command_table[3].name);
}

test "bridge dispatches every approved skeleton command through command table" {
    const allocator = std.testing.allocator;
    var session = try testSession(allocator);
    defer session.deinit();
    var bridge = testBridge(&session);
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
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"status\":\"accepted_by_bridge\"") != null);

    const abort = try bridge.handleRequestJson(allocator, "{\"id\":\"abort\",\"command\":\"abort\"}", trusted_bundle_origin);
    defer allocator.free(abort);
    try std.testing.expect(std.mem.indexOf(u8, abort, "\"id\":\"abort\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, abort, "\"status\":\"not_running\"") != null);

    try std.testing.expectEqual(@as(usize, 1), counters.get_state);
    try std.testing.expectEqual(@as(usize, 1), counters.get_messages);
    try std.testing.expectEqual(@as(usize, 1), counters.prompt);
    try std.testing.expectEqual(@as(usize, 1), counters.abort);
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
    try std.testing.expectEqual(@as(usize, 0), counters.total());
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

    try std.testing.expectEqual(@as(usize, 0), counters.total());
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
    try std.testing.expectEqual(@as(usize, 0), counters.total());
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
    try std.testing.expectEqual(@as(usize, 0), counters.total());
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
    try std.testing.expectEqual(@as(usize, 0), counters.total());
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
    try std.testing.expectEqual(@as(usize, 0), counters.total());
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
