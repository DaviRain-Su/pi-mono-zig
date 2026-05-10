const std = @import("std");
const builtin = @import("builtin");
const ai = @import("ai");
const agent = @import("agent");
const json_format = @import("../shared/json_format.zig");
const json_event_wire = @import("json_event_wire.zig");
const auth = @import("../auth/auth.zig");
const common = @import("../tools/common.zig");
const config_mod = @import("../config/config.zig");
const provider_config = @import("../providers/provider_config.zig");
const resources_mod = @import("../resources/resources.zig");
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
    settings_get,
    settings_set,
    thinking_set,
    theme_select,
    scoped_models_get,
    scoped_models_update,
    scoped_models_save,
    session_tree_get,
    session_tree_label,
    session_tree_navigate,
    fork_messages_get,
    fork_session,
};

pub const Permission = enum {
    skeleton_chat,
    model_selection,
    session_mutation,
    auth_mutation,
    settings_mutation,
};

pub const BridgePermissions = struct {
    skeleton_chat: bool = true,
    model_selection: bool = false,
    session_mutation: bool = false,
    auth_mutation: bool = false,
    settings_mutation: bool = false,

    fn allows(self: BridgePermissions, permission: Permission) bool {
        return switch (permission) {
            .skeleton_chat => self.skeleton_chat,
            .model_selection => self.model_selection,
            .session_mutation => self.session_mutation,
            .auth_mutation => self.auth_mutation,
            .settings_mutation => self.settings_mutation,
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
    .{ .name = "settings_get", .command = .settings_get, .permission = .skeleton_chat },
    .{ .name = "settings_set", .command = .settings_set, .permission = .settings_mutation },
    .{ .name = "thinking_set", .command = .thinking_set, .permission = .settings_mutation },
    .{ .name = "theme_select", .command = .theme_select, .permission = .settings_mutation },
    .{ .name = "scoped_models_get", .command = .scoped_models_get, .permission = .skeleton_chat },
    .{ .name = "scoped_models_update", .command = .scoped_models_update, .permission = .settings_mutation },
    .{ .name = "scoped_models_save", .command = .scoped_models_save, .permission = .settings_mutation },
    .{ .name = "session_tree_get", .command = .session_tree_get, .permission = .skeleton_chat },
    .{ .name = "session_tree_label", .command = .session_tree_label, .permission = .session_mutation },
    .{ .name = "session_tree_navigate", .command = .session_tree_navigate, .permission = .session_mutation },
    .{ .name = "fork_messages_get", .command = .fork_messages_get, .permission = .skeleton_chat },
    .{ .name = "fork_session", .command = .fork_session, .permission = .session_mutation },
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
    env_map: ?*const std.process.Environ.Map = null,
    configured_credentials: provider_config.ConfiguredCredentials = .{},
    auth_path: ?[]const u8 = null,
    runtime_config: ?*config_mod.RuntimeConfig = null,
    themes: []const resources_mod.Theme = &.{},
    active_theme_name: ?[]const u8 = null,
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
    settings_get: usize = 0,
    settings_set: usize = 0,
    thinking_set: usize = 0,
    theme_select: usize = 0,
    scoped_models_get: usize = 0,
    scoped_models_update: usize = 0,
    scoped_models_save: usize = 0,
    session_tree_get: usize = 0,
    session_tree_label: usize = 0,
    session_tree_navigate: usize = 0,
    fork_messages_get: usize = 0,
    fork_session: usize = 0,

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
            .settings_get => self.settings_get += 1,
            .settings_set => self.settings_set += 1,
            .thinking_set => self.thinking_set += 1,
            .theme_select => self.theme_select += 1,
            .scoped_models_get => self.scoped_models_get += 1,
            .scoped_models_update => self.scoped_models_update += 1,
            .scoped_models_save => self.scoped_models_save += 1,
            .session_tree_get => self.session_tree_get += 1,
            .session_tree_label => self.session_tree_label += 1,
            .session_tree_navigate => self.session_tree_navigate += 1,
            .fork_messages_get => self.fork_messages_get += 1,
            .fork_session => self.fork_session += 1,
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
            self.remove_auth +
            self.settings_get +
            self.settings_set +
            self.thinking_set +
            self.theme_select +
            self.scoped_models_get +
            self.scoped_models_update +
            self.scoped_models_save +
            self.session_tree_get +
            self.session_tree_label +
            self.session_tree_navigate +
            self.fork_messages_get +
            self.fork_session;
    }
};

const QueuedEventFrame = struct {
    sequence: usize,
    terminal: bool,
    bytes: []u8,
};

const ResolvedModelSelection = struct {
    model: ai.Model,
    api_key: ?[]const u8,
    auth_status: provider_config.ProviderAuthStatus,
    resolved: ?provider_config.ResolvedProviderConfig = null,

    fn deinit(self: *const ResolvedModelSelection, allocator: std.mem.Allocator) void {
        if (self.resolved) |resolved_value| {
            var resolved = resolved_value;
            resolved.deinit(allocator);
        }
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
    event_mutex: std.Io.Mutex = .init,
    event_frames: std.ArrayList(QueuedEventFrame) = .empty,
    terminal_seen: bool = false,
    terminal_outcome: []const u8 = "success",
    terminal_error_message: ?[]u8 = null,
    worker_thread: ?std.Thread = null,
    worker_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    worker_allocator: std.mem.Allocator = std.heap.c_allocator,
    owned_selected_model: ?ai.Model = null,
    owned_selected_api_key: ?[]u8 = null,
    owned_active_theme_name: ?[]u8 = null,
    scoped_draft_initialized: bool = false,
    scoped_draft_enabled_ids: ?[][]u8 = null,
    scoped_draft_dirty: bool = false,

    pub fn init(context: BridgeContext) BridgeHost {
        return .{ .context = context };
    }

    pub fn deinit(self: *BridgeHost) void {
        _ = self.closeAndAbortActiveWork();
        self.joinWorkerIfPresent();
        self.clearOwnedSelection();
        self.clearOwnedTheme();
        self.clearScopedDraft();
        self.event_mutex.lockUncancelable(self.context.session.io);
        defer self.event_mutex.unlock(self.context.session.io);
        self.clearPromptStateLocked();
    }

    fn clearOwnedSelection(self: *BridgeHost) void {
        if (self.owned_selected_model) |*model| {
            ai.model_registry.deinitOwnedModel(self.context.session.allocator, model);
            self.owned_selected_model = null;
        }
        if (self.owned_selected_api_key) |api_key| {
            self.context.session.allocator.free(api_key);
            self.owned_selected_api_key = null;
        }
    }

    fn clearOwnedTheme(self: *BridgeHost) void {
        if (self.owned_active_theme_name) |theme| {
            self.context.session.allocator.free(theme);
            self.owned_active_theme_name = null;
        }
    }

    fn clearScopedDraft(self: *BridgeHost) void {
        if (self.scoped_draft_enabled_ids) |ids| {
            freeOwnedStringList(self.context.session.allocator, ids);
            self.scoped_draft_enabled_ids = null;
        }
        self.scoped_draft_initialized = false;
        self.scoped_draft_dirty = false;
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
            .new_session, .resume_session, .switch_session => try self.writeSessionMutationGatedResult(allocator, &writer.writer, command, payload),
            .auth_status => try self.writeAuthStatusResult(allocator, &writer.writer),
            .start_auth, .save_api_key, .remove_auth => try self.writeAuthMutationGatedResult(allocator, &writer.writer, command, payload),
            .settings_get => try self.writeSettingsPanelResult(allocator, &writer.writer),
            .settings_set => try self.writeSettingsSetResult(allocator, &writer.writer, payload.?),
            .thinking_set => try self.writeThinkingSetResult(allocator, &writer.writer, payload.?),
            .theme_select => try self.writeThemeSelectResult(allocator, &writer.writer, payload.?),
            .scoped_models_get => try self.writeScopedModelsResult(allocator, &writer.writer),
            .scoped_models_update => try self.writeScopedModelsUpdateResult(allocator, &writer.writer, payload.?),
            .scoped_models_save => try self.writeScopedModelsSaveResult(allocator, &writer.writer),
            .session_tree_get => try self.writeSessionTreeState(allocator, &writer.writer),
            .session_tree_label => try self.writeSessionTreeLabelResult(allocator, &writer.writer, payload.?),
            .session_tree_navigate => try self.writeSessionTreeNavigateResult(allocator, &writer.writer, payload.?),
            .fork_messages_get => try self.writeForkPanelState(allocator, &writer.writer),
            .fork_session => try self.writeForkSessionResult(allocator, &writer.writer, payload.?),
        }

        try writer.writer.writeAll("}");
        return try writer.toOwnedSlice();
    }

    fn writeStateResult(
        self: *BridgeHost,
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
        try writer.writeAll(",\"sessionSelection\":");
        try self.writeSessionSelectionState(allocator, writer);
        try writer.writeAll(",\"settingsPanel\":");
        try self.writeSettingsPanelResult(allocator, writer);
        try writer.writeAll(",\"thinkingSelection\":");
        try self.writeThinkingSelectionState(allocator, writer);
        try writer.writeAll(",\"themeSelection\":");
        try self.writeThemeSelectionState(allocator, writer);
        try writer.writeAll(",\"scopedModels\":");
        try self.writeScopedModelsResult(allocator, writer);
        try writer.writeAll(",\"sessionTree\":");
        try self.writeSessionTreeState(allocator, writer);
        try writer.writeAll(",\"forkPanel\":");
        try self.writeForkPanelState(allocator, writer);
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
        try writer.writeAll(",\"actions\":{\"startAuth\":");
        try writer.writeAll(if (auth.findSupportedProvider(self.context.provider) != null) "true" else "false");
        try writer.writeAll(",\"saveApiKey\":");
        try writer.writeAll(if (auth.findSupportedProviderByAuthType(self.context.provider, .api_key) != null) "true" else "false");
        try writer.writeAll(",\"removeAuth\":");
        try writer.writeAll(if (self.context.auth_status == .stored) "true" else "false");
        try writer.writeAll(",\"permissionRequired\":");
        try writer.writeAll(if (self.context.permissions.auth_mutation) "false" else "true");
        try writer.writeAll("}");
        try writer.writeAll("}");
    }

    fn writeSettingsPanelResult(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !void {
        const runtime = self.context.runtime_config;
        try writer.writeAll("{\"status\":");
        try writeJsonString(allocator, writer, if (runtime == null) "unavailable" else "ready");
        try writer.writeAll(",\"searchable\":true,\"permissionRequired\":");
        try writer.writeAll(if (self.context.permissions.settings_mutation) "false" else "true");
        try writer.writeAll(",\"rows\":[");
        var wrote = false;
        try self.writeSettingsRows(allocator, writer, &wrote);
        try writer.writeAll("],\"thinking\":");
        try self.writeThinkingSelectionState(allocator, writer);
        try writer.writeAll(",\"theme\":");
        try self.writeThemeSelectionState(allocator, writer);
        try writer.writeAll("}");
    }

    fn writeSettingsRows(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        wrote: *bool,
    ) !void {
        const runtime = self.context.runtime_config;
        try self.writeSettingRow(allocator, writer, wrote, "autocompact", "Auto-compact", "Automatically compact context when it gets too large", boolName(if (runtime) |config| (config.settings.compaction orelse session_mod.CompactionSettings{}).enabled else self.context.session.compaction_settings.enabled), "toggle", true, &.{ "true", "false" });
        if (modelSupportsImages(self.context.model)) {
            try self.writeSettingRow(allocator, writer, wrote, "show_images", "Show images", "Render images inline in terminal", boolName(if (runtime) |config| config.showImages() else true), "toggle", true, &.{ "true", "false" });
            var image_width_buf: [32]u8 = undefined;
            const image_width = std.fmt.bufPrint(&image_width_buf, "{d}", .{if (runtime) |config| config.imageWidthCells() else 60}) catch "60";
            try self.writeSettingRow(allocator, writer, wrote, "image_width_cells", "Image width", "Preferred inline image width in terminal cells", image_width, "choice", true, &.{ "60", "80", "120" });
        }
        try self.writeSettingRow(allocator, writer, wrote, "auto_resize_images", "Auto-resize images", "Resize large images to 2000x2000 max for better model compatibility", boolName(if (runtime) |config| config.imageAutoResize() else true), "toggle", true, &.{ "true", "false" });
        try self.writeSettingRow(allocator, writer, wrote, "block_images", "Block images", "Prevent images from being sent to LLM providers", boolName(if (runtime) |config| config.blockImages() else false), "toggle", true, &.{ "true", "false" });
        try self.writeSettingRow(allocator, writer, wrote, "skill_commands", "Skill commands", "Register skills as /skill:name commands", boolName(if (runtime) |config| config.enableSkillCommands() else true), "toggle", true, &.{ "true", "false" });
        try self.writeSettingRow(allocator, writer, wrote, "show_hardware_cursor", "Show hardware cursor", "Show the terminal cursor while still positioning it for IME support", boolName(if (runtime) |config| config.showHardwareCursor() else false), "toggle", true, &.{ "true", "false" });
        var editor_padding_buf: [32]u8 = undefined;
        const editor_padding = std.fmt.bufPrint(&editor_padding_buf, "{d}", .{if (runtime) |config| config.settings.editor_padding_x orelse 0 else 0}) catch "0";
        try self.writeSettingRow(allocator, writer, wrote, "editor_padding", "Editor padding", "Horizontal padding for input editor (0-3)", editor_padding, "choice", true, &.{ "0", "1", "2", "3" });
        var autocomplete_buf: [32]u8 = undefined;
        const autocomplete = std.fmt.bufPrint(&autocomplete_buf, "{d}", .{if (runtime) |config| config.settings.autocomplete_max_visible orelse 5 else 5}) catch "5";
        try self.writeSettingRow(allocator, writer, wrote, "autocomplete_max_visible", "Autocomplete max items", "Max visible items in autocomplete dropdown (3-20)", autocomplete, "choice", true, &.{ "3", "5", "7", "10", "15", "20" });
        try self.writeSettingRow(allocator, writer, wrote, "clear_on_shrink", "Clear on shrink", "Clear empty rows when content shrinks (may cause flicker)", boolName(if (runtime) |config| config.clearOnShrink() else false), "toggle", true, &.{ "true", "false" });
        try self.writeSettingRow(allocator, writer, wrote, "terminal_progress", "Terminal progress", "Show OSC 9;4 progress indicators in the terminal tab bar", boolName(if (runtime) |config| config.showTerminalProgress() else false), "toggle", true, &.{ "true", "false" });
        try self.writeSettingRow(allocator, writer, wrote, "steering_mode", "Steering mode", "Enter while streaming queues steering messages", queueModeName(self.context.session.agent.steering_queue.mode), "choice", true, &.{ "one-at-a-time", "all" });
        try self.writeSettingRow(allocator, writer, wrote, "follow_up_mode", "Follow-up mode", "Alt+Enter queues follow-up messages until agent stops", queueModeName(self.context.session.agent.follow_up_queue.mode), "choice", true, &.{ "one-at-a-time", "all" });
        try self.writeSettingRow(allocator, writer, wrote, "transport", "Transport", "Preferred transport for providers that support multiple transports", transportName(if (runtime) |config| config.transport() else .auto), "choice", true, &.{ "sse", "websocket", "websocket-cached", "auto" });
        try self.writeSettingRow(allocator, writer, wrote, "hide_thinking", "Hide thinking", "Hide thinking blocks in assistant responses", boolName(if (runtime) |config| config.hideThinkingBlock() else false), "toggle", true, &.{ "true", "false" });
        try self.writeSettingRow(allocator, writer, wrote, "collapse_changelog", "Collapse changelog", "Show condensed changelog after updates", boolName(if (runtime) |config| config.collapseChangelog() else false), "toggle", true, &.{ "true", "false" });
        try self.writeSettingRow(allocator, writer, wrote, "quiet_startup", "Quiet startup", "Disable verbose printing at startup", boolName(if (runtime) |config| config.quietStartup() else false), "toggle", true, &.{ "true", "false" });
        try self.writeSettingRow(allocator, writer, wrote, "install_telemetry", "Install telemetry", "Send an anonymous version/update ping after changelog-detected updates", boolName(if (runtime) |config| config.enableInstallTelemetry() else true), "toggle", true, &.{ "true", "false" });
        try self.writeSettingRow(allocator, writer, wrote, "double_escape_action", "Double-escape action", "Action when pressing Escape twice with empty editor", doubleEscapeName(if (runtime) |config| config.doubleEscapeAction() else .tree), "choice", true, &.{ "tree", "fork", "none" });
        try self.writeSettingRow(allocator, writer, wrote, "tree_filter_mode", "Tree filter mode", "Default filter when opening /tree", treeFilterName(if (runtime) |config| config.treeFilterMode() else .default), "choice", true, &.{ "default", "no-tools", "user-only", "labeled-only", "all" });
        try self.writeSettingRow(allocator, writer, wrote, "warnings", "Warnings", "Enable or disable individual warnings", boolName(if (runtime) |config| config.warningAnthropicExtraUsage() else true), "toggle", true, &.{ "true", "false" });
        try self.writeSettingRow(allocator, writer, wrote, "thinking", "Thinking level", "Reasoning depth for thinking-capable models", thinkingName(self.context.session.agent.getThinkingLevel()), "submenu", false, null);
        try self.writeSettingRow(allocator, writer, wrote, "theme", "Theme", "Color theme for the interface", self.activeThemeName(), "submenu", false, null);
        try self.writeSettingRow(allocator, writer, wrote, "raw_json", "Advanced raw JSON", "Open the safe settings.json editor with validation and cancel-on-error", "open", "raw", false, null);
    }

    fn writeSettingRow(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        wrote: *bool,
        id: []const u8,
        label: []const u8,
        description: []const u8,
        value: []const u8,
        kind: []const u8,
        editable: bool,
        options: ?[]const []const u8,
    ) !void {
        _ = self;
        if (wrote.*) try writer.writeAll(",");
        wrote.* = true;
        try writer.writeAll("{");
        try writeStringField(allocator, writer, "id", id, false);
        try writeStringField(allocator, writer, "label", label, true);
        try writeStringField(allocator, writer, "description", description, true);
        try writeStringField(allocator, writer, "value", value, true);
        try writeStringField(allocator, writer, "kind", kind, true);
        try writeBoolField(writer, "editable", editable, true);
        try writer.writeAll(",\"options\":");
        if (options) |values| {
            try writer.writeAll("[");
            for (values, 0..) |option, index| {
                if (index > 0) try writer.writeAll(",");
                try writeJsonString(allocator, writer, option);
            }
            try writer.writeAll("]");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("}");
    }

    fn writeThinkingSelectionState(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !void {
        try writer.writeAll("{\"current\":");
        try writeJsonString(allocator, writer, thinkingName(self.context.session.agent.getThinkingLevel()));
        try writer.writeAll(",\"modelSupportsThinking\":");
        try writer.writeAll(if (self.context.model.reasoning) "true" else "false");
        try writer.writeAll(",\"levels\":[");
        inline for (.{ agent.ThinkingLevel.off, .minimal, .low, .medium, .high, .xhigh }, 0..) |level, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.writeAll("{\"name\":");
            try writeJsonString(allocator, writer, thinkingName(level));
            try writer.writeAll(",\"description\":");
            try writeJsonString(allocator, writer, thinkingDescription(level));
            try writer.writeAll(",\"available\":");
            try writer.writeAll(if (thinkingLevelAvailable(self.context.model, level)) "true" else "false");
            try writer.writeAll(",\"active\":");
            try writer.writeAll(if (self.context.session.agent.getThinkingLevel() == level) "true" else "false");
            if (!thinkingLevelAvailable(self.context.model, level)) {
                try writer.writeAll(",\"unavailableReason\":\"Current model does not support this thinking level\"");
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("]}");
    }

    fn writeThemeSelectionState(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !void {
        const active = self.activeThemeName();
        try writer.writeAll("{\"active\":");
        try writeJsonString(allocator, writer, active);
        try writer.writeAll(",\"themes\":[");
        if (self.context.themes.len > 0) {
            for (self.context.themes, 0..) |theme, index| {
                if (index > 0) try writer.writeAll(",");
                try writer.writeAll("{\"name\":");
                try writeJsonString(allocator, writer, theme.name);
                try writer.writeAll(",\"active\":");
                try writer.writeAll(if (std.mem.eql(u8, active, theme.name)) "true" else "false");
                try writer.writeAll("}");
            }
        } else {
            const fallback = [_][]const u8{ "dark", "light", "codex" };
            for (fallback, 0..) |theme, index| {
                if (index > 0) try writer.writeAll(",");
                try writer.writeAll("{\"name\":");
                try writeJsonString(allocator, writer, theme);
                try writer.writeAll(",\"active\":");
                try writer.writeAll(if (std.mem.eql(u8, active, theme)) "true" else "false");
                try writer.writeAll("}");
            }
        }
        try writer.writeAll("]}");
    }

    fn activeThemeName(self: *const BridgeHost) []const u8 {
        if (self.owned_active_theme_name) |theme| return theme;
        if (self.context.active_theme_name) |theme| return theme;
        if (self.context.runtime_config) |config| {
            if (config.settings.theme) |theme| return theme;
        }
        return "dark";
    }

    fn writeSettingsSetResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        payload: std.json.Value,
    ) !void {
        const id = payload.object.get("id").?.string;
        const value = payload.object.get("value").?.string;
        if (self.context.runtime_config == null) {
            try writer.writeAll("{\"status\":\"unavailable\",\"accepted\":false,\"message\":\"Settings are unavailable in this WebView session\"}");
            return;
        }
        if (!settingValueAllowed(id, value)) {
            try writer.writeAll("{\"status\":\"invalid\",\"accepted\":false,\"message\":\"Setting value is not supported\"}");
            return;
        }
        try self.persistSettingValue(allocator, id, value);
        try self.applySettingSideEffect(id, value);
        try writer.writeAll("{\"status\":\"saved\",\"accepted\":true,\"id\":");
        try writeJsonString(allocator, writer, id);
        try writer.writeAll(",\"value\":");
        try writeJsonString(allocator, writer, value);
        try writer.writeAll(",\"settings\":");
        try self.writeSettingsPanelResult(allocator, writer);
        try writer.writeAll("}");
    }

    fn writeThinkingSetResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        payload: std.json.Value,
    ) !void {
        const level_name = payload.object.get("level").?.string;
        const level = parseThinkingLevelName(level_name) orelse {
            try writer.writeAll("{\"status\":\"invalid\",\"accepted\":false,\"message\":\"Unknown thinking level\"}");
            return;
        };
        if (!thinkingLevelAvailable(self.context.model, level)) {
            try writer.writeAll("{\"status\":\"unsupported\",\"accepted\":false,\"level\":");
            try writeJsonString(allocator, writer, level_name);
            try writer.writeAll(",\"message\":\"Current model does not support this thinking level\",\"thinking\":");
            try self.writeThinkingSelectionState(allocator, writer);
            try writer.writeAll("}");
            return;
        }
        try self.context.session.setThinkingLevel(level);
        try writer.writeAll("{\"status\":\"selected\",\"accepted\":true,\"level\":");
        try writeJsonString(allocator, writer, thinkingName(level));
        try writer.writeAll(",\"thinking\":");
        try self.writeThinkingSelectionState(allocator, writer);
        try writer.writeAll("}");
    }

    fn writeThemeSelectResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        payload: std.json.Value,
    ) !void {
        const requested = canonicalThemeName(payload.object.get("theme").?.string);
        if (!self.themeExists(requested)) {
            try writer.writeAll("{\"status\":\"invalid\",\"accepted\":false,\"message\":\"Unknown theme\"}");
            return;
        }
        try self.persistSettingValue(allocator, "theme", requested);
        const owned = try self.context.session.allocator.dupe(u8, requested);
        self.clearOwnedTheme();
        self.owned_active_theme_name = owned;
        try writer.writeAll("{\"status\":\"selected\",\"accepted\":true,\"theme\":");
        try writeJsonString(allocator, writer, requested);
        try writer.writeAll(",\"themeSelection\":");
        try self.writeThemeSelectionState(allocator, writer);
        try writer.writeAll("}");
    }

    fn themeExists(self: *const BridgeHost, name: []const u8) bool {
        if (self.context.themes.len == 0) {
            return std.mem.eql(u8, name, "dark") or std.mem.eql(u8, name, "light") or std.mem.eql(u8, name, "codex");
        }
        for (self.context.themes) |theme| {
            if (std.mem.eql(u8, theme.name, name)) return true;
        }
        return false;
    }

    fn writeScopedModelsResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !void {
        try self.ensureScopedDraft();
        const enabled_count = if (self.scoped_draft_enabled_ids) |ids| ids.len else self.context.available_models.len;
        try writer.writeAll("{\"status\":\"ready\",\"permissionRequired\":");
        try writer.writeAll(if (self.context.permissions.settings_mutation) "false" else "true");
        try writer.writeAll(",\"dirty\":");
        try writer.writeAll(if (self.scoped_draft_dirty) "true" else "false");
        try writer.writeAll(",\"allEnabled\":");
        try writer.writeAll(if (self.scoped_draft_enabled_ids == null) "true" else "false");
        try writeUsizeField(writer, "enabledCount", enabled_count, true);
        try writeUsizeField(writer, "totalCount", self.context.available_models.len, true);
        try writer.writeAll(",\"controls\":{\"toggle\":true,\"enableAll\":true,\"clearAll\":true,\"providerToggle\":true,\"reorder\":true,\"save\":true,\"search\":true},\"models\":[");
        try self.writeScopedModelRows(allocator, writer);
        try writer.writeAll("]}");
    }

    fn writeScopedModelRows(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !void {
        if (self.context.available_models.len == 0) return;
        const emitted = try allocator.alloc(bool, self.context.available_models.len);
        defer allocator.free(emitted);
        @memset(emitted, false);
        var wrote = false;
        var order_index: usize = 0;
        if (self.scoped_draft_enabled_ids) |ids| {
            for (ids) |id| {
                const model_index = self.availableModelIndexByFullId(id) orelse continue;
                if (emitted[model_index]) continue;
                if (wrote) try writer.writeAll(",");
                wrote = true;
                try self.writeScopedModelRow(allocator, writer, self.context.available_models[model_index], true, order_index);
                emitted[model_index] = true;
                order_index += 1;
            }
        }
        for (self.context.available_models, 0..) |model, index| {
            if (emitted[index]) continue;
            if (wrote) try writer.writeAll(",");
            wrote = true;
            const enabled = if (self.scoped_draft_enabled_ids == null) true else false;
            try self.writeScopedModelRow(allocator, writer, model, enabled, order_index);
            order_index += 1;
        }
    }

    fn writeScopedModelRow(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        model: provider_config.AvailableModel,
        enabled: bool,
        order_index: usize,
    ) !void {
        const full_id = try scopedModelFullId(allocator, model);
        defer allocator.free(full_id);
        _ = self;
        try writer.writeAll("{");
        try writeStringField(allocator, writer, "fullId", full_id, false);
        try writeStringField(allocator, writer, "provider", model.provider, true);
        try writeStringField(allocator, writer, "model", model.model_id, true);
        try writeStringField(allocator, writer, "displayName", model.display_name, true);
        try writeBoolField(writer, "enabled", enabled, true);
        try writeStringField(allocator, writer, "authStatus", @tagName(model.auth_status), true);
        try writeStringField(allocator, writer, "authStatusLabel", provider_config.providerAuthStatusLabel(model.auth_status), true);
        try writeBoolField(writer, "reasoning", model.reasoning, true);
        try writeUsizeField(writer, "order", order_index, true);
        try writer.writeAll("}");
    }

    fn writeScopedModelsUpdateResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        payload: std.json.Value,
    ) !void {
        try self.ensureScopedDraft();
        const action = payload.object.get("action").?.string;
        if (std.mem.eql(u8, action, "toggle")) {
            const full_id = payload.object.get("fullId") orelse {
                try writer.writeAll("{\"status\":\"invalid\",\"accepted\":false,\"message\":\"toggle requires fullId\"}");
                return;
            };
            if (full_id != .string or self.availableModelIndexByFullId(full_id.string) == null) {
                try writer.writeAll("{\"status\":\"invalid\",\"accepted\":false,\"message\":\"unknown model\"}");
                return;
            }
            try self.toggleScopedId(full_id.string);
        } else if (std.mem.eql(u8, action, "enable_all")) {
            const targets = try self.scopedTargetsFromPayload(allocator, payload);
            defer freeOwnedStringList(allocator, targets);
            try self.enableScopedTargets(targets);
        } else if (std.mem.eql(u8, action, "clear_all")) {
            const targets = try self.scopedTargetsFromPayload(allocator, payload);
            defer freeOwnedStringList(allocator, targets);
            try self.clearScopedTargets(targets);
        } else if (std.mem.eql(u8, action, "provider_toggle")) {
            const provider = payload.object.get("provider") orelse {
                try writer.writeAll("{\"status\":\"invalid\",\"accepted\":false,\"message\":\"provider_toggle requires provider\"}");
                return;
            };
            if (provider != .string) {
                try writer.writeAll("{\"status\":\"invalid\",\"accepted\":false,\"message\":\"provider must be a string\"}");
                return;
            }
            const targets = try self.scopedTargetsForProvider(allocator, provider.string);
            defer freeOwnedStringList(allocator, targets);
            if (self.allScopedTargetsEnabled(targets)) {
                try self.clearScopedTargets(targets);
            } else {
                try self.enableScopedTargets(targets);
            }
        } else if (std.mem.eql(u8, action, "reorder")) {
            const full_id = payload.object.get("fullId") orelse {
                try writer.writeAll("{\"status\":\"invalid\",\"accepted\":false,\"message\":\"reorder requires fullId\"}");
                return;
            };
            const direction = payload.object.get("direction") orelse {
                try writer.writeAll("{\"status\":\"invalid\",\"accepted\":false,\"message\":\"reorder requires direction\"}");
                return;
            };
            if (full_id != .string or direction != .string) {
                try writer.writeAll("{\"status\":\"invalid\",\"accepted\":false,\"message\":\"reorder fields must be strings\"}");
                return;
            }
            try self.reorderScopedId(full_id.string, if (std.mem.eql(u8, direction.string, "up")) -1 else 1);
        } else {
            try writer.writeAll("{\"status\":\"invalid\",\"accepted\":false,\"message\":\"unknown scoped model action\"}");
            return;
        }
        try writer.writeAll("{\"status\":\"updated\",\"accepted\":true,\"scopedModels\":");
        try self.writeScopedModelsResult(allocator, writer);
        try writer.writeAll("}");
    }

    fn writeScopedModelsSaveResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !void {
        try self.ensureScopedDraft();
        if (self.context.runtime_config == null) {
            try writer.writeAll("{\"status\":\"unavailable\",\"accepted\":false,\"message\":\"Settings are unavailable in this WebView session\"}");
            return;
        }
        try persistEnabledModels(allocator, self.context.session.io, self.context.runtime_config.?, self.scoped_draft_enabled_ids);
        try self.replaceRuntimeEnabledModelsFromDraft();
        self.scoped_draft_dirty = false;
        try writer.writeAll("{\"status\":\"saved\",\"accepted\":true,\"scopedModels\":");
        try self.writeScopedModelsResult(allocator, writer);
        try writer.writeAll("}");
    }

    fn ensureScopedDraft(self: *BridgeHost) !void {
        if (self.scoped_draft_initialized) return;
        self.scoped_draft_initialized = true;
        if (self.context.runtime_config) |config| {
            if (config.settings.enabled_models) |ids| {
                self.scoped_draft_enabled_ids = try cloneStringListAsMutable(self.context.session.allocator, ids);
            }
        }
    }

    fn setScopedDraft(self: *BridgeHost, next_ids: ?[][]u8) void {
        if (self.scoped_draft_enabled_ids) |ids| freeOwnedStringList(self.context.session.allocator, ids);
        self.scoped_draft_enabled_ids = next_ids;
        self.scoped_draft_dirty = true;
    }

    fn toggleScopedId(self: *BridgeHost, id: []const u8) !void {
        const allocator = self.context.session.allocator;
        if (self.scoped_draft_enabled_ids == null) {
            const all_ids = try self.allScopedModelIds(allocator);
            defer freeOwnedStringList(allocator, all_ids);
            const next = try clonedExcludingIds(allocator, all_ids, &.{id});
            self.setScopedDraft(next);
            return;
        }
        const ids = self.scoped_draft_enabled_ids.?;
        if (indexOfString(ids, id) != null) {
            const next = try clonedExcludingIds(allocator, ids, &.{id});
            self.setScopedDraft(next);
        } else {
            var next = try cloneStringListAsMutable(allocator, ids);
            errdefer freeOwnedStringList(allocator, next);
            try appendUniqueOwned(allocator, &next, id);
            if (next.len == self.context.available_models.len) {
                freeOwnedStringList(allocator, next);
                self.setScopedDraft(null);
            } else {
                self.setScopedDraft(next);
            }
        }
    }

    fn enableScopedTargets(self: *BridgeHost, targets: []const []const u8) !void {
        if (targets.len == 0 or self.scoped_draft_enabled_ids == null) return;
        const allocator = self.context.session.allocator;
        var next = try cloneStringListAsMutable(allocator, self.scoped_draft_enabled_ids.?);
        errdefer freeOwnedStringList(allocator, next);
        for (targets) |target| try appendUniqueOwned(allocator, &next, target);
        if (next.len == self.context.available_models.len) {
            freeOwnedStringList(allocator, next);
            self.setScopedDraft(null);
        } else {
            self.setScopedDraft(next);
        }
    }

    fn clearScopedTargets(self: *BridgeHost, targets: []const []const u8) !void {
        const allocator = self.context.session.allocator;
        if (self.scoped_draft_enabled_ids == null) {
            const all_ids = try self.allScopedModelIds(allocator);
            defer freeOwnedStringList(allocator, all_ids);
            const next = try clonedExcludingIds(allocator, all_ids, targets);
            self.setScopedDraft(next);
        } else {
            const next = try clonedExcludingIds(allocator, self.scoped_draft_enabled_ids.?, targets);
            self.setScopedDraft(next);
        }
    }

    fn reorderScopedId(self: *BridgeHost, id: []const u8, delta: isize) !void {
        const allocator = self.context.session.allocator;
        if (self.scoped_draft_enabled_ids == null) {
            self.scoped_draft_enabled_ids = try self.allScopedModelIds(allocator);
        }
        const ids = self.scoped_draft_enabled_ids.?;
        const index = indexOfString(ids, id) orelse return;
        if (delta < 0 and index == 0) return;
        if (delta > 0 and index + 1 >= ids.len) return;
        const swap_index: usize = if (delta < 0) index - 1 else index + 1;
        std.mem.swap([]u8, &ids[index], &ids[swap_index]);
        self.scoped_draft_dirty = true;
    }

    fn scopedTargetsFromPayload(self: *BridgeHost, allocator: std.mem.Allocator, payload: std.json.Value) ![][]u8 {
        if (payload.object.get("targets")) |targets| {
            if (targets == .array) {
                var list = std.ArrayList([]u8).empty;
                errdefer freeOwnedStringList(allocator, list.items);
                for (targets.array.items) |target| {
                    if (target != .string) continue;
                    if (self.availableModelIndexByFullId(target.string) != null) {
                        try list.append(allocator, try allocator.dupe(u8, target.string));
                    }
                }
                return try list.toOwnedSlice(allocator);
            }
        }
        return try self.allScopedModelIds(allocator);
    }

    fn scopedTargetsForProvider(self: *BridgeHost, allocator: std.mem.Allocator, provider: []const u8) ![][]u8 {
        var list = std.ArrayList([]u8).empty;
        errdefer freeOwnedStringList(allocator, list.items);
        for (self.context.available_models) |model| {
            if (!std.mem.eql(u8, model.provider, provider)) continue;
            try list.append(allocator, try scopedModelFullId(allocator, model));
        }
        return try list.toOwnedSlice(allocator);
    }

    fn allScopedTargetsEnabled(self: *BridgeHost, targets: []const []const u8) bool {
        for (targets) |target| {
            if (!scopedIdEnabled(self.scoped_draft_enabled_ids, target)) return false;
        }
        return targets.len > 0;
    }

    fn allScopedModelIds(self: *BridgeHost, allocator: std.mem.Allocator) ![][]u8 {
        var ids = try allocator.alloc([]u8, self.context.available_models.len);
        var initialized: usize = 0;
        errdefer {
            for (ids[0..initialized]) |id| allocator.free(id);
            allocator.free(ids);
        }
        for (self.context.available_models, 0..) |model, index| {
            ids[index] = try scopedModelFullId(allocator, model);
            initialized += 1;
        }
        return ids;
    }

    fn availableModelIndexByFullId(self: *const BridgeHost, full_id: []const u8) ?usize {
        for (self.context.available_models, 0..) |model, index| {
            var buffer: [1024]u8 = undefined;
            const candidate = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ model.provider, model.model_id }) catch continue;
            if (std.mem.eql(u8, candidate, full_id)) return index;
        }
        return null;
    }

    fn replaceRuntimeEnabledModelsFromDraft(self: *BridgeHost) !void {
        const runtime = self.context.runtime_config orelse return;
        const allocator = runtime.allocator;
        freeConstStringList(allocator, runtime.settings.enabled_models);
        runtime.settings.enabled_models = try cloneStringListConst(allocator, self.scoped_draft_enabled_ids);
        freeConstStringList(allocator, runtime.global_settings.enabled_models);
        runtime.global_settings.enabled_models = try cloneStringListConst(allocator, self.scoped_draft_enabled_ids);
    }

    fn writeModelSelectionState(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !void {
        try writer.writeAll("{\"status\":");
        try writeJsonString(allocator, writer, if (self.context.permissions.model_selection) "ready" else "gated");
        try writer.writeAll(",\"permissionRequired\":");
        try writer.writeAll(if (self.context.permissions.model_selection) "false" else "true");
        try writer.writeAll(",\"activeProvider\":");
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

        const available = self.availableModelForSelection(provider, model);
        if (available) |entry| {
            if (!entry.available or entry.auth_status == .missing) {
                self.context.provider = entry.provider;
                self.context.auth_status = entry.auth_status;
                self.context.api_key_present = false;
                self.context.session.setApiKey(null);
                try writer.writeAll("{\"status\":\"auth_required\",\"accepted\":false,\"provider\":");
                try writeJsonString(allocator, writer, entry.provider);
                try writer.writeAll(",\"model\":");
                try writeJsonString(allocator, writer, entry.model_id);
                try writer.writeAll(",\"message\":");
                try writeJsonString(allocator, writer, "Provider credentials are required before this model can run");
                try writer.writeAll(",\"auth\":");
                try self.writeAuthStatusResult(allocator, writer);
                try writer.writeAll("}");
                return;
            }
        }

        const selected = try self.resolveSelectedModel(allocator, provider, model);
        defer selected.deinit(allocator);
        var next_owned_model: ?ai.Model = try ai.model_registry.cloneOwnedModel(self.context.session.allocator, selected.model);
        errdefer if (next_owned_model) |*owned_model| {
            ai.model_registry.deinitOwnedModel(self.context.session.allocator, owned_model);
        };
        var next_owned_api_key: ?[]u8 = if (selected.api_key) |api_key|
            try self.context.session.allocator.dupe(u8, api_key)
        else
            null;
        errdefer if (next_owned_api_key) |api_key| self.context.session.allocator.free(api_key);

        self.clearOwnedSelection();
        self.owned_selected_model = next_owned_model.?;
        self.owned_selected_api_key = next_owned_api_key;
        next_owned_model = null;
        next_owned_api_key = null;
        const stable_model = self.owned_selected_model.?;
        self.context.provider = stable_model.provider;
        self.context.model = stable_model;
        self.context.auth_status = selected.auth_status;
        self.context.api_key_present = selected.api_key != null or selected.auth_status == .local;
        self.context.session.setApiKey(self.owned_selected_api_key);
        try self.context.session.setModel(stable_model);

        try writer.writeAll("{\"status\":\"selected\",\"accepted\":true,\"provider\":");
        try writeJsonString(allocator, writer, self.context.provider);
        try writer.writeAll(",\"model\":");
        try writeJsonString(allocator, writer, self.context.model.id);
        try writer.writeAll(",\"displayName\":");
        try writeJsonString(allocator, writer, self.context.model.name);
        try writer.writeAll(",\"authStatus\":");
        try writeJsonString(allocator, writer, @tagName(self.context.auth_status));
        try writer.writeAll(",\"state\":");
        try self.writeModelSelectionState(allocator, writer);
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
        payload: ?std.json.Value,
    ) !void {
        if (self.active_generation.load(.seq_cst)) {
            try writer.writeAll("{\"status\":\"busy\",\"accepted\":false,\"command\":");
            try writeJsonString(allocator, writer, @tagName(command));
            try writer.writeAll(",\"message\":");
            try writeJsonString(allocator, writer, "WebView session changes are blocked while a prompt is active");
            try writer.writeAll("}");
            return;
        }
        const session_dir = self.context.session.session_manager.getSessionDir();
        if (self.context.no_session or session_dir.len == 0) {
            try writer.writeAll("{\"status\":\"unavailable\",\"accepted\":false,\"command\":");
            try writeJsonString(allocator, writer, @tagName(command));
            try writer.writeAll(",\"message\":");
            try writeJsonString(allocator, writer, "Persistent sessions are unavailable in --no-session WebView mode");
            try writer.writeAll("}");
            return;
        }

        var next_manager = switch (command) {
            .new_session => try session_manager_mod.SessionManager.createWithParent(
                self.context.session.allocator,
                self.context.session.io,
                self.context.cwd,
                session_dir,
                self.context.session.session_manager.getSessionFile(),
            ),
            .resume_session, .switch_session => try session_manager_mod.SessionManager.open(
                self.context.session.allocator,
                self.context.session.io,
                payload.?.object.get("sessionPath").?.string,
                null,
            ),
            else => unreachable,
        };
        errdefer next_manager.deinit();
        try self.replaceSessionManager(allocator, &next_manager);

        try writer.writeAll("{\"status\":");
        try writeJsonString(allocator, writer, switch (command) {
            .new_session => "created",
            .resume_session => "resumed",
            .switch_session => "switched",
            else => unreachable,
        });
        try writer.writeAll(",\"accepted\":true,\"sessionId\":");
        try writeJsonString(allocator, writer, self.context.session.session_manager.getSessionId());
        try writer.writeAll(",\"sessionPath\":");
        if (self.context.session.session_manager.getSessionFile()) |path| {
            try writeJsonString(allocator, writer, path);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"sessionSelection\":");
        try self.writeSessionSelectionState(allocator, writer);
        try writer.writeAll("}");
    }

    fn writeAuthMutationGatedResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        command: Command,
        payload: ?std.json.Value,
    ) !void {
        switch (command) {
            .start_auth => try self.writeStartAuthResult(allocator, writer, payload),
            .save_api_key => try self.writeSaveApiKeyResult(allocator, writer, payload.?),
            .remove_auth => try self.writeRemoveAuthResult(allocator, writer, payload.?),
            else => unreachable,
        }
    }

    fn writeSessionSelectionState(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !void {
        const session_dir = self.context.session.session_manager.getSessionDir();
        try writer.writeAll("{\"status\":");
        try writeJsonString(allocator, writer, if (self.context.no_session or session_dir.len == 0) "unavailable" else "ready");
        try writer.writeAll(",\"permissionRequired\":");
        try writer.writeAll(if (self.context.permissions.session_mutation) "false" else "true");
        try writer.writeAll(",\"currentSessionId\":");
        try writeJsonString(allocator, writer, self.context.session.session_manager.getSessionId());
        try writer.writeAll(",\"currentSessionPath\":");
        if (self.context.session.session_manager.getSessionFile()) |path| {
            try writeJsonString(allocator, writer, path);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"controls\":{\"scopes\":[\"current\",\"all\"],\"sorts\":[\"threaded\",\"recent\",\"relevance\"],\"nameFilters\":[\"all\",\"named\"],\"search\":true,\"pathToggle\":true,\"newSession\":true,\"resume\":true,\"switch\":true},\"sessions\":[");
        if (!self.context.no_session and session_dir.len > 0) {
            const sessions = session_manager_mod.listAllSessionsUnder(allocator, self.context.session.io, session_dir) catch &[_]session_manager_mod.SessionSearchInfo{};
            defer {
                for (@constCast(sessions)) |*entry| entry.deinit(allocator);
                if (sessions.len > 0) allocator.free(@constCast(sessions));
            }
            for (sessions, 0..) |entry, index| {
                if (index > 0) try writer.writeAll(",");
                try writeSessionSearchInfo(allocator, writer, entry, self.context.session.session_manager.getSessionFile());
            }
        }
        try writer.writeAll("]}");
    }

    fn writeSessionTreeState(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !void {
        const tree = try self.context.session.session_manager.getTree(allocator);
        defer {
            for (tree) |*node| node.deinit(allocator);
            allocator.free(tree);
        }
        const current_leaf_id = self.context.session.session_manager.getLeafId();
        try writer.writeAll("{\"status\":\"ready\",\"permissionRequired\":");
        try writer.writeAll(if (self.context.permissions.session_mutation) "false" else "true");
        try writer.writeAll(",\"currentLeafId\":");
        if (current_leaf_id) |id| {
            try writeJsonString(allocator, writer, id);
        } else {
            try writer.writeAll("null");
        }
        const prompt_required = if (self.context.runtime_config) |config| !config.branchSummarySkipPrompt() else true;
        try writer.writeAll(",\"branchSummaryPromptRequired\":");
        try writer.writeAll(if (prompt_required) "true" else "false");
        const default_filter = if (self.context.runtime_config) |config| treeFilterName(config.treeFilterMode()) else "default";
        try writer.writeAll(",\"defaultFilter\":");
        try writeJsonString(allocator, writer, default_filter);
        try writer.writeAll(",\"filters\":[\"default\",\"no-tools\",\"user-only\",\"labeled-only\",\"all\"],\"controls\":{\"search\":true,\"folding\":true,\"labels\":true,\"labelTimestamps\":true,\"navigate\":true,\"branchSummaryPrompt\":true},\"entries\":[");
        var wrote = false;
        try self.writeSessionTreeNodes(allocator, writer, tree, current_leaf_id, 0, &wrote);
        try writer.writeAll("]}");
    }

    fn writeSessionTreeNodes(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        nodes: []const session_manager_mod.SessionTreeNode,
        current_leaf_id: ?[]const u8,
        depth: usize,
        wrote: *bool,
    ) !void {
        var pass: usize = 0;
        while (pass < 2) : (pass += 1) {
            for (nodes) |node| {
                const active_subtree = treeSubtreeContains(node, current_leaf_id);
                if ((pass == 0) != active_subtree) continue;
                if (wrote.*) try writer.writeAll(",");
                wrote.* = true;
                try self.writeSessionTreeEntry(allocator, writer, node, current_leaf_id, depth);
                try self.writeSessionTreeNodes(allocator, writer, node.children, current_leaf_id, depth + 1, wrote);
            }
        }
    }

    fn writeSessionTreeEntry(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        node: session_manager_mod.SessionTreeNode,
        current_leaf_id: ?[]const u8,
        depth: usize,
    ) !void {
        _ = self;
        const entry = node.entry.*;
        const kind = sessionEntryKindName(entry);
        const display = try sessionEntryDisplayText(allocator, entry);
        defer allocator.free(display);
        try writer.writeAll("{");
        try writeStringField(allocator, writer, "id", entry.id(), false);
        try writer.writeAll(",\"parentId\":");
        if (entry.parentId()) |parent_id| {
            try writeJsonString(allocator, writer, parent_id);
        } else {
            try writer.writeAll("null");
        }
        try writeStringField(allocator, writer, "timestamp", entry.timestamp(), true);
        try writeStringField(allocator, writer, "kind", kind, true);
        try writeStringField(allocator, writer, "display", display, true);
        try writer.writeAll(",\"label\":");
        if (node.label) |label| {
            try writeJsonString(allocator, writer, label);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"labelTimestamp\":");
        if (node.label_timestamp) |timestamp| {
            try writeJsonString(allocator, writer, timestamp);
        } else {
            try writer.writeAll("null");
        }
        try writeUsizeField(writer, "depth", depth, true);
        try writeBoolField(writer, "hasChildren", node.children.len > 0, true);
        try writeBoolField(writer, "activePath", treeSubtreeContains(node, current_leaf_id), true);
        try writeBoolField(writer, "current", if (current_leaf_id) |id| std.mem.eql(u8, id, entry.id()) else false, true);
        try writeBoolField(writer, "bookkeeping", sessionEntryIsBookkeeping(entry), true);
        try writer.writeAll("}");
    }

    fn writeSessionTreeLabelResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        payload: std.json.Value,
    ) !void {
        if (self.active_generation.load(.seq_cst)) {
            try writer.writeAll("{\"status\":\"busy\",\"accepted\":false,\"message\":\"WebView session tree labels are blocked while a prompt is active\"}");
            return;
        }
        const entry_id = payload.object.get("entryId").?.string;
        const label_text = payload.object.get("label").?.string;
        const trimmed = std.mem.trim(u8, label_text, &std.ascii.whitespace);
        _ = try self.context.session.session_manager.appendLabelChange(entry_id, if (trimmed.len == 0) null else trimmed);
        try writer.writeAll("{\"status\":");
        try writeJsonString(allocator, writer, if (trimmed.len == 0) "cleared" else "saved");
        try writer.writeAll(",\"accepted\":true,\"entryId\":");
        try writeJsonString(allocator, writer, entry_id);
        try writer.writeAll(",\"label\":");
        if (trimmed.len == 0) {
            try writer.writeAll("null");
        } else {
            try writeJsonString(allocator, writer, trimmed);
        }
        try writer.writeAll(",\"sessionTree\":");
        try self.writeSessionTreeState(allocator, writer);
        try writer.writeAll("}");
    }

    fn writeSessionTreeNavigateResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        payload: std.json.Value,
    ) !void {
        if (self.active_generation.load(.seq_cst)) {
            try writer.writeAll("{\"status\":\"busy\",\"accepted\":false,\"message\":\"WebView session tree navigation is blocked while a prompt is active\"}");
            return;
        }
        const entry_id = payload.object.get("entryId").?.string;
        if (self.context.session.session_manager.getLeafId()) |leaf_id| {
            if (std.mem.eql(u8, leaf_id, entry_id)) {
                try writer.writeAll("{\"status\":\"already_current\",\"accepted\":false,\"entryId\":");
                try writeJsonString(allocator, writer, entry_id);
                try writer.writeAll(",\"sessionTree\":");
                try self.writeSessionTreeState(allocator, writer);
                try writer.writeAll("}");
                return;
            }
        }
        const prompt_required = if (self.context.runtime_config) |config| !config.branchSummarySkipPrompt() else true;
        const summarize_value = payload.object.get("summarize");
        if (prompt_required and summarize_value == null) {
            try writer.writeAll("{\"status\":\"summary_required\",\"accepted\":false,\"entryId\":");
            try writeJsonString(allocator, writer, entry_id);
            try writer.writeAll(",\"choices\":[\"skip\",\"summarize\",\"summarize-custom\"],\"message\":\"Choose branch summary behavior\"}");
            return;
        }
        const summarize = if (summarize_value) |value| value == .bool and value.bool else false;
        const summary_text = if (payload.object.get("summaryText")) |value|
            if (value == .string and value.string.len > 0) value.string else "Branch summary selected from the session tree."
        else
            "Branch summary selected from the session tree.";
        var result = try self.context.session.navigateTree(allocator, entry_id, .{
            .summarize = summarize,
            .summary_text = if (summarize) summary_text else null,
        });
        defer result.deinit(allocator);
        try writer.writeAll("{\"status\":\"navigated\",\"accepted\":true,\"entryId\":");
        try writeJsonString(allocator, writer, entry_id);
        try writer.writeAll(",\"sessionId\":");
        try writeJsonString(allocator, writer, self.context.session.session_manager.getSessionId());
        try writer.writeAll(",\"currentLeafId\":");
        if (self.context.session.session_manager.getLeafId()) |leaf_id| {
            try writeJsonString(allocator, writer, leaf_id);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"summaryEntryId\":");
        if (result.summary_entry_id) |summary_id| {
            try writeJsonString(allocator, writer, summary_id);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"editorText\":");
        if (result.editor_text) |text| {
            try writeJsonString(allocator, writer, text);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"sessionTree\":");
        try self.writeSessionTreeState(allocator, writer);
        try writer.writeAll("}");
    }

    fn writeForkPanelState(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !void {
        try writer.writeAll("{\"status\":\"ready\",\"permissionRequired\":");
        try writer.writeAll(if (self.context.permissions.session_mutation) "false" else "true");
        try writer.writeAll(",\"messages\":[");
        var wrote = false;
        var index: usize = 0;
        for (self.context.session.session_manager.getEntries()) |entry| {
            if (entry != .message or entry.message.message != .user) continue;
            const text = try contentBlocksPlainTextAlloc(allocator, entry.message.message.user.content);
            defer allocator.free(text);
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (wrote) try writer.writeAll(",");
            wrote = true;
            index += 1;
            try writer.writeAll("{");
            try writeStringField(allocator, writer, "entryId", entry.message.id, false);
            try writer.writeAll(",\"parentId\":");
            if (entry.message.parent_id) |parent_id| {
                try writeJsonString(allocator, writer, parent_id);
            } else {
                try writer.writeAll("null");
            }
            try writeStringField(allocator, writer, "timestamp", entry.message.timestamp, true);
            try writeStringField(allocator, writer, "text", trimmed, true);
            try writer.print(",\"index\":{d}", .{index});
            try writer.writeAll("}");
        }
        try writer.writeAll("],\"controls\":{\"fork\":true,\"search\":true}}");
    }

    fn writeForkSessionResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        payload: std.json.Value,
    ) !void {
        if (self.active_generation.load(.seq_cst)) {
            try writer.writeAll("{\"status\":\"busy\",\"accepted\":false,\"message\":\"WebView session fork is blocked while a prompt is active\"}");
            return;
        }
        const entry_id = payload.object.get("entryId").?.string;
        const selected_entry = self.context.session.session_manager.getEntry(entry_id) orelse return error.EntryNotFound;
        if (selected_entry.* != .message or selected_entry.message.message != .user) return error.InvalidSessionTarget;
        const selected_text = try contentBlocksPlainTextAlloc(allocator, selected_entry.message.message.user.content);
        defer allocator.free(selected_text);
        const trimmed = std.mem.trim(u8, selected_text, " \t\r\n");
        const target_leaf_id = selected_entry.message.parent_id;
        const session_dir = self.context.session.session_manager.getSessionDir();

        var next_manager = if (target_leaf_id) |leaf_id|
            try self.context.session.session_manager.createBranchedSession(leaf_id)
        else if (self.context.session.session_manager.getSessionFile() != null and session_dir.len > 0)
            try session_manager_mod.SessionManager.createWithParent(
                self.context.session.allocator,
                self.context.session.io,
                self.context.session.cwd,
                session_dir,
                self.context.session.session_manager.getSessionFile(),
            )
        else
            try session_manager_mod.SessionManager.inMemory(
                self.context.session.allocator,
                self.context.session.io,
                self.context.session.cwd,
            );
        errdefer next_manager.deinit();
        try self.replaceSessionManager(allocator, &next_manager);
        try writer.writeAll("{\"status\":\"forked\",\"accepted\":true,\"entryId\":");
        try writeJsonString(allocator, writer, entry_id);
        try writer.writeAll(",\"sessionId\":");
        try writeJsonString(allocator, writer, self.context.session.session_manager.getSessionId());
        try writer.writeAll(",\"sessionPath\":");
        if (self.context.session.session_manager.getSessionFile()) |path| {
            try writeJsonString(allocator, writer, path);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"editorText\":");
        try writeJsonString(allocator, writer, trimmed);
        try writer.writeAll(",\"sessionTree\":");
        try self.writeSessionTreeState(allocator, writer);
        try writer.writeAll(",\"forkPanel\":");
        try self.writeForkPanelState(allocator, writer);
        try writer.writeAll("}");
    }

    fn availableModelForSelection(
        self: *const BridgeHost,
        provider: []const u8,
        model: []const u8,
    ) ?provider_config.AvailableModel {
        for (self.context.available_models) |entry| {
            if (std.mem.eql(u8, entry.provider, provider) and std.mem.eql(u8, entry.model_id, model)) return entry;
        }
        return null;
    }

    fn storedApiKeyForProvider(self: *const BridgeHost, allocator: std.mem.Allocator, provider: []const u8) !?[]u8 {
        const auth_path = self.context.auth_path orelse return null;
        const stored = try auth.readStoredCredentialsObject(allocator, self.context.session.io, auth_path);
        defer common.deinitJsonValue(allocator, stored);
        if (stored != .object) return null;
        const provider_value = stored.object.get(provider) orelse return null;
        if (provider_value != .object) return null;
        return try auth.buildApiKeyFromStoredEntry(allocator, provider, provider_value.object);
    }

    fn resolveSelectedModel(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        provider: []const u8,
        model: []const u8,
    ) !ResolvedModelSelection {
        const stored_key = try self.storedApiKeyForProvider(allocator, provider);
        defer if (stored_key) |key| allocator.free(key);
        const configured_key = stored_key orelse self.context.configured_credentials.lookup(provider);
        if (self.context.env_map) |env_map| {
            const resolved = try provider_config.resolveProviderConfigAllowMissingCredentials(
                allocator,
                self.context.session.io,
                env_map,
                provider,
                model,
                null,
                configured_key,
            );
            return .{
                .model = resolved.model,
                .api_key = resolved.api_key,
                .auth_status = resolved.auth_status,
                .resolved = resolved,
            };
        }
        const selected_model = if (std.mem.eql(u8, self.context.model.provider, provider) and std.mem.eql(u8, self.context.model.id, model))
            self.context.model
        else
            ai.model_registry.find(provider, model) orelse return error.InvalidModelSelection;
        const available = self.availableModelForSelection(provider, model);
        return .{
            .model = selected_model,
            .api_key = null,
            .auth_status = if (available) |entry| entry.auth_status else if (std.mem.eql(u8, provider, "faux")) .local else .missing,
        };
    }

    fn replaceSessionManager(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        next_manager: *session_manager_mod.SessionManager,
    ) !void {
        var next_context = try next_manager.buildSessionContext(allocator);
        defer next_context.deinit(allocator);

        self.context.session.session_manager.deinit();
        self.context.session.session_manager.* = next_manager.*;
        next_manager.* = undefined;
        try self.context.session.agent.setMessages(next_context.messages);
        self.context.session.agent.session_id = self.context.session.session_manager.getSessionId();
        self.context.no_session = !self.context.session.session_manager.isPersisted();
        if (next_context.model) |model_ref| {
            if (ai.model_registry.find(model_ref.provider, model_ref.model_id)) |restored| {
                self.clearOwnedSelection();
                self.context.provider = restored.provider;
                self.context.model = restored;
                self.context.session.agent.setModel(restored);
            }
        }
    }

    fn writeStartAuthResult(
        self: *const BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        payload: ?std.json.Value,
    ) !void {
        const provider = getPayloadString(payload, "provider") orelse self.context.provider;
        try writer.writeAll("{\"status\":\"auth_flow_ready\",\"accepted\":true,\"provider\":");
        try writeJsonString(allocator, writer, provider);
        try writer.writeAll(",\"displayName\":");
        try writeJsonString(allocator, writer, provider_config.providerDisplayName(provider));
        try writer.writeAll(",\"authType\":");
        const auth_type = if (auth.findSupportedProviderByAuthType(provider, .api_key) != null) "api_key" else "oauth";
        try writeJsonString(allocator, writer, auth_type);
        try writer.writeAll(",\"secretEcho\":false,\"message\":");
        try writeJsonString(allocator, writer, if (std.mem.eql(u8, auth_type, "api_key")) "Enter an API key to save it securely" else "Use the provider login flow; tokens are never shown in WebView responses");
        try writer.writeAll("}");
    }

    fn writeSaveApiKeyResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        payload: std.json.Value,
    ) !void {
        const provider = payload.object.get("provider").?.string;
        const api_key = payload.object.get("apiKey").?.string;
        const auth_path = self.context.auth_path orelse {
            try writer.writeAll("{\"status\":\"unavailable\",\"accepted\":false,\"message\":\"Authentication storage is unavailable in this WebView session\"}");
            return;
        };
        var credential = auth.StoredCredential{ .api_key = try allocator.dupe(u8, api_key) };
        defer credential.deinit(allocator);
        try auth.upsertStoredCredential(allocator, self.context.session.io, auth_path, provider, &credential);
        if (std.mem.eql(u8, provider, self.context.provider)) {
            const next_api_key = try self.context.session.allocator.dupe(u8, api_key);
            if (self.owned_selected_api_key) |old| self.context.session.allocator.free(old);
            self.owned_selected_api_key = next_api_key;
            self.context.session.setApiKey(self.owned_selected_api_key);
            self.context.auth_status = .stored;
            self.context.api_key_present = true;
        }
        try writer.writeAll("{\"status\":\"saved\",\"accepted\":true,\"provider\":");
        try writeJsonString(allocator, writer, provider);
        try writer.writeAll(",\"secretEcho\":false,\"auth\":");
        try self.writeAuthStatusResult(allocator, writer);
        try writer.writeAll("}");
    }

    fn writeRemoveAuthResult(
        self: *BridgeHost,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        payload: std.json.Value,
    ) !void {
        const provider = payload.object.get("provider").?.string;
        const auth_path = self.context.auth_path orelse {
            try writer.writeAll("{\"status\":\"unavailable\",\"accepted\":false,\"message\":\"Authentication storage is unavailable in this WebView session\"}");
            return;
        };
        const removed = try auth.removeStoredCredential(allocator, self.context.session.io, auth_path, provider);
        if (std.mem.eql(u8, provider, self.context.provider)) {
            if (self.owned_selected_api_key) |old| {
                self.context.session.allocator.free(old);
                self.owned_selected_api_key = null;
            }
            self.context.session.setApiKey(null);
            self.context.auth_status = .missing;
            self.context.api_key_present = false;
        }
        try writer.writeAll("{\"status\":\"removed\",\"accepted\":true,\"removed\":");
        try writer.writeAll(if (removed) "true" else "false");
        try writer.writeAll(",\"provider\":");
        try writeJsonString(allocator, writer, provider);
        try writer.writeAll(",\"secretEcho\":false,\"auth\":");
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
            .settings_get, .scoped_models_get, .scoped_models_save, .session_tree_get, .fork_messages_get => {},
            .settings_set => {},
            .thinking_set => {},
            .theme_select => {},
            .scoped_models_update => {},
            .session_tree_label, .session_tree_navigate => {
                const value = payload orelse return error.InvalidSessionTarget;
                const entry_id_value = value.object.get("entryId") orelse return error.InvalidSessionTarget;
                if (entry_id_value != .string or !isValidSessionEntryId(entry_id_value.string)) return error.InvalidSessionTarget;
                if (self.context.session.session_manager.getEntry(entry_id_value.string) == null) return error.InvalidSessionTarget;
                if (command == .session_tree_navigate) {
                    if (value.object.get("summarize")) |summarize| {
                        if (summarize != .bool) return error.InvalidSessionTarget;
                    }
                    if (value.object.get("summaryText")) |summary_text| {
                        if (summary_text != .string) return error.InvalidSessionTarget;
                    }
                }
            },
            .fork_session => {
                const value = payload orelse return error.InvalidSessionTarget;
                const entry_id_value = value.object.get("entryId") orelse return error.InvalidSessionTarget;
                if (entry_id_value != .string or !isValidSessionEntryId(entry_id_value.string)) return error.InvalidSessionTarget;
                const entry = self.context.session.session_manager.getEntry(entry_id_value.string) orelse return error.InvalidSessionTarget;
                if (entry.* != .message or entry.message.message != .user) return error.InvalidSessionTarget;
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

    fn persistSettingValue(self: *BridgeHost, allocator: std.mem.Allocator, id: []const u8, value: []const u8) !void {
        const runtime = self.context.runtime_config orelse return;
        var settings_json = try loadSettingsJsonValue(allocator, self.context.session.io, runtime.agent_dir);
        defer common.deinitJsonValue(allocator, settings_json);
        if (settings_json != .object) {
            common.deinitJsonValue(allocator, settings_json);
            settings_json = .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
        }
        try updateSettingsJsonValue(allocator, &settings_json.object, id, value);
        const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ runtime.agent_dir, "settings.json" });
        defer allocator.free(settings_path);
        const serialized = try std.json.Stringify.valueAlloc(allocator, settings_json, .{ .whitespace = .indent_2 });
        defer allocator.free(serialized);
        try common.writeFileAbsolute(self.context.session.io, settings_path, serialized, true);
        try self.replaceRuntimeSetting(id, value);
    }

    fn replaceRuntimeSetting(self: *BridgeHost, id: []const u8, value: []const u8) !void {
        const runtime = self.context.runtime_config orelse return;
        try applyRuntimeSetting(&runtime.settings, runtime.allocator, id, value);
        try applyRuntimeSetting(&runtime.global_settings, runtime.allocator, id, value);
    }

    fn applySettingSideEffect(self: *BridgeHost, id: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, id, "autocompact")) {
            self.context.session.compaction_settings.enabled = parseBoolText(value);
        } else if (std.mem.eql(u8, id, "steering_mode")) {
            self.context.session.agent.steering_queue.mode = parseQueueMode(value);
        } else if (std.mem.eql(u8, id, "follow_up_mode")) {
            self.context.session.agent.follow_up_queue.mode = parseQueueMode(value);
        }
    }
};

