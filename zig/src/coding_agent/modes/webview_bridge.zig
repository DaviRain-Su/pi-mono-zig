const std = @import("std");
const builtin = @import("builtin");
const ai = @import("ai");
const agent = @import("agent");
const json_format = @import("../shared/json_format.zig");
const json_event_wire = @import("json_event_wire.zig");
const provider_config = @import("../providers/provider_config.zig");
const session_mod = @import("../sessions/session.zig");
const session_manager_mod = @import("../sessions/session_manager.zig");
const tool_selection = @import("../tool_selection.zig");

const writeJsonString = json_format.writeJsonString;

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
    get_events,
    model_select,
    new_session,
    resume_session,
    switch_session,
    auth_status,
    start_auth,
    save_api_key,
    remove_auth,
};

pub const Permission = enum {
    skeleton_chat,
    model_selection,
    session_mutation,
    auth_mutation,
};

pub const BridgePermissions = struct {
    skeleton_chat: bool = true,
    model_selection: bool = false,
    session_mutation: bool = false,
    auth_mutation: bool = false,

    fn allows(self: BridgePermissions, permission: Permission) bool {
        return switch (permission) {
            .skeleton_chat => self.skeleton_chat,
            .model_selection => self.model_selection,
            .session_mutation => self.session_mutation,
            .auth_mutation => self.auth_mutation,
        };
    }
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
    .{ .name = "get_events", .command = .get_events, .permission = .skeleton_chat },
    .{ .name = "model_select", .command = .model_select, .permission = .model_selection },
    .{ .name = "new_session", .command = .new_session, .permission = .session_mutation },
    .{ .name = "resume_session", .command = .resume_session, .permission = .session_mutation },
    .{ .name = "switch_session", .command = .switch_session, .permission = .session_mutation },
    .{ .name = "auth_status", .command = .auth_status, .permission = .skeleton_chat },
    .{ .name = "start_auth", .command = .start_auth, .permission = .auth_mutation },
    .{ .name = "save_api_key", .command = .save_api_key, .permission = .auth_mutation },
    .{ .name = "remove_auth", .command = .remove_auth, .permission = .auth_mutation },
};

pub const BridgeContext = struct {
    cwd: []const u8,
    trusted_asset_root: []const u8,
    provider: []const u8,
    model: ai.Model,
    no_session: bool,
    api_key_present: bool,
    auth_status: provider_config.ProviderAuthStatus,
    available_models: []const provider_config.AvailableModel = &.{},
    selected_tools: tool_selection.ToolSelection,
    active_tool_count: usize,
    session: *session_mod.AgentSession,
    permissions: BridgePermissions = .{},
    initial_prompt: ?[]const u8 = null,
    initial_messages: []const []const u8 = &.{},
    initial_images_count: usize = 0,
};

pub const DispatchCounters = struct {
    get_state: usize = 0,
    get_messages: usize = 0,
    prompt: usize = 0,
    abort: usize = 0,
    get_events: usize = 0,
    model_select: usize = 0,
    new_session: usize = 0,
    resume_session: usize = 0,
    switch_session: usize = 0,
    auth_status: usize = 0,
    start_auth: usize = 0,
    save_api_key: usize = 0,
    remove_auth: usize = 0,

    fn increment(self: *DispatchCounters, command: Command) void {
        switch (command) {
            .get_state => self.get_state += 1,
            .get_messages => self.get_messages += 1,
            .prompt => self.prompt += 1,
            .abort => self.abort += 1,
            .get_events => self.get_events += 1,
            .model_select => self.model_select += 1,
            .new_session => self.new_session += 1,
            .resume_session => self.resume_session += 1,
            .switch_session => self.switch_session += 1,
            .auth_status => self.auth_status += 1,
            .start_auth => self.start_auth += 1,
            .save_api_key => self.save_api_key += 1,
            .remove_auth => self.remove_auth += 1,
        }
    }

    fn total(self: DispatchCounters) usize {
        return self.get_state +
            self.get_messages +
            self.prompt +
            self.abort +
            self.get_events +
            self.model_select +
            self.new_session +
            self.resume_session +
            self.switch_session +
            self.auth_status +
            self.start_auth +
            self.save_api_key +
            self.remove_auth;
    }
};

