const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const json_event_wire = @import("json_event_wire.zig");
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
    session: *session_mod.AgentSession,
    initial_prompt: ?[]const u8 = null,
    initial_messages: []const []const u8 = &.{},
    initial_images_count: usize = 0,
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
    active_turn_id: ?[]const u8 = null,
    active_generation: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    close_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    next_turn_index: usize = 0,

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
            .prompt => try self.writePromptResult(allocator, &writer.writer, payload.?),
            .abort => try self.writeAbortResult(&writer.writer),
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
        try writeBoolField(writer, "busy", self.active_generation.load(.seq_cst), true);
        if (self.context.initial_prompt != null or self.context.initial_messages.len > 0 or self.context.initial_images_count > 0) {
            try writer.writeAll(",\"initialInput\":{");
            try writeOptionalStringField(allocator, writer, "prompt", self.context.initial_prompt, false);
            try writeStringArrayField(allocator, writer, "messages", self.context.initial_messages, true);
            try writeUsizeField(writer, "imagesCount", self.context.initial_images_count, true);
            try writer.writeAll("}");
        }
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

    fn writePromptResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        payload: std.json.Value,
    ) !void {
        const text = payload.object.get("text").?.string;
        if (self.active_generation.load(.seq_cst)) {
            try writer.writeAll("{\"status\":\"busy\",\"accepted\":false,\"queued\":false,\"message\":");
            try writeJsonString(allocator, writer, "Agent is already processing a WebView prompt");
            try writer.writeAll("}");
            return;
        }

        const turn_id = try std.fmt.allocPrint(allocator, "webview-turn-{d}", .{self.next_turn_index});
        defer allocator.free(turn_id);
        self.next_turn_index += 1;
        self.active_generation.store(true, .seq_cst);
        self.active_turn_id = turn_id;
        defer {
            self.active_turn_id = null;
            self.active_generation.store(false, .seq_cst);
            self.close_requested.store(false, .seq_cst);
        }

        var capture = PromptEventCapture.init(
            allocator,
            self.context.session.session_manager.getSessionId(),
            turn_id,
        );
        defer capture.deinit();

        const subscriber = agent.AgentSubscriber{
            .context = &capture,
            .callback = handleWebViewPromptEvent,
        };
        try self.context.session.agent.subscribe(subscriber);
        defer {
            _ = self.context.session.agent.unsubscribe(subscriber);
        }

        var acceptance = PromptAcceptance{};
        const accepted_callback = agent.PromptAcceptedCallback{
            .context = &acceptance,
            .callback = markPromptAccepted,
        };

        const prompt_result = self.context.session.promptWithAcceptedCallback(
            .{ .text = text, .images = &[_]ai.ImageContent{} },
            accepted_callback,
        );
        if (prompt_result) |_| {
            if (!capture.terminal_seen) {
                try capture.appendSyntheticTerminal("success", "prompt completed without an agent_end event");
            }
            try writer.writeAll("{\"status\":");
            try writeJsonString(allocator, writer, statusForTerminalOutcome(capture.terminal_outcome));
            try writer.writeAll(",\"accepted\":");
            try writer.writeAll(if (acceptance.accepted) "true" else "false");
            try writer.writeAll(",\"queued\":false,\"sessionId\":");
            try writeJsonString(allocator, writer, self.context.session.session_manager.getSessionId());
            try writer.writeAll(",\"turnId\":");
            try writeJsonString(allocator, writer, turn_id);
            try writer.writeAll(",\"terminalOutcome\":");
            try writeJsonString(allocator, writer, capture.terminal_outcome);
            if (capture.terminal_error_message) |message| {
                try writer.writeAll(",\"error\":");
                try writeJsonString(allocator, writer, message);
            }
            try writer.writeAll(",\"events\":[");
            try capture.writeFrames(writer);
            try writer.writeAll("]}");
        } else |err| {
            if (!capture.terminal_seen) {
                try capture.appendSyntheticTerminal("setup_failure", @errorName(err));
            }
            try writer.writeAll("{\"status\":\"failed\",\"accepted\":");
            try writer.writeAll(if (acceptance.accepted) "true" else "false");
            try writer.writeAll(",\"queued\":false,\"sessionId\":");
            try writeJsonString(allocator, writer, self.context.session.session_manager.getSessionId());
            try writer.writeAll(",\"turnId\":");
            try writeJsonString(allocator, writer, turn_id);
            try writer.writeAll(",\"terminalOutcome\":\"setup_failure\",\"error\":");
            try writeJsonString(allocator, writer, @errorName(err));
            try writer.writeAll(",\"events\":[");
            try capture.writeFrames(writer);
            try writer.writeAll("]}");
        }
    }

    fn writeAbortResult(
        self: *BridgeHost,
        writer: *std.Io.Writer,
    ) !void {
        if (!self.active_generation.load(.seq_cst)) {
            try writer.writeAll("{\"status\":\"not_running\",\"aborted\":false}");
            return;
        }
        self.context.session.abortRetry();
        self.context.session.agent.abort();
        try writer.writeAll("{\"status\":\"abort_requested\",\"aborted\":true}");
    }

    pub fn closeAndAbortActiveWork(self: *BridgeHost) bool {
        self.close_requested.store(true, .seq_cst);
        if (!self.active_generation.load(.seq_cst)) return false;
        self.context.session.abortRetry();
        self.context.session.agent.abort();
        return true;
    }
};