fn permissionDeniedMessage(permission: Permission) []const u8 {
    return switch (permission) {
        .skeleton_chat => "WebView bridge command is disabled by policy",
        .model_selection => "WebView model selection requires explicit model selection permission",
        .session_mutation => "WebView session mutation requires explicit session mutation permission",
        .auth_mutation => "WebView auth mutation requires explicit auth mutation permission",
        .settings_mutation => "WebView settings/theme/scoped-model mutation requires explicit settings mutation permission",
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

fn boolName(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn queueModeName(mode: agent.QueueMode) []const u8 {
    return switch (mode) {
        .all => "all",
        .one_at_a_time => "one-at-a-time",
    };
}

fn transportName(value: ai.types.Transport) []const u8 {
    return switch (value) {
        .sse => "sse",
        .websocket => "websocket",
        .websocket_cached => "websocket-cached",
        .auto => "auto",
    };
}

fn doubleEscapeName(action: config_mod.DoubleEscapeAction) []const u8 {
    return switch (action) {
        .fork => "fork",
        .tree => "tree",
        .none => "none",
    };
}

fn treeFilterName(mode: config_mod.TreeFilterMode) []const u8 {
    return switch (mode) {
        .default => "default",
        .no_tools => "no-tools",
        .user_only => "user-only",
        .labeled_only => "labeled-only",
        .all => "all",
    };
}

fn thinkingName(level: agent.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn thinkingDescription(level: agent.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "No reasoning",
        .minimal => "Very brief reasoning (~1k tokens)",
        .low => "Light reasoning (~2k tokens)",
        .medium => "Moderate reasoning (~8k tokens)",
        .high => "Deep reasoning (~16k tokens)",
        .xhigh => "Maximum reasoning (~32k tokens)",
    };
}

fn parseThinkingLevelName(value: []const u8) ?agent.ThinkingLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return null;
}

fn thinkingLevelAvailable(model: ai.Model, level: agent.ThinkingLevel) bool {
    const mapped: ai.ModelThinkingLevel = switch (level) {
        .off => .off,
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
    };
    return ai.model_registry.isThinkingLevelSupported(model, mapped);
}

fn modelSupportsImages(model: ai.Model) bool {
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) return true;
    }
    return false;
}