const QueuedEventFrame = struct {
    sequence: usize,
    terminal: bool,
    bytes: []u8,
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
    event_mutex: std.Io.Mutex = .init,
    event_frames: std.ArrayList(QueuedEventFrame) = .empty,
    terminal_seen: bool = false,
    terminal_outcome: []const u8 = "success",
    terminal_error_message: ?[]u8 = null,
    worker_thread: ?std.Thread = null,
    worker_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    worker_allocator: std.mem.Allocator = std.heap.c_allocator,

    pub fn init(context: BridgeContext) BridgeHost {
        return .{ .context = context };
    }

    pub fn deinit(self: *BridgeHost) void {
        _ = self.closeAndAbortActiveWork();
        self.joinWorkerIfPresent();
        self.event_mutex.lockUncancelable(self.context.session.io);
        defer self.event_mutex.unlock(self.context.session.io);
        self.clearPromptStateLocked();
    }

    fn joinCompletedWorker(self: *BridgeHost) void {
        if (!self.worker_done.load(.seq_cst)) return;
        self.joinWorkerIfPresent();
    }

    fn joinWorkerIfPresent(self: *BridgeHost) void {
        if (self.worker_thread) |thread| {
            thread.join();
            self.worker_thread = null;
            self.worker_done.store(true, .seq_cst);
        }
    }

    fn clearPromptStateLocked(self: *BridgeHost) void {
        for (self.event_frames.items) |frame| {
            self.worker_allocator.free(frame.bytes);
        }
        self.event_frames.clearAndFree(self.worker_allocator);
        if (self.active_turn_id) |turn_id| {
            self.worker_allocator.free(@constCast(turn_id));
            self.active_turn_id = null;
        }
        if (self.terminal_error_message) |message| {
            self.worker_allocator.free(message);
            self.terminal_error_message = null;
        }
        self.terminal_seen = false;
        self.terminal_outcome = "success";
        self.close_requested.store(false, .seq_cst);
    }

    fn enqueueEventFrame(
        self: *BridgeHost,
        frame: []u8,
        sequence: usize,
        terminal: bool,
        terminal_outcome: []const u8,
        terminal_error_message: ?[]const u8,
    ) !void {
        self.event_mutex.lockUncancelable(self.context.session.io);
        defer self.event_mutex.unlock(self.context.session.io);
        errdefer self.worker_allocator.free(frame);
        if (self.terminal_seen) {
            self.worker_allocator.free(frame);
            return;
        }
        try self.event_frames.append(self.worker_allocator, .{
            .sequence = sequence,
            .terminal = terminal,
            .bytes = frame,
        });
        if (terminal and !self.terminal_seen) {
            self.terminal_seen = true;
            self.terminal_outcome = terminal_outcome;
            if (terminal_error_message) |message| {
                self.terminal_error_message = try self.worker_allocator.dupe(u8, message);
            }
        }
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
        self.validateCommandPayloadSemantics(spec.command, payload) catch |err| switch (err) {
            error.InvalidSessionTarget => return writeErrorResponseAlloc(
                allocator,
                request_id,
                "invalid_payload",
                "Bridge session target is invalid or missing",
            ),
            error.InvalidModelSelection => return writeErrorResponseAlloc(
                allocator,
                request_id,
                "invalid_payload",
                "Bridge provider/model selection is invalid or unsupported",
            ),
        };

        if (!self.context.permissions.allows(spec.permission)) {
            return writeErrorResponseAlloc(
                allocator,
                request_id,
                "permission_denied",
                permissionDeniedMessage(spec.permission),
            );
        }

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
            .get_events => try self.writeEventsResult(allocator, &writer.writer, payload),
            .model_select => try self.writeModelSelectResult(allocator, &writer.writer, payload.?),
            .new_session, .resume_session, .switch_session => try self.writeSessionMutationGatedResult(allocator, &writer.writer, command),
            .auth_status => try self.writeAuthStatusResult(allocator, &writer.writer),
            .start_auth, .save_api_key, .remove_auth => try self.writeAuthMutationGatedResult(allocator, &writer.writer, command),
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
        try writeStringField(allocator, writer, "modelProvider", self.context.model.provider, true);
        try writeStringField(allocator, writer, "modelName", self.context.model.name, true);
        try writeStringField(allocator, writer, "modelApi", self.context.model.api, true);
        try writer.writeAll(",\"modelSelection\":");
        try self.writeModelSelectionState(allocator, writer);
        try writeStringField(allocator, writer, "sessionId", self.context.session.session_manager.getSessionId(), true);
        try writeBoolField(writer, "noSession", self.context.no_session, true);
        try writeBoolField(writer, "apiKeyPresent", self.context.api_key_present, true);
        try writer.writeAll(",\"auth\":");
        try self.writeAuthStatusResult(allocator, writer);
        try writeBoolField(writer, "toolsDisabled", self.context.selected_tools.disable_all, true);
        try writeUsizeField(writer, "activeToolCount", self.context.active_tool_count, true);
        try writeBoolField(writer, "busy", self.active_generation.load(.seq_cst), true);
        if (self.active_turn_id) |turn_id| {
            try writeStringField(allocator, writer, "activeTurnId", turn_id, true);
        }
        if (self.context.initial_prompt != null or self.context.initial_messages.len > 0 or self.context.initial_images_count > 0) {
            try writer.writeAll(",\"initialInput\":{");
            try writeOptionalStringField(allocator, writer, "prompt", self.context.initial_prompt, false);
            try writeStringArrayField(allocator, writer, "messages", self.context.initial_messages, true);
            try writeUsizeField(writer, "imagesCount", self.context.initial_images_count, true);
            try writer.writeAll("}");
        }
        try writer.writeAll("}");
    }

    fn writeAuthStatusResult(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !void {
        try writer.writeAll("{");
        try writeStringField(allocator, writer, "provider", self.context.provider, false);
        try writeStringField(allocator, writer, "displayName", provider_config.providerDisplayName(self.context.provider), true);
        try writeStringField(allocator, writer, "status", @tagName(self.context.auth_status), true);
        try writeStringField(allocator, writer, "statusLabel", provider_config.providerAuthStatusLabel(self.context.auth_status), true);
        try writeBoolField(writer, "apiKeyPresent", self.context.api_key_present, true);
        try writeBoolField(writer, "required", self.authRequired(), true);
        try writeBoolField(writer, "promptEnabled", !self.authRequired(), true);
        try writer.writeAll("}");
    }

    fn writeModelSelectionState(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !void {
        try writer.writeAll("{\"status\":\"gated\",\"permissionRequired\":true,\"activeProvider\":");
        try writeJsonString(allocator, writer, self.context.provider);
        try writer.writeAll(",\"activeModel\":");
        try writeJsonString(allocator, writer, self.context.model.id);
        try writer.writeAll(",\"availableModels\":[");
        for (self.context.available_models, 0..) |model, index| {
            if (index > 0) try writer.writeAll(",");
            try self.writeAvailableModelState(allocator, writer, model);
        }
        try writer.writeAll("]}");
    }

    fn writeAvailableModelState(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        model: provider_config.AvailableModel,
    ) !void {
        try writer.writeAll("{");
        try writeStringField(allocator, writer, "provider", model.provider, false);
        try writeStringField(allocator, writer, "model", model.model_id, true);
        try writeStringField(allocator, writer, "displayName", model.display_name, true);
        try writeBoolField(writer, "available", model.available, true);
        try writeStringField(allocator, writer, "authStatus", @tagName(model.auth_status), true);
        try writeStringField(allocator, writer, "authStatusLabel", provider_config.providerAuthStatusLabel(model.auth_status), true);
        try writeBoolField(
            writer,
            "current",
            std.mem.eql(u8, model.provider, self.context.model.provider) and
                std.mem.eql(u8, model.model_id, self.context.model.id),
            true,
        );
        try writeBoolField(writer, "reasoning", model.reasoning, true);
        try writeBoolField(writer, "toolCalling", model.tool_calling, true);
        try writeBoolField(writer, "loaded", model.loaded, true);
        try writeBoolField(writer, "supportsImages", model.supports_images, true);
        try writeUsizeField(writer, "contextWindow", model.context_window, true);
        try writeUsizeField(writer, "maxTokens", model.max_tokens, true);
        try writer.writeAll("}");
    }

    fn writeModelSelectResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        payload: std.json.Value,
    ) !void {
        const provider = payload.object.get("provider").?.string;
        const model = payload.object.get("model").?.string;
        if (self.active_generation.load(.seq_cst)) {
            try writer.writeAll("{\"status\":\"busy\",\"accepted\":false,\"provider\":");
            try writeJsonString(allocator, writer, self.context.provider);
            try writer.writeAll(",\"model\":");
            try writeJsonString(allocator, writer, self.context.model.id);
            try writer.writeAll(",\"message\":");
            try writeJsonString(allocator, writer, "WebView model selection is blocked while a prompt is active");
            try writer.writeAll("}");
            return;
        }

        try writer.writeAll("{\"status\":\"gated\",\"accepted\":false,\"provider\":");
        try writeJsonString(allocator, writer, provider);
        try writer.writeAll(",\"model\":");
        try writeJsonString(allocator, writer, model);
        try writer.writeAll(",\"message\":");
        try writeJsonString(allocator, writer, "WebView model selection is permissioned but not implemented in this milestone");
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
        self.joinCompletedWorker();
        const text = payload.object.get("text").?.string;
        if (self.authRequired()) {
            try writer.writeAll("{\"status\":\"auth_required\",\"accepted\":false,\"queued\":false,\"message\":");
            try writeJsonString(allocator, writer, "Provider credentials are required before WebView prompts can run");
            try writer.writeAll(",\"auth\":");
            try self.writeAuthStatusResult(allocator, writer);
            try writer.writeAll("}");
            return;
        }
        if (self.active_generation.load(.seq_cst)) {
            try writer.writeAll("{\"status\":\"busy\",\"accepted\":false,\"queued\":false,\"message\":");
            try writeJsonString(allocator, writer, "Agent is already processing a WebView prompt");
            try writer.writeAll("}");
            return;
        }

        const turn_id = try std.fmt.allocPrint(self.worker_allocator, "webview-turn-{d}", .{self.next_turn_index});
        errdefer self.worker_allocator.free(turn_id);
        const text_copy = try self.worker_allocator.dupe(u8, text);
        errdefer self.worker_allocator.free(text_copy);
        const session_id = try self.worker_allocator.dupe(u8, self.context.session.session_manager.getSessionId());
        errdefer self.worker_allocator.free(session_id);

        self.event_mutex.lockUncancelable(self.context.session.io);
        self.clearPromptStateLocked();
        self.active_turn_id = turn_id;
        self.event_mutex.unlock(self.context.session.io);

        self.next_turn_index += 1;
        self.active_generation.store(true, .seq_cst);
        self.worker_done.store(false, .seq_cst);

        const runner = try self.worker_allocator.create(AsyncPromptRunner);
        errdefer self.worker_allocator.destroy(runner);
        runner.* = .{
            .allocator = self.worker_allocator,
            .bridge = self,
            .text = text_copy,
            .session_id = session_id,
            .turn_id = turn_id,
        };
        self.worker_thread = std.Thread.spawn(.{}, runAsyncPrompt, .{runner}) catch |err| {
            self.active_generation.store(false, .seq_cst);
            self.worker_done.store(true, .seq_cst);
            self.event_mutex.lockUncancelable(self.context.session.io);
            self.clearPromptStateLocked();
            self.event_mutex.unlock(self.context.session.io);
            return err;
        };

        try writer.writeAll("{\"status\":\"accepted\",\"accepted\":true,\"queued\":false,\"sessionId\":");
        try writeJsonString(allocator, writer, session_id);
        try writer.writeAll(",\"turnId\":");
        try writeJsonString(allocator, writer, turn_id);
        try writer.writeAll(",\"nextSequence\":1,\"events\":[]}");
    }

    fn writeEventsResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        payload: ?std.json.Value,
    ) !void {
        self.joinCompletedWorker();
        const requested_turn_id = getPayloadString(payload, "turnId");
        const after_sequence = getPayloadUsize(payload, "afterSequence") orelse 0;

        self.event_mutex.lockUncancelable(self.context.session.io);
        defer self.event_mutex.unlock(self.context.session.io);

        const active_turn_id = self.active_turn_id;
        try writer.writeAll("{\"status\":");
        if (requested_turn_id) |requested| {
            if (active_turn_id == null or !std.mem.eql(u8, requested, active_turn_id.?)) {
                try writeJsonString(allocator, writer, "stale");
                try writer.writeAll(",\"turnId\":");
                try writeJsonString(allocator, writer, requested);
                try writer.writeAll(",\"active\":false,\"terminal\":true,\"events\":[]}");
                return;
            }
        }

        try writeJsonString(allocator, writer, "ok");
        try writer.writeAll(",\"sessionId\":");
        try writeJsonString(allocator, writer, self.context.session.session_manager.getSessionId());
        try writer.writeAll(",\"turnId\":");
        if (active_turn_id) |turn_id| {
            try writeJsonString(allocator, writer, turn_id);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"active\":");
        try writer.writeAll(if (self.active_generation.load(.seq_cst)) "true" else "false");
        try writer.writeAll(",\"terminal\":");
        try writer.writeAll(if (self.terminal_seen) "true" else "false");
        if (self.terminal_seen) {
            try writer.writeAll(",\"terminalOutcome\":");
            try writeJsonString(allocator, writer, self.terminal_outcome);
            if (self.terminal_error_message) |message| {
                try writer.writeAll(",\"error\":");
                try writeJsonString(allocator, writer, message);
            }
        }
        try writer.writeAll(",\"events\":[");
        var wrote = false;
        for (self.event_frames.items) |frame| {
            if (frame.sequence <= after_sequence) continue;
            if (wrote) try writer.writeAll(",");
            try writer.writeAll(frame.bytes);
            wrote = true;
        }
        try writer.writeAll("]}");
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

    fn writeSessionMutationGatedResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        command: Command,
    ) !void {
        _ = self;
        try writer.writeAll("{\"status\":\"gated\",\"accepted\":false,\"command\":");
        try writeJsonString(allocator, writer, @tagName(command));
        try writer.writeAll(",\"message\":");
        try writeJsonString(allocator, writer, "WebView session mutation commands are permissioned but not implemented in this milestone");
        try writer.writeAll("}");
    }

    fn writeAuthMutationGatedResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        command: Command,
    ) !void {
        try writer.writeAll("{\"status\":\"gated\",\"accepted\":false,\"command\":");
        try writeJsonString(allocator, writer, @tagName(command));
        try writer.writeAll(",\"message\":");
        try writeJsonString(allocator, writer, "WebView auth mutation commands are permissioned but not implemented in this milestone");
        try writer.writeAll(",\"auth\":");
        try self.writeAuthStatusResult(allocator, writer);
        try writer.writeAll("}");
    }

    fn validateCommandPayloadSemantics(
        self: *BridgeHost,
        command: Command,
        payload: ?std.json.Value,
    ) error{ InvalidSessionTarget, InvalidModelSelection }!void {
        switch (command) {
            .model_select => {
                const value = payload orelse return error.InvalidModelSelection;
                const provider_value = value.object.get("provider") orelse return error.InvalidModelSelection;
                const model_value = value.object.get("model") orelse return error.InvalidModelSelection;
                if (provider_value != .string or model_value != .string) return error.InvalidModelSelection;
                if (!isValidModelSelection(self.context.model, provider_value.string, model_value.string)) return error.InvalidModelSelection;
            },
            .new_session => {
                if (payload) |value| {
                    if (value == .object) {
                        if (value.object.get("parentSession")) |parent_session| {
                            if (parent_session != .string or !isValidSessionPath(parent_session.string)) return error.InvalidSessionTarget;
                        }
                    }
                }
            },
            .resume_session, .switch_session => {
                const value = payload orelse return error.InvalidSessionTarget;
                const session_path_value = value.object.get("sessionPath") orelse return error.InvalidSessionTarget;
                if (session_path_value != .string or !isValidSessionPath(session_path_value.string)) return error.InvalidSessionTarget;
                var header = session_manager_mod.readSessionHeader(
                    self.context.session.allocator,
                    self.context.session.io,
                    session_path_value.string,
                ) catch return error.InvalidSessionTarget;
                session_manager_mod.freeSessionHeader(self.context.session.allocator, &header);
            },
            .get_state, .get_messages, .prompt, .abort, .get_events => {},
            .auth_status => {},
            .start_auth, .save_api_key, .remove_auth => {
                if (payload) |value| {
                    if (value == .object) {
                        if (value.object.get("provider")) |provider_value| {
                            if (provider_value != .string or !isValidProviderId(provider_value.string)) return error.InvalidModelSelection;
                        }
                    }
                }
            },
        }
    }

    pub fn closeAndAbortActiveWork(self: *BridgeHost) bool {
        self.close_requested.store(true, .seq_cst);
        if (!self.active_generation.load(.seq_cst)) return false;
        self.context.session.abortRetry();
        self.context.session.agent.abort();
        return true;
    }

    fn authRequired(self: *const BridgeHost) bool {
        return self.context.auth_status == .missing;
    }
};