fn statusForTerminalOutcome(outcome: []const u8) []const u8 {
    if (std.mem.eql(u8, outcome, "success")) return "completed";
    if (std.mem.eql(u8, outcome, "abort")) return "aborted";
    if (std.mem.eql(u8, outcome, "provider_error")) return "failed";
    if (std.mem.eql(u8, outcome, "setup_failure")) return "failed";
    if (std.mem.eql(u8, outcome, "window_closed")) return "aborted";
    return "failed";
}

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

fn writeOptionalStringField(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    name: []const u8,
    value: ?[]const u8,
    comma: bool,
) !void {
    if (comma) try writer.writeAll(",");
    try writeJsonString(allocator, writer, name);
    try writer.writeAll(":");
    if (value) |text| {
        try writeJsonString(allocator, writer, text);
    } else {
        try writer.writeAll("null");
    }
}

fn writeStringArrayField(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    name: []const u8,
    values: []const []const u8,
    comma: bool,
) !void {
    if (comma) try writer.writeAll(",");
    try writeJsonString(allocator, writer, name);
    try writer.writeAll(":[");
    for (values, 0..) |value, index| {
        if (index > 0) try writer.writeAll(",");
        try writeJsonString(allocator, writer, value);
    }
    try writer.writeAll("]");
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
    return try testSessionWithModel(allocator, testModel());
}

fn testSessionWithModel(allocator: std.mem.Allocator, model: ai.Model) !session_mod.AgentSession {
    return try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/pi-webview-assets",
        .model = model,
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
        .selected_tools = .{ .disable_all = true },
        .active_tool_count = 0,
        .session = session,
    });
}

const PromptAcceptance = struct {
    accepted: bool = false,
};

fn markPromptAccepted(context: ?*anyopaque) !void {
    const acceptance: *PromptAcceptance = @ptrCast(@alignCast(context.?));
    acceptance.accepted = true;
}