fn canonicalThemeName(theme_name: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(theme_name, "night")) return "dark";
    if (std.ascii.eqlIgnoreCase(theme_name, "day")) return "light";
    return theme_name;
}

fn parseBoolText(value: []const u8) bool {
    return std.mem.eql(u8, value, "true");
}

fn parseQueueMode(value: []const u8) agent.QueueMode {
    return if (std.mem.eql(u8, value, "all")) .all else .one_at_a_time;
}

fn settingValueAllowed(id: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, id, "autocompact") or
        std.mem.eql(u8, id, "show_images") or
        std.mem.eql(u8, id, "auto_resize_images") or
        std.mem.eql(u8, id, "block_images") or
        std.mem.eql(u8, id, "skill_commands") or
        std.mem.eql(u8, id, "show_hardware_cursor") or
        std.mem.eql(u8, id, "clear_on_shrink") or
        std.mem.eql(u8, id, "terminal_progress") or
        std.mem.eql(u8, id, "hide_thinking") or
        std.mem.eql(u8, id, "collapse_changelog") or
        std.mem.eql(u8, id, "quiet_startup") or
        std.mem.eql(u8, id, "install_telemetry") or
        std.mem.eql(u8, id, "warnings"))
    {
        return std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false");
    }
    if (std.mem.eql(u8, id, "image_width_cells")) return oneOf(value, &.{ "60", "80", "120" });
    if (std.mem.eql(u8, id, "editor_padding")) return oneOf(value, &.{ "0", "1", "2", "3" });
    if (std.mem.eql(u8, id, "autocomplete_max_visible")) return oneOf(value, &.{ "3", "5", "7", "10", "15", "20" });
    if (std.mem.eql(u8, id, "steering_mode") or std.mem.eql(u8, id, "follow_up_mode")) return oneOf(value, &.{ "one-at-a-time", "all" });
    if (std.mem.eql(u8, id, "transport")) return oneOf(value, &.{ "sse", "websocket", "websocket-cached", "auto" });
    if (std.mem.eql(u8, id, "double_escape_action")) return oneOf(value, &.{ "tree", "fork", "none" });
    if (std.mem.eql(u8, id, "tree_filter_mode")) return oneOf(value, &.{ "default", "no-tools", "user-only", "labeled-only", "all" });
    if (std.mem.eql(u8, id, "theme")) return value.len > 0;
    return false;
}