fn permissionDeniedMessage(permission: Permission) []const u8 {
    return switch (permission) {
        .skeleton_chat => "WebView bridge command is disabled by policy",
        .model_selection => "WebView model selection requires explicit model selection permission",
        .session_mutation => "WebView session mutation requires explicit session mutation permission",
        .auth_mutation => "WebView auth mutation requires explicit auth mutation permission",
    };
}

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
        .get_state, .get_messages, .abort, .get_events => true,
        .prompt => value.object.get("text") != null and value.object.get("text").? == .string,
        .model_select => value.object.get("provider") != null and
            value.object.get("provider").? == .string and
            value.object.get("model") != null and
            value.object.get("model").? == .string,
        .new_session => true,
        .resume_session, .switch_session => value.object.get("sessionPath") != null and value.object.get("sessionPath").? == .string,
        .auth_status => true,
        .start_auth => value.object.get("provider") == null or value.object.get("provider").? == .string,
        .save_api_key => value.object.get("provider") != null and
            value.object.get("provider").? == .string and
            value.object.get("apiKey") != null and
            value.object.get("apiKey").? == .string,
        .remove_auth => value.object.get("provider") != null and value.object.get("provider").? == .string,
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

fn isValidSessionPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    return std.mem.endsWith(u8, path, ".jsonl");
}