const PromptEventCapture = struct {
    allocator: std.mem.Allocator,
    session_id: []const u8,
    turn_id: []const u8,
    frames: std.ArrayList([]u8) = .empty,
    next_sequence: usize = 1,
    terminal_seen: bool = false,
    terminal_outcome: []const u8 = "success",
    terminal_error_message: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator, session_id: []const u8, turn_id: []const u8) PromptEventCapture {
        return .{
            .allocator = allocator,
            .session_id = session_id,
            .turn_id = turn_id,
        };
    }

    fn deinit(self: *PromptEventCapture) void {
        for (self.frames.items) |frame| self.allocator.free(frame);
        self.frames.deinit(self.allocator);
        if (self.terminal_error_message) |message| self.allocator.free(message);
        self.* = undefined;
    }

    fn appendEvent(self: *PromptEventCapture, event: agent.AgentEvent) !void {
        if (self.terminal_seen) return;
        try self.observeTerminalOutcome(event);
        const terminal = event.event_type == .agent_end;
        if (terminal) self.terminal_seen = true;

        const event_json = try json_event_wire.stringifyAgentEventLine(self.allocator, event);
        defer self.allocator.free(event_json);

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        try writer.writer.writeAll("{\"sessionId\":");
        try writeJsonString(self.allocator, &writer.writer, self.session_id);
        try writer.writer.writeAll(",\"turnId\":");
        try writeJsonString(self.allocator, &writer.writer, self.turn_id);
        try writer.writer.print(",\"sequence\":{d},\"type\":", .{self.next_sequence});
        try writeJsonString(self.allocator, &writer.writer, @tagName(event.event_type));
        try writer.writer.writeAll(",\"terminal\":");
        try writer.writer.writeAll(if (terminal) "true" else "false");
        if (terminal) {
            try writer.writer.writeAll(",\"terminalOutcome\":");
            try writeJsonString(self.allocator, &writer.writer, self.terminal_outcome);
            if (self.terminal_error_message) |message| {
                try writer.writer.writeAll(",\"error\":");
                try writeJsonString(self.allocator, &writer.writer, message);
            }
        }
        try writer.writer.writeAll(",\"event\":");
        try writer.writer.writeAll(event_json);
        try writer.writer.writeAll("}");
        self.next_sequence += 1;
        try self.frames.append(self.allocator, try writer.toOwnedSlice());
    }

    fn appendSyntheticTerminal(self: *PromptEventCapture, outcome: []const u8, message: []const u8) !void {
        if (self.terminal_seen) return;
        self.terminal_seen = true;
        try self.setTerminalOutcome(outcome, message);
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        try writer.writer.writeAll("{\"sessionId\":");
        try writeJsonString(self.allocator, &writer.writer, self.session_id);
        try writer.writer.writeAll(",\"turnId\":");
        try writeJsonString(self.allocator, &writer.writer, self.turn_id);
        try writer.writer.print(",\"sequence\":{d},\"type\":\"terminal\",\"terminal\":true,\"terminalOutcome\":", .{self.next_sequence});
        try writeJsonString(self.allocator, &writer.writer, outcome);
        try writer.writer.writeAll(",\"event\":{\"type\":\"terminal\",\"message\":");
        try writeJsonString(self.allocator, &writer.writer, message);
        try writer.writer.writeAll("}}");
        self.next_sequence += 1;
        try self.frames.append(self.allocator, try writer.toOwnedSlice());
    }

    fn observeTerminalOutcome(self: *PromptEventCapture, event: agent.AgentEvent) !void {
        const message = event.message orelse return;
        if (message != .assistant) return;
        const assistant = message.assistant;
        switch (assistant.stop_reason) {
            .aborted => try self.setTerminalOutcome("abort", assistant.error_message orelse "Request was aborted"),
            .error_reason => try self.setTerminalOutcome("provider_error", assistant.error_message orelse "Provider error"),
            else => {},
        }
    }

    fn setTerminalOutcome(self: *PromptEventCapture, outcome: []const u8, message: ?[]const u8) !void {
        self.terminal_outcome = outcome;
        if (self.terminal_error_message) |old| {
            self.allocator.free(old);
            self.terminal_error_message = null;
        }
        if (message) |text| {
            self.terminal_error_message = try self.allocator.dupe(u8, text);
        }
    }

    fn writeFrames(self: *const PromptEventCapture, writer: *std.Io.Writer) !void {
        for (self.frames.items, 0..) |frame, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.writeAll(frame);
        }
    }
};