fn oneOf(value: []const u8, options: []const []const u8) bool {
    for (options) |option| {
        if (std.mem.eql(u8, value, option)) return true;
    }
    return false;
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
        .get_state, .get_messages, .abort, .get_events, .settings_get, .scoped_models_get, .scoped_models_save, .session_tree_get, .fork_messages_get => true,
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
        .settings_set => value.object.get("id") != null and
            value.object.get("id").? == .string and
            value.object.get("value") != null and
            value.object.get("value").? == .string,
        .thinking_set => value.object.get("level") != null and value.object.get("level").? == .string,
        .theme_select => value.object.get("theme") != null and value.object.get("theme").? == .string,
        .scoped_models_update => value.object.get("action") != null and value.object.get("action").? == .string,
        .session_tree_label => value.object.get("entryId") != null and
            value.object.get("entryId").? == .string and
            value.object.get("label") != null and
            value.object.get("label").? == .string,
        .session_tree_navigate => value.object.get("entryId") != null and
            value.object.get("entryId").? == .string and
            (value.object.get("summarize") == null or value.object.get("summarize").? == .bool) and
            (value.object.get("summaryText") == null or value.object.get("summaryText").? == .string),
        .fork_session => value.object.get("entryId") != null and value.object.get("entryId").? == .string,
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

fn isValidSessionEntryId(entry_id: []const u8) bool {
    if (entry_id.len == 0) return false;
    if (entry_id.len > 256) return false;
    return std.mem.indexOfScalar(u8, entry_id, 0) == null;
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
            try writer.writeAll(",\"content\":");
            try writeContentBlocksSummary(allocator, writer, assistant.content);
            try writer.writeAll(",\"stopReason\":");
            try writeJsonString(allocator, writer, @tagName(assistant.stop_reason));
        },
        .tool_result => |tool_result| {
            try writeJsonString(allocator, writer, "toolResult");
            try writer.writeAll(",\"timestamp\":");
            try writer.print("{d}", .{tool_result.timestamp});
            try writer.writeAll(",\"toolCallId\":");
            try writeJsonString(allocator, writer, tool_result.tool_call_id);
            try writer.writeAll(",\"toolName\":");
            try writeJsonString(allocator, writer, tool_result.tool_name);
            try writer.writeAll(",\"text\":");
            try writeJsonString(allocator, writer, firstTextContent(tool_result.content) orelse "");
            try writer.writeAll(",\"content\":");
            try writeContentBlocksSummary(allocator, writer, tool_result.content);
            try writer.writeAll(",\"isError\":");
            try writer.writeAll(if (tool_result.is_error) "true" else "false");
        },
    }
    try writer.writeAll("}");
}