fn isValidModelSelection(current_model: ai.Model, provider: []const u8, model_id: []const u8) bool {
    if (provider.len == 0 or model_id.len == 0) return false;
    if (std.mem.indexOfScalar(u8, provider, 0) != null or std.mem.indexOfScalar(u8, model_id, 0) != null) return false;
    if (std.mem.eql(u8, current_model.provider, provider) and std.mem.eql(u8, current_model.id, model_id)) return true;
    return ai.model_registry.find(provider, model_id) != null;
}

fn isValidProviderId(provider: []const u8) bool {
    if (provider.len == 0) return false;
    if (std.mem.indexOfScalar(u8, provider, 0) != null) return false;
    return true;
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

fn getPayloadString(payload: ?std.json.Value, key: []const u8) ?[]const u8 {
    const value = payload orelse return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

fn getPayloadUsize(payload: ?std.json.Value, key: []const u8) ?usize {
    const value = payload orelse return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .integer => |number| if (number >= 0) @as(usize, @intCast(number)) else null,
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
    if (builtin.os.tag == .windows) {
        return std.fs.path.resolve(allocator, &.{path}) catch return error.FileNotFound;
    }
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

const PromptAcceptance = struct {
    accepted: bool = false,
};

fn markPromptAccepted(context: ?*anyopaque) !void {
    const acceptance: *PromptAcceptance = @ptrCast(@alignCast(context.?));
    acceptance.accepted = true;
}

const AsyncPromptRunner = struct {
    allocator: std.mem.Allocator,
    bridge: *BridgeHost,
    text: []u8,
    session_id: []u8,
    turn_id: []const u8,
};

fn runAsyncPrompt(runner: *AsyncPromptRunner) void {
    defer {
        runner.bridge.active_generation.store(false, .seq_cst);
        runner.bridge.worker_done.store(true, .seq_cst);
        runner.allocator.free(runner.text);
        runner.allocator.free(runner.session_id);
        runner.allocator.destroy(runner);
    }

    var capture = PromptEventCapture.init(
        runner.allocator,
        runner.bridge,
        runner.session_id,
        runner.turn_id,
    );
    defer capture.deinit();

    const subscriber = agent.AgentSubscriber{
        .context = &capture,
        .callback = handleWebViewPromptEvent,
    };
    runner.bridge.context.session.agent.subscribe(subscriber) catch |err| {
        capture.appendSyntheticTerminal("setup_failure", @errorName(err)) catch {};
        return;
    };
    defer {
        _ = runner.bridge.context.session.agent.unsubscribe(subscriber);
    }

    var acceptance = PromptAcceptance{};
    const accepted_callback = agent.PromptAcceptedCallback{
        .context = &acceptance,
        .callback = markPromptAccepted,
    };

    runner.bridge.context.session.promptWithAcceptedCallback(
        .{ .text = runner.text, .images = &[_]ai.ImageContent{} },
        accepted_callback,
    ) catch |err| {
        capture.appendSyntheticTerminal("setup_failure", @errorName(err)) catch {};
        return;
    };
    if (!capture.terminal_seen) {
        capture.appendSyntheticTerminal("success", "prompt completed without an agent_end event") catch {};
    }
}

const PromptEventCapture = struct {
    allocator: std.mem.Allocator,
    host: *BridgeHost,
    session_id: []const u8,
    turn_id: []const u8,
    next_sequence: usize = 1,
    terminal_seen: bool = false,
    terminal_outcome: []const u8 = "success",
    terminal_error_message: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator, host: *BridgeHost, session_id: []const u8, turn_id: []const u8) PromptEventCapture {
        return .{
            .allocator = allocator,
            .host = host,
            .session_id = session_id,
            .turn_id = turn_id,
        };
    }

    fn deinit(self: *PromptEventCapture) void {
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
        const sequence = self.next_sequence;
        self.next_sequence += 1;
        try self.host.enqueueEventFrame(
            try writer.toOwnedSlice(),
            sequence,
            terminal,
            self.terminal_outcome,
            self.terminal_error_message,
        );
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
        const sequence = self.next_sequence;
        self.next_sequence += 1;
        try self.host.enqueueEventFrame(
            try writer.toOwnedSlice(),
            sequence,
            true,
            self.terminal_outcome,
            self.terminal_error_message,
        );
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
};

fn handleWebViewPromptEvent(context: ?*anyopaque, event: agent.AgentEvent) !void {
    const capture: *PromptEventCapture = @ptrCast(@alignCast(context.?));
    try capture.appendEvent(event);
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
    try std.testing.expectEqual(@as(usize, 13), command_table.len);
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
    try std.testing.expectEqual(@as(usize, 0), counters.total());
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
    try std.testing.expectEqual(@as(usize, 0), counters.total());
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
    try std.testing.expectEqual(@as(usize, 0), counters.total());
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
    try std.testing.expectEqual(@as(usize, 1), capture_host.event_frames.items.len);

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
    try bridge.enqueueEventFrame(
        try allocator.dupe(u8, "{\"sessionId\":\"session\",\"turnId\":\"turn\",\"sequence\":2,\"type\":\"message_update\",\"terminal\":false,\"event\":{\"assistantMessageEvent\":{\"delta\":\"late full content\"}}}"),
        2,
        false,
        "success",
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), bridge.event_frames.items.len);
    try std.testing.expect(std.mem.indexOf(u8, bridge.event_frames.items[0].bytes, "Request was aborted") != null);
    try std.testing.expect(std.mem.indexOf(u8, bridge.event_frames.items[0].bytes, "late full content") == null);
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