fn handleWebViewPromptEvent(context: ?*anyopaque, event: agent.AgentEvent) !void {
    const capture: *PromptEventCapture = @ptrCast(@alignCast(context.?));
    try capture.appendEvent(event);
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
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"status\":") != null);

    const abort = try bridge.handleRequestJson(allocator, "{\"id\":\"abort\",\"command\":\"abort\"}", trusted_bundle_origin);
    defer allocator.free(abort);
    try std.testing.expect(std.mem.indexOf(u8, abort, "\"id\":\"abort\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, abort, "\"status\":\"not_running\"") != null);

    try std.testing.expectEqual(@as(usize, 1), counters.get_state);
    try std.testing.expectEqual(@as(usize, 1), counters.get_messages);
    try std.testing.expectEqual(@as(usize, 1), counters.prompt);
    try std.testing.expectEqual(@as(usize, 1), counters.abort);
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
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"status\":\"completed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"turnId\":\"webview-turn-0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"sequence\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"terminal\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"terminalOutcome\":\"success\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "webview answer") != null);

    const after = try bridge.handleRequestJson(allocator, "{\"id\":\"after\",\"command\":\"get_messages\"}", trusted_bundle_origin);
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "hello from webview") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "webview answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "webview-turn-0") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"sequence\"") == null);
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
    bridge.context.model = registration.getModel();

    const prompt = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"prompt-error\",\"command\":\"prompt\",\"payload\":{\"text\":\"trigger error\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"terminalOutcome\":\"provider_error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "faux provider failed safely") != null);

    const state = try bridge.handleRequestJson(allocator, "{\"id\":\"after-error\",\"command\":\"get_state\"}", trusted_bundle_origin);
    defer allocator.free(state);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"id\":\"after-error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"busy\":false") != null);
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
    const slow_blocks = [_]faux.FauxContentBlock{faux.fauxText(
        "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz",
    )};
    const retry_blocks = [_]faux.FauxContentBlock{faux.fauxText("retry succeeded")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(slow_blocks[0..], .{}) },
        .{ .message = faux.fauxAssistantMessage(retry_blocks[0..], .{}) },
    });

    var session = try testSessionWithModel(allocator, registration.getModel());
    defer session.deinit();
    var bridge = testBridge(&session);
    bridge.context.model = registration.getModel();

    const ThreadResult = struct {
        response: ?[]u8 = null,
        err: ?anyerror = null,

        fn run(host: *BridgeHost, result: *@This()) void {
            result.response = host.handleRequestJson(
                std.heap.c_allocator,
                "{\"id\":\"abort-prompt\",\"command\":\"prompt\",\"payload\":{\"text\":\"abort me\"}}",
                trusted_bundle_origin,
            ) catch |err| {
                result.err = err;
                return;
            };
        }
    };

    var thread_result = ThreadResult{};
    const prompt_thread = try std.Thread.spawn(.{}, ThreadResult.run, .{ &bridge, &thread_result });
    while (!bridge.active_generation.load(.seq_cst)) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    std.Io.sleep(std.testing.io, .fromMilliseconds(250), .awake) catch {};

    const abort = try bridge.handleRequestJson(allocator, "{\"id\":\"abort-active\",\"command\":\"abort\"}", trusted_bundle_origin);
    defer allocator.free(abort);
    try std.testing.expect(std.mem.indexOf(u8, abort, "\"status\":\"abort_requested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, abort, "\"aborted\":true") != null);

    prompt_thread.join();
    if (thread_result.err) |err| return err;
    const aborted_prompt = thread_result.response.?;
    defer std.heap.c_allocator.free(aborted_prompt);
    try std.testing.expect(std.mem.indexOf(u8, aborted_prompt, "\"status\":\"aborted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aborted_prompt, "\"terminalOutcome\":\"abort\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aborted_prompt, "\"terminal\":true") != null);
    try std.testing.expect(!bridge.active_generation.load(.seq_cst));

    var capture = PromptEventCapture.init(allocator, "session", "turn");
    defer capture.deinit();
    try capture.appendSyntheticTerminal("abort", "Request was aborted");
    try capture.appendEvent(.{ .event_type = .message_update });
    try std.testing.expectEqual(@as(usize, 1), capture.frames.items.len);

    const retry = try bridge.handleRequestJson(
        allocator,
        "{\"id\":\"retry-prompt\",\"command\":\"prompt\",\"payload\":{\"text\":\"try again\"}}",
        trusted_bundle_origin,
    );
    defer allocator.free(retry);
    try std.testing.expect(std.mem.indexOf(u8, retry, "\"status\":\"completed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, retry, "\"terminalOutcome\":\"success\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, retry, "retry succeeded") != null);
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