fn writeContentBlocksSummary(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    blocks: []const ai.ContentBlock,
) !void {
    try writer.writeAll("[");
    for (blocks, 0..) |block, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("{\"type\":");
        switch (block) {
            .text => |text| {
                try writeJsonString(allocator, writer, "text");
                try writer.writeAll(",\"text\":");
                try writeJsonString(allocator, writer, text.text);
            },
            .thinking => |thinking| {
                try writeJsonString(allocator, writer, "thinking");
                try writer.writeAll(",\"thinking\":");
                try writeJsonString(allocator, writer, thinking.thinking);
                if (thinking.redacted) {
                    try writer.writeAll(",\"redacted\":true");
                }
            },
            .image => |image| {
                try writeJsonString(allocator, writer, "image");
                try writer.writeAll(",\"mimeType\":");
                try writeJsonString(allocator, writer, image.mime_type);
                try writer.writeAll(",\"dataLength\":");
                try writer.print("{d}", .{image.data.len});
            },
            .tool_call => |tool_call| {
                try writeJsonString(allocator, writer, "toolCall");
                try writer.writeAll(",\"id\":");
                try writeJsonString(allocator, writer, tool_call.id);
                try writer.writeAll(",\"name\":");
                try writeJsonString(allocator, writer, tool_call.name);
                try writer.writeAll(",\"arguments\":");
                try std.json.Stringify.value(tool_call.arguments, .{}, writer);
            },
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn treeSubtreeContains(node: session_manager_mod.SessionTreeNode, needle: ?[]const u8) bool {
    const id = needle orelse return false;
    if (std.mem.eql(u8, node.entry.id(), id)) return true;
    for (node.children) |child| {
        if (treeSubtreeContains(child, id)) return true;
    }
    return false;
}

fn sessionEntryKindName(entry: session_manager_mod.SessionEntry) []const u8 {
    return switch (entry) {
        .message => |message_entry| switch (message_entry.message) {
            .user => "user",
            .assistant => "assistant",
            .tool_result => "tool_result",
        },
        .thinking_level_change => "thinking_level_change",
        .model_change => "model_change",
        .compaction => "compaction",
        .branch_summary => "branch_summary",
        .custom => "custom",
        .custom_message => "custom_message",
        .label => "label",
        .session_info => "session_info",
    };
}

fn sessionEntryIsBookkeeping(entry: session_manager_mod.SessionEntry) bool {
    return switch (entry) {
        .label, .custom, .model_change, .thinking_level_change => true,
        else => false,
    };
}

fn sessionEntryDisplayText(allocator: std.mem.Allocator, entry: session_manager_mod.SessionEntry) ![]u8 {
    return switch (entry) {
        .message => |message_entry| switch (message_entry.message) {
            .user => |user_message| blk: {
                const text = try contentBlocksPlainTextAlloc(allocator, user_message.content);
                defer allocator.free(text);
                break :blk std.fmt.allocPrint(allocator, "user: {s}", .{trimTreeSummaryText(text)});
            },
            .assistant => |assistant_message| blk: {
                const text = try contentBlocksPlainTextAlloc(allocator, assistant_message.content);
                defer allocator.free(text);
                const trimmed = trimTreeSummaryText(text);
                break :blk if (trimmed.len > 0)
                    std.fmt.allocPrint(allocator, "assistant: {s}", .{trimmed})
                else
                    allocator.dupe(u8, "assistant: (no content)");
            },
            .tool_result => |tool_result| blk: {
                const text = try contentBlocksPlainTextAlloc(allocator, tool_result.content);
                defer allocator.free(text);
                break :blk std.fmt.allocPrint(allocator, "[{s}]: {s}", .{ tool_result.tool_name, trimTreeSummaryText(text) });
            },
        },
        .thinking_level_change => |thinking_entry| std.fmt.allocPrint(allocator, "[thinking: {s}]", .{@tagName(thinking_entry.thinking_level)}),
        .model_change => |model_entry| std.fmt.allocPrint(allocator, "[model: {s}/{s}]", .{ model_entry.provider, model_entry.model_id }),
        .compaction => |compaction_entry| std.fmt.allocPrint(allocator, "[compaction: {d}k tokens]", .{compaction_entry.tokens_before / 1000}),
        .branch_summary => |branch_summary_entry| std.fmt.allocPrint(allocator, "[branch summary]: {s}", .{trimTreeSummaryText(branch_summary_entry.summary)}),
        .custom => |custom_entry| std.fmt.allocPrint(allocator, "[custom: {s}]", .{custom_entry.custom_type}),
        .custom_message => |custom_message_entry| blk: {
            const text = switch (custom_message_entry.content) {
                .text => |value| try allocator.dupe(u8, value),
                .blocks => |blocks| try contentBlocksPlainTextAlloc(allocator, blocks),
            };
            defer allocator.free(text);
            break :blk std.fmt.allocPrint(allocator, "[{s}]: {s}", .{ custom_message_entry.custom_type, trimTreeSummaryText(text) });
        },
        .label => |label_entry| if (label_entry.label) |label|
            std.fmt.allocPrint(allocator, "[label: {s}]", .{label})
        else
            allocator.dupe(u8, "[label: (cleared)]"),
        .session_info => |session_info_entry| if (session_info_entry.name) |name|
            std.fmt.allocPrint(allocator, "session name: {s}", .{name})
        else
            allocator.dupe(u8, "session name cleared"),
    };
}

fn contentBlocksPlainTextAlloc(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (blocks) |block| {
        switch (block) {
            .text => |text| try out.writer.writeAll(text.text),
            .thinking => |thinking| try out.writer.writeAll(thinking.thinking),
            .image => |image| try out.writer.print("[Image: {s}]", .{image.mime_type}),
            .tool_call => |tool_call| try out.writer.print("{s}", .{tool_call.name}),
        }
        try out.writer.writeByte('\n');
    }
    return try allocator.dupe(u8, std.mem.trim(u8, out.written(), " \t\r\n"));
}

fn trimTreeSummaryText(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return if (trimmed.len > 72) trimmed[0..72] else trimmed;
}

fn writeSessionSearchInfo(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    entry: session_manager_mod.SessionSearchInfo,
    current_session_path: ?[]const u8,
) !void {
    try writer.writeAll("{");
    try writeStringField(allocator, writer, "id", entry.id, false);
    try writeStringField(allocator, writer, "path", entry.path, true);
    try writeStringField(allocator, writer, "cwd", entry.cwd, true);
    try writer.writeAll(",\"name\":");
    if (entry.name) |name| {
        try writeJsonString(allocator, writer, name);
    } else {
        try writer.writeAll("null");
    }
    try writeStringField(allocator, writer, "created", entry.created_timestamp, true);
    try writeStringField(allocator, writer, "modified", entry.modified_timestamp, true);
    try writeUsizeField(writer, "messageCount", entry.message_count, true);
    try writeStringField(allocator, writer, "firstMessage", entry.first_message, true);
    try writer.writeAll(",\"parentSession\":");
    if (entry.parent_session) |parent| {
        try writeJsonString(allocator, writer, parent);
    } else {
        try writer.writeAll("null");
    }
    try writeBoolField(writer, "current", if (current_session_path) |current| std.mem.eql(u8, current, entry.path) else false, true);
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

fn loadSettingsJsonValue(allocator: std.mem.Allocator, io: std.Io, agent_dir: []const u8) !std.json.Value {
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const content = std.Io.Dir.readFileAlloc(.cwd(), io, settings_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) },
        else => return err,
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch
        return .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    defer parsed.deinit();
    return common.cloneJsonValue(allocator, parsed.value);
}

fn updateSettingsJsonValue(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    id: []const u8,
    value: []const u8,
) !void {
    if (std.mem.eql(u8, id, "autocompact")) return putNestedBool(allocator, object, "compaction", "enabled", parseBoolText(value));
    if (std.mem.eql(u8, id, "show_images")) return putNestedBool(allocator, object, "terminal", "showImages", parseBoolText(value));
    if (std.mem.eql(u8, id, "image_width_cells")) return putNestedInteger(allocator, object, "terminal", "imageWidthCells", try parseUsizeText(value));
    if (std.mem.eql(u8, id, "auto_resize_images")) return putNestedBool(allocator, object, "images", "autoResize", parseBoolText(value));
    if (std.mem.eql(u8, id, "block_images")) return putNestedBool(allocator, object, "images", "blockImages", parseBoolText(value));
    if (std.mem.eql(u8, id, "skill_commands")) return putStringValue(allocator, object, "enableSkillCommands", .{ .bool = parseBoolText(value) });
    if (std.mem.eql(u8, id, "show_hardware_cursor")) return putStringValue(allocator, object, "showHardwareCursor", .{ .bool = parseBoolText(value) });
    if (std.mem.eql(u8, id, "editor_padding")) return putStringValue(allocator, object, "editorPaddingX", .{ .integer = @intCast(try parseUsizeText(value)) });
    if (std.mem.eql(u8, id, "autocomplete_max_visible")) return putStringValue(allocator, object, "autocompleteMaxVisible", .{ .integer = @intCast(try parseUsizeText(value)) });
    if (std.mem.eql(u8, id, "clear_on_shrink")) return putNestedBool(allocator, object, "terminal", "clearOnShrink", parseBoolText(value));
    if (std.mem.eql(u8, id, "terminal_progress")) return putNestedBool(allocator, object, "terminal", "showTerminalProgress", parseBoolText(value));
    if (std.mem.eql(u8, id, "steering_mode")) return putOwnedString(allocator, object, "steeringMode", value);
    if (std.mem.eql(u8, id, "follow_up_mode")) return putOwnedString(allocator, object, "followUpMode", value);
    if (std.mem.eql(u8, id, "transport")) return putOwnedString(allocator, object, "transport", value);
    if (std.mem.eql(u8, id, "hide_thinking")) return putStringValue(allocator, object, "hideThinkingBlock", .{ .bool = parseBoolText(value) });
    if (std.mem.eql(u8, id, "collapse_changelog")) return putStringValue(allocator, object, "collapseChangelog", .{ .bool = parseBoolText(value) });
    if (std.mem.eql(u8, id, "quiet_startup")) return putStringValue(allocator, object, "quietStartup", .{ .bool = parseBoolText(value) });
    if (std.mem.eql(u8, id, "install_telemetry")) return putStringValue(allocator, object, "enableInstallTelemetry", .{ .bool = parseBoolText(value) });
    if (std.mem.eql(u8, id, "double_escape_action")) return putOwnedString(allocator, object, "doubleEscapeAction", value);
    if (std.mem.eql(u8, id, "tree_filter_mode")) return putOwnedString(allocator, object, "treeFilterMode", value);
    if (std.mem.eql(u8, id, "theme")) return putOwnedString(allocator, object, "theme", value);
    if (std.mem.eql(u8, id, "warnings")) return putNestedBool(allocator, object, "warnings", "anthropicExtraUsage", parseBoolText(value));
}

fn putOwnedString(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try putStringValue(allocator, object, key, .{ .string = try allocator.dupe(u8, value) });
}

fn putNestedBool(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, nested_key: []const u8, value: bool) !void {
    const nested = try ensureNestedObject(allocator, object, key);
    try putStringValue(allocator, nested, nested_key, .{ .bool = value });
}

fn putNestedInteger(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, nested_key: []const u8, value: usize) !void {
    const nested = try ensureNestedObject(allocator, object, key);
    try putStringValue(allocator, nested, nested_key, .{ .integer = @intCast(value) });
}

fn ensureNestedObject(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8) !*std.json.ObjectMap {
    if (object.getPtr(key)) |existing| {
        if (existing.* != .object) {
            common.deinitJsonValue(allocator, existing.*);
            existing.* = .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
        }
        return &existing.object;
    }
    try object.put(allocator, try allocator.dupe(u8, key), .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) });
    return &object.getPtr(key).?.object;
}

fn putStringValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    if (object.getPtr(key)) |existing| {
        common.deinitJsonValue(allocator, existing.*);
        existing.* = value;
        return;
    }
    try object.put(allocator, try allocator.dupe(u8, key), value);
}

fn parseUsizeText(value: []const u8) !usize {
    return try std.fmt.parseInt(usize, value, 10);
}

fn applyRuntimeSetting(settings: *config_mod.Settings, allocator: std.mem.Allocator, id: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, id, "autocompact")) {
        var compaction = settings.compaction orelse session_mod.CompactionSettings{};
        compaction.enabled = parseBoolText(value);
        settings.compaction = compaction;
    } else if (std.mem.eql(u8, id, "show_images")) {
        settings.terminal_show_images = parseBoolText(value);
    } else if (std.mem.eql(u8, id, "image_width_cells")) {
        settings.terminal_image_width_cells = try parseUsizeText(value);
    } else if (std.mem.eql(u8, id, "auto_resize_images")) {
        settings.image_auto_resize = parseBoolText(value);
    } else if (std.mem.eql(u8, id, "block_images")) {
        settings.image_block_images = parseBoolText(value);
    } else if (std.mem.eql(u8, id, "skill_commands")) {
        settings.enable_skill_commands = parseBoolText(value);
    } else if (std.mem.eql(u8, id, "show_hardware_cursor")) {
        settings.show_hardware_cursor = parseBoolText(value);
    } else if (std.mem.eql(u8, id, "editor_padding")) {
        settings.editor_padding_x = try parseUsizeText(value);
    } else if (std.mem.eql(u8, id, "autocomplete_max_visible")) {
        settings.autocomplete_max_visible = try parseUsizeText(value);
    } else if (std.mem.eql(u8, id, "clear_on_shrink")) {
        settings.terminal_clear_on_shrink = parseBoolText(value);
    } else if (std.mem.eql(u8, id, "terminal_progress")) {
        settings.terminal_show_progress = parseBoolText(value);
    } else if (std.mem.eql(u8, id, "steering_mode")) {
        settings.steering_mode = if (std.mem.eql(u8, value, "all")) .all else .one_at_a_time;
    } else if (std.mem.eql(u8, id, "follow_up_mode")) {
        settings.follow_up_mode = if (std.mem.eql(u8, value, "all")) .all else .one_at_a_time;
    } else if (std.mem.eql(u8, id, "transport")) {
        settings.transport = parseTransport(value);
    } else if (std.mem.eql(u8, id, "hide_thinking")) {
        settings.hide_thinking_block = parseBoolText(value);
    } else if (std.mem.eql(u8, id, "collapse_changelog")) {
        settings.collapse_changelog = parseBoolText(value);
    } else if (std.mem.eql(u8, id, "quiet_startup")) {
        settings.quiet_startup = parseBoolText(value);
    } else if (std.mem.eql(u8, id, "install_telemetry")) {
        settings.enable_install_telemetry = parseBoolText(value);
    } else if (std.mem.eql(u8, id, "double_escape_action")) {
        settings.double_escape_action = parseDoubleEscape(value);
    } else if (std.mem.eql(u8, id, "tree_filter_mode")) {
        settings.tree_filter_mode = parseTreeFilter(value);
    } else if (std.mem.eql(u8, id, "warnings")) {
        settings.warning_anthropic_extra_usage = parseBoolText(value);
    } else if (std.mem.eql(u8, id, "theme")) {
        if (settings.theme) |old| allocator.free(old);
        settings.theme = try allocator.dupe(u8, value);
    }
}

fn parseTransport(value: []const u8) ai.types.Transport {
    if (std.mem.eql(u8, value, "sse")) return .sse;
    if (std.mem.eql(u8, value, "websocket")) return .websocket;
    if (std.mem.eql(u8, value, "websocket-cached")) return .websocket_cached;
    return .auto;
}

fn parseDoubleEscape(value: []const u8) config_mod.DoubleEscapeAction {
    if (std.mem.eql(u8, value, "fork")) return .fork;
    if (std.mem.eql(u8, value, "none")) return .none;
    return .tree;
}

fn parseTreeFilter(value: []const u8) config_mod.TreeFilterMode {
    if (std.mem.eql(u8, value, "no-tools")) return .no_tools;
    if (std.mem.eql(u8, value, "user-only")) return .user_only;
    if (std.mem.eql(u8, value, "labeled-only")) return .labeled_only;
    if (std.mem.eql(u8, value, "all")) return .all;
    return .default;
}

fn persistEnabledModels(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_config: *config_mod.RuntimeConfig,
    enabled_ids: ?[]const []const u8,
) !void {
    var settings_json = try loadSettingsJsonValue(allocator, io, runtime_config.agent_dir);
    defer common.deinitJsonValue(allocator, settings_json);
    if (settings_json != .object) {
        common.deinitJsonValue(allocator, settings_json);
        settings_json = .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    }
    if (enabled_ids) |ids| {
        var array = std.json.Array.init(allocator);
        errdefer array.deinit();
        for (ids) |id| {
            try array.append(.{ .string = try allocator.dupe(u8, id) });
        }
        try putStringValue(allocator, &settings_json.object, "enabledModels", .{ .array = array });
    } else {
        try putStringValue(allocator, &settings_json.object, "enabledModels", .null);
    }
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ runtime_config.agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const serialized = try std.json.Stringify.valueAlloc(allocator, settings_json, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);
    try common.writeFileAbsolute(io, settings_path, serialized, true);
}

fn scopedModelFullId(allocator: std.mem.Allocator, model: provider_config.AvailableModel) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ model.provider, model.model_id });
}

fn indexOfString(items: []const []const u8, needle: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item, needle)) return index;
    }
    return null;
}

fn scopedIdEnabled(enabled_ids: ?[][]u8, id: []const u8) bool {
    const ids = enabled_ids orelse return true;
    return indexOfString(ids, id) != null;
}

fn appendUniqueOwned(allocator: std.mem.Allocator, items: *[][]u8, value: []const u8) !void {
    if (indexOfString(items.*, value) != null) return;
    const next = try allocator.realloc(items.*, items.*.len + 1);
    next[next.len - 1] = try allocator.dupe(u8, value);
    items.* = next;
}

fn clonedExcludingIds(allocator: std.mem.Allocator, source: []const []const u8, excluded: []const []const u8) ![][]u8 {
    var result = std.ArrayList([]u8).empty;
    errdefer freeOwnedStringList(allocator, result.items);
    for (source) |item| {
        if (indexOfString(excluded, item) == null) try result.append(allocator, try allocator.dupe(u8, item));
    }
    return try result.toOwnedSlice(allocator);
}

fn cloneStringListAsMutable(allocator: std.mem.Allocator, source: []const []const u8) ![][]u8 {
    var result = try allocator.alloc([]u8, source.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |item| allocator.free(item);
        allocator.free(result);
    }
    for (source, 0..) |item, index| {
        result[index] = try allocator.dupe(u8, item);
        initialized += 1;
    }
    return result;
}

fn cloneStringListConst(allocator: std.mem.Allocator, source: ?[][]u8) !?[]const []const u8 {
    const ids = source orelse return null;
    const result = try allocator.alloc([]const u8, ids.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |item| allocator.free(@constCast(item));
        allocator.free(result);
    }
    for (ids, 0..) |item, index| {
        result[index] = try allocator.dupe(u8, item);
        initialized += 1;
    }
    return result;
}

fn freeOwnedStringList(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn freeConstStringList(allocator: std.mem.Allocator, items: ?[]const []const u8) void {
    const list = items orelse return;
    for (list) |item| allocator.free(@constCast(item));
    allocator.free(list);
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
    try std.testing.expectEqual(@as(usize, 25), command_table.len);
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
    try std.testing.expectEqual(@as(usize, 25), command_table.len);
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
    try std.testing.expectEqual(@as(usize, 25), command_table.len);
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
    try arguments.put(allocator, try allocator.dupe(u8, "command"), .{ .string = try allocator.dupe(u8, "printf structured") });
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
    try std.testing.expectEqual(@as(usize, 0), counters.total());
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
    try std.testing.expectEqual(@as(usize, 0), counters.total());
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
