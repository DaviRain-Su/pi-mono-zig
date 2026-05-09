const std = @import("std");
const ai = @import("ai");
const string_utils = ai.shared.string_utils;
const agent = @import("agent");
const extension_runtime = @import("../extensions/extension_runtime.zig");
const native_runtime = @import("../extensions/native_runtime.zig");
const sdk = @import("../extensions/sdk.zig");
const wasm_manifest = @import("../extensions/wasm/wasm_manifest.zig");
const json_event_wire = @import("../modes/json_event_wire.zig");
const session_manager = @import("session_manager.zig");
const tools_common = @import("../tools/common.zig");

pub const CompactionSettings = struct {
    enabled: bool = false,
    reserve_tokens: u32 = 4096,
    keep_recent_tokens: u32 = 20000,
};

pub const RetrySettings = struct {
    enabled: bool = false,
    max_retries: u32 = 2,
    base_delay_ms: u64 = 1000,
};

pub const RetryLifecycleEvent = union(enum) {
    start: struct {
        attempt: u32,
        max_attempts: u32,
        delay_ms: u64,
        error_message: []const u8,
    },
    end: struct {
        success: bool,
        attempt: u32,
        final_error: ?[]const u8 = null,
    },
};

pub const RetryLifecycleCallback = struct {
    context: ?*anyopaque = null,
    callback: *const fn (context: ?*anyopaque, event: RetryLifecycleEvent) anyerror!void,
};

pub const CompactionReason = enum {
    manual,
    threshold,
    overflow,
};

pub const CompactionLifecycleEvent = union(enum) {
    start: struct {
        reason: CompactionReason,
    },
    end: struct {
        reason: CompactionReason,
        result: ?CompactionResult = null,
        aborted: bool = false,
        will_retry: bool = false,
        error_message: ?[]const u8 = null,
    },
};

pub const CompactionLifecycleCallback = struct {
    context: ?*anyopaque = null,
    callback: *const fn (context: ?*anyopaque, event: CompactionLifecycleEvent) anyerror!void,
};

pub const CompactionResult = struct {
    summary: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u32,
};

pub const QueuedInput = struct {
    text: []u8,
    images: []ai.ImageContent,

    pub fn deinit(self: *QueuedInput, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.images) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        allocator.free(self.images);
        self.* = undefined;
    }
};

pub const ClearedQueue = struct {
    steering: []QueuedInput,
    follow_up: []QueuedInput,

    pub fn count(self: ClearedQueue) usize {
        return self.steering.len + self.follow_up.len;
    }

    pub fn deinit(self: *ClearedQueue, allocator: std.mem.Allocator) void {
        for (self.steering) |*item| item.deinit(allocator);
        allocator.free(self.steering);
        for (self.follow_up) |*item| item.deinit(allocator);
        allocator.free(self.follow_up);
        self.* = undefined;
    }
};

pub const AgentSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    system_prompt: []const u8,
    agent: agent.Agent,
    session_manager: *session_manager.SessionManager,
    subscriber: agent.AgentSubscriber,
    subscribed: bool,
    extension_event_subscriber: agent.AgentSubscriber,
    extension_event_subscribed: bool,
    compaction_settings: CompactionSettings,
    retry_settings: RetrySettings,
    retry_attempt: u32,
    retry_lifecycle_callback: ?RetryLifecycleCallback,
    compaction_lifecycle_callback: ?CompactionLifecycleCallback,
    retry_abort_requested: std.atomic.Value(bool),
    retry_delay_active: std.atomic.Value(bool),
    overflow_recovery_attempted: bool,
    compaction_active: std.atomic.Value(bool),
    extension_hook_context: ?*ExtensionHookContext,

    pub const CreateOptions = struct {
        cwd: []const u8,
        system_prompt: []const u8 = "",
        model: ?ai.Model = null,
        api_key: ?[]const u8 = null,
        thinking_level: agent.ThinkingLevel = .off,
        tools: []const agent.AgentTool = &.{},
        session_dir: ?[]const u8 = null,
        compaction: CompactionSettings = .{},
        retry: RetrySettings = .{},
        extension_hosts: []const extension_runtime.RuntimeAdapter = &.{},
        extension_hook_timeout_ms: u64 = 1000,
    };

    pub const OpenOptions = struct {
        session_file: []const u8,
        cwd_override: ?[]const u8 = null,
        system_prompt: []const u8 = "",
        model: ?ai.Model = null,
        api_key: ?[]const u8 = null,
        thinking_level: agent.ThinkingLevel = .off,
        tools: []const agent.AgentTool = &.{},
        compaction: CompactionSettings = .{},
        retry: RetrySettings = .{},
        extension_hosts: []const extension_runtime.RuntimeAdapter = &.{},
        extension_hook_timeout_ms: u64 = 1000,
    };

    pub const ManagedOptions = struct {
        cwd: []const u8,
        system_prompt: []const u8 = "",
        model: ?ai.Model = null,
        api_key: ?[]const u8 = null,
        thinking_level: agent.ThinkingLevel = .off,
        tools: []const agent.AgentTool = &.{},
        compaction: CompactionSettings = .{},
        retry: RetrySettings = .{},
        extension_hosts: []const extension_runtime.RuntimeAdapter = &.{},
        extension_hook_timeout_ms: u64 = 1000,
    };

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: CreateOptions,
    ) !AgentSession {
        const manager = try allocator.create(session_manager.SessionManager);
        errdefer allocator.destroy(manager);
        manager.* = if (options.session_dir) |session_dir|
            try session_manager.SessionManager.create(allocator, io, options.cwd, session_dir)
        else
            try session_manager.SessionManager.inMemory(allocator, io, options.cwd);
        errdefer manager.deinit();

        var instance = try initWithManager(
            allocator,
            io,
            options.cwd,
            options.system_prompt,
            options.model,
            options.api_key,
            options.thinking_level,
            options.tools,
            options.compaction,
            options.retry,
            options.extension_hosts,
            options.extension_hook_timeout_ms,
            manager,
            "startup",
        );
        if (options.model) |model| {
            _ = try instance.session_manager.appendModelChange(model.provider, model.id);
        }
        if (options.thinking_level != .off) {
            _ = try instance.session_manager.appendThinkingLevelChange(options.thinking_level);
        }
        return instance;
    }

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: OpenOptions,
    ) !AgentSession {
        const manager = try allocator.create(session_manager.SessionManager);
        errdefer allocator.destroy(manager);
        manager.* = try session_manager.SessionManager.open(allocator, io, options.session_file, options.cwd_override);
        errdefer manager.deinit();

        const effective_cwd = options.cwd_override orelse manager.getCwd();
        return initWithManager(
            allocator,
            io,
            effective_cwd,
            options.system_prompt,
            options.model,
            options.api_key,
            options.thinking_level,
            options.tools,
            options.compaction,
            options.retry,
            options.extension_hosts,
            options.extension_hook_timeout_ms,
            manager,
            "resume",
        );
    }

    /// Takes ownership of `manager`. Caller must destroy the manager pointer if
    /// this function returns an error.
    pub fn createWithManager(
        allocator: std.mem.Allocator,
        io: std.Io,
        manager: *session_manager.SessionManager,
        options: ManagedOptions,
    ) !AgentSession {
        return initWithManager(
            allocator,
            io,
            options.cwd,
            options.system_prompt,
            options.model,
            options.api_key,
            options.thinking_level,
            options.tools,
            options.compaction,
            options.retry,
            options.extension_hosts,
            options.extension_hook_timeout_ms,
            manager,
            "startup",
        );
    }

    pub fn deinit(self: *AgentSession) void {
        self.emitSessionShutdown("quit") catch {};
        if (self.subscribed) {
            _ = self.agent.unsubscribe(self.subscriber);
            self.subscribed = false;
        }
        if (self.extension_event_subscribed) {
            _ = self.agent.unsubscribe(self.extension_event_subscriber);
            self.extension_event_subscribed = false;
        }
        self.agent.deinit();
        if (self.extension_hook_context) |hook_context| {
            hook_context.deinit(self.allocator);
            self.allocator.destroy(hook_context);
            self.extension_hook_context = null;
        }
        self.session_manager.deinit();
        self.allocator.destroy(self.session_manager);
    }

    pub fn prompt(self: *AgentSession, input: anytype) !void {
        if (try self.runHookedPrompt(input, null)) return;
        try self.agent.prompt(input);
        try self.runPostPromptMaintenance();
        try self.flushExtensionHookDiagnostics();
    }

    pub fn promptWithAcceptedCallback(
        self: *AgentSession,
        input: anytype,
        accepted_callback: ?agent.PromptAcceptedCallback,
    ) !void {
        if (try self.runHookedPrompt(input, accepted_callback)) return;
        try self.agent.promptWithAcceptedCallback(input, accepted_callback);
        try self.runPostPromptMaintenance();
        try self.flushExtensionHookDiagnostics();
    }

    pub fn steer(self: *AgentSession, text: []const u8, images: []const ai.ImageContent) !void {
        var message = try queuedUserMessage(self.allocator, text, images);
        defer deinitQueuedUserMessage(self.allocator, &message);
        try self.agent.steer(message);
    }

    pub fn followUp(self: *AgentSession, text: []const u8, images: []const ai.ImageContent) !void {
        var message = try queuedUserMessage(self.allocator, text, images);
        defer deinitQueuedUserMessage(self.allocator, &message);
        try self.agent.followUp(message);
    }

    pub fn clearQueue(self: *AgentSession, allocator: std.mem.Allocator) !ClearedQueue {
        const steering_messages = try self.agent.takeSteeringMessages(allocator);
        defer {
            agent.deinitMessageSlice(allocator, steering_messages);
            allocator.free(steering_messages);
        }

        const follow_up_messages = try self.agent.takeFollowUpMessages(allocator);
        defer {
            agent.deinitMessageSlice(allocator, follow_up_messages);
            allocator.free(follow_up_messages);
        }

        return .{
            .steering = try queuedInputsFromMessages(allocator, steering_messages),
            .follow_up = try queuedInputsFromMessages(allocator, follow_up_messages),
        };
    }

    pub fn isStreaming(self: *const AgentSession) bool {
        return self.agent.isStreaming();
    }

    pub fn isCompacting(self: *const AgentSession) bool {
        return self.compaction_active.load(.seq_cst);
    }

    pub fn compact(self: *AgentSession, custom_instructions: ?[]const u8) !CompactionResult {
        return try self.runCompactionWithLifecycle(.manual, custom_instructions, false);
    }

    pub fn setRetryLifecycleCallback(self: *AgentSession, callback: RetryLifecycleCallback) void {
        self.retry_lifecycle_callback = callback;
    }

    pub fn clearRetryLifecycleCallback(self: *AgentSession) void {
        self.retry_lifecycle_callback = null;
    }

    pub fn setExtensionHosts(self: *AgentSession, extension_hosts: []const extension_runtime.RuntimeAdapter, timeout_ms: u64) !void {
        if (self.extension_event_subscribed) {
            _ = self.agent.unsubscribe(self.extension_event_subscriber);
            self.extension_event_subscribed = false;
        }
        if (self.extension_hook_context) |hook_context| {
            hook_context.deinit(self.allocator);
            self.allocator.destroy(hook_context);
            self.extension_hook_context = null;
        }
        if (extension_hosts.len == 0) {
            self.agent.transform_context = null;
            self.agent.transform_context_context = null;
            self.agent.message_end_transform = null;
            self.agent.message_end_transform_context = null;
            self.agent.before_tool_call = null;
            self.agent.after_tool_call = null;
            self.agent.extension_hook_context = null;
            return;
        }
        const context = try self.allocator.create(ExtensionHookContext);
        context.* = .{
            .allocator = self.allocator,
            .hosts = extension_hosts,
            .timeout_ms = timeout_ms,
            .diagnostics = .empty,
        };
        self.extension_hook_context = context;
        self.agent.transform_context = transformContextHook;
        self.agent.transform_context_context = context;
        self.agent.message_end_transform = messageEndHook;
        self.agent.message_end_transform_context = context;
        self.agent.before_tool_call = beforeToolCallHook;
        self.agent.after_tool_call = afterToolCallHook;
        self.agent.extension_hook_context = context;
        self.extension_event_subscriber = .{
            .context = context,
            .callback = handleExtensionLifecycleEvent,
        };
        try self.agent.subscribe(self.extension_event_subscriber);
        self.extension_event_subscribed = true;
    }

    pub fn setCompactionLifecycleCallback(self: *AgentSession, callback: CompactionLifecycleCallback) void {
        self.compaction_lifecycle_callback = callback;
    }

    pub fn clearCompactionLifecycleCallback(self: *AgentSession) void {
        self.compaction_lifecycle_callback = null;
    }

    pub fn abortRetry(self: *AgentSession) void {
        self.retry_abort_requested.store(true, .seq_cst);
    }

    pub fn isRetrying(self: *const AgentSession) bool {
        return self.retry_delay_active.load(.seq_cst);
    }

    pub fn navigateTo(self: *AgentSession, entry_id: ?[]const u8) !void {
        if (entry_id) |id| {
            try self.session_manager.branch(id);
        } else {
            self.session_manager.resetLeaf();
        }
        try self.reloadFromSession();
    }

    pub const NavigateTreeOptions = struct {
        summarize: bool = false,
        summary_text: ?[]const u8 = null,
        label: ?[]const u8 = null,
    };

    pub const NavigateTreeResult = struct {
        editor_text: ?[]u8 = null,
        summary_entry_id: ?[]const u8 = null,

        pub fn deinit(self: *NavigateTreeResult, allocator: std.mem.Allocator) void {
            if (self.editor_text) |text| allocator.free(text);
            self.* = .{};
        }
    };

    pub fn navigateTree(
        self: *AgentSession,
        allocator: std.mem.Allocator,
        target_id: []const u8,
        options: NavigateTreeOptions,
    ) !NavigateTreeResult {
        if (self.session_manager.getLeafId()) |leaf_id| {
            if (std.mem.eql(u8, leaf_id, target_id)) return .{};
        }

        const target_entry = self.session_manager.getEntry(target_id) orelse return error.EntryNotFound;
        const new_leaf_id = treeNavigationLeaf(target_entry);
        const editor_text = try treeNavigationEditorText(allocator, target_entry);
        errdefer if (editor_text) |text| allocator.free(text);

        var summary_entry_id: ?[]const u8 = null;
        if (options.summarize) {
            const summary = options.summary_text orelse "Branch summary";
            summary_entry_id = try self.session_manager.branchWithSummary(new_leaf_id, summary, null, false);
            if (options.label) |label| {
                _ = try self.session_manager.appendLabelChange(summary_entry_id.?, label);
            }
        } else if (new_leaf_id) |id| {
            try self.session_manager.branch(id);
            if (options.label) |label| {
                _ = try self.session_manager.appendLabelChange(target_id, label);
            }
        } else {
            self.session_manager.resetLeaf();
            if (options.label) |label| {
                _ = try self.session_manager.appendLabelChange(target_id, label);
            }
        }

        try self.reloadFromSession();
        return .{
            .editor_text = editor_text,
            .summary_entry_id = summary_entry_id,
        };
    }

    pub fn setThinkingLevel(self: *AgentSession, thinking_level: agent.ThinkingLevel) !void {
        self.agent.setThinkingLevel(thinking_level);
        _ = try self.session_manager.appendThinkingLevelChange(thinking_level);
    }

    pub fn setModel(self: *AgentSession, model: ai.Model) !void {
        self.agent.setModel(model);
        _ = try self.session_manager.appendModelChange(model.provider, model.id);
    }

    pub fn setApiKey(self: *AgentSession, api_key: ?[]const u8) void {
        self.agent.setApiKey(api_key);
    }

    fn runPostPromptMaintenance(self: *AgentSession) !void {
        while (true) {
            const last_assistant = findLastAssistantMessage(self.agent.getMessages()) orelse {
                self.retry_attempt = 0;
                self.overflow_recovery_attempted = false;
                return;
            };

            if (last_assistant.stop_reason != .error_reason) {
                if (self.retry_attempt > 0) {
                    try self.emitRetryLifecycleEvent(.{ .end = .{
                        .success = true,
                        .attempt = self.retry_attempt,
                    } });
                }
                self.retry_attempt = 0;
                self.overflow_recovery_attempted = false;
            }

            if (try self.handleOverflowCompaction(last_assistant)) continue;
            if (try self.handleRetryableError(last_assistant)) continue;
            if (try self.handleThresholdCompaction(last_assistant)) continue;
            return;
        }
    }

    fn handleOverflowCompaction(self: *AgentSession, last_assistant: ai.AssistantMessage) !bool {
        if (!self.compaction_settings.enabled) return false;
        if (!isContextOverflow(last_assistant, self.agent.getModel().context_window)) return false;
        if (self.overflow_recovery_attempted) return false;

        self.overflow_recovery_attempted = true;
        _ = removeLastAssistantError(self);
        _ = try self.runCompactionWithLifecycle(.overflow, null, true);
        try self.agent.continueRun();
        return true;
    }

    fn handleThresholdCompaction(self: *AgentSession, last_assistant: ai.AssistantMessage) !bool {
        _ = last_assistant;
        if (!self.compaction_settings.enabled) return false;
        const context_window = self.agent.getModel().context_window;
        if (context_window == 0) return false;
        if (!shouldAutoCompact(estimateContextTokens(self.agent.getMessages()), context_window, self.compaction_settings)) return false;
        _ = self.runCompactionWithLifecycle(.threshold, null, false) catch |err| switch (err) {
            error.NothingToCompact => return false,
            else => return err,
        };
        if (self.agent.hasQueuedMessages()) {
            try self.agent.continueRun();
            return true;
        }
        return false;
    }

    fn handleRetryableError(self: *AgentSession, last_assistant: ai.AssistantMessage) !bool {
        if (!self.retry_settings.enabled) return false;
        if (!isRetryableError(last_assistant, self.agent.getModel().context_window)) return false;

        self.retry_attempt += 1;
        if (self.retry_attempt > self.retry_settings.max_retries) {
            try self.emitRetryLifecycleEvent(.{ .end = .{
                .success = false,
                .attempt = self.retry_attempt - 1,
                .final_error = last_assistant.error_message,
            } });
            self.retry_attempt = 0;
            return false;
        }

        const error_message = last_assistant.error_message orelse "Unknown error";
        const delay_ms = exponentialBackoffMs(self.retry_settings.base_delay_ms, self.retry_attempt);
        try self.emitRetryLifecycleEvent(.{ .start = .{
            .attempt = self.retry_attempt,
            .max_attempts = self.retry_settings.max_retries,
            .delay_ms = delay_ms,
            .error_message = error_message,
        } });

        _ = removeLastAssistantError(self);
        const slept = try self.sleepRetryDelay(delay_ms);
        if (!slept) {
            const cancelled_attempt = self.retry_attempt;
            self.retry_attempt = 0;
            try self.emitRetryLifecycleEvent(.{ .end = .{
                .success = false,
                .attempt = cancelled_attempt,
                .final_error = "Retry cancelled",
            } });
            return false;
        }
        try self.agent.continueRun();
        return true;
    }

    fn emitRetryLifecycleEvent(self: *AgentSession, event: RetryLifecycleEvent) !void {
        if (self.retry_lifecycle_callback) |callback| {
            try callback.callback(callback.context, event);
        }
    }

    fn emitCompactionLifecycleEvent(self: *AgentSession, event: CompactionLifecycleEvent) !void {
        if (self.compaction_lifecycle_callback) |callback| {
            try callback.callback(callback.context, event);
        }
    }

    fn sleepRetryDelay(self: *AgentSession, delay_ms: u64) !bool {
        self.retry_abort_requested.store(false, .seq_cst);
        self.retry_delay_active.store(true, .seq_cst);
        defer self.retry_delay_active.store(false, .seq_cst);

        var remaining = delay_ms;
        while (remaining > 0) {
            if (self.retry_abort_requested.load(.seq_cst)) return false;
            const step = @min(remaining, @as(u64, 10));
            try sleepMilliseconds(self.io, step);
            remaining -= step;
        }
        return !self.retry_abort_requested.load(.seq_cst);
    }

    fn runCompactionWithLifecycle(
        self: *AgentSession,
        reason: CompactionReason,
        custom_instructions: ?[]const u8,
        will_retry: bool,
    ) !CompactionResult {
        try self.emitCompactionLifecycleEvent(.{ .start = .{ .reason = reason } });
        const result = self.runCompaction(custom_instructions) catch |err| {
            try self.emitCompactionLifecycleEvent(.{ .end = .{
                .reason = reason,
                .result = null,
                .aborted = false,
                .will_retry = false,
                .error_message = @errorName(err),
            } });
            return err;
        };
        try self.emitCompactionLifecycleEvent(.{ .end = .{
            .reason = reason,
            .result = result,
            .aborted = false,
            .will_retry = will_retry,
            .error_message = null,
        } });
        return result;
    }

    fn runCompaction(self: *AgentSession, custom_instructions: ?[]const u8) !CompactionResult {
        self.compaction_active.store(true, .seq_cst);
        defer self.compaction_active.store(false, .seq_cst);

        const branch_entries = try self.session_manager.getBranch(self.allocator, null);
        defer self.allocator.free(branch_entries);

        const preparation = prepareCompaction(branch_entries, self.compaction_settings.keep_recent_tokens) orelse
            prepareManualCompaction(branch_entries) orelse
            return error.NothingToCompact;

        const summary = try buildCompactionSummary(
            self.allocator,
            branch_entries,
            preparation.summary_start_index,
            preparation.first_kept_entry_index,
            custom_instructions,
        );
        defer self.allocator.free(summary);

        const first_kept_entry_id = branch_entries[preparation.first_kept_entry_index].id();
        const compaction_id = try self.session_manager.appendCompaction(
            summary,
            first_kept_entry_id,
            preparation.tokens_before,
        );
        try self.reloadFromSession();

        const entry = self.session_manager.getEntry(compaction_id) orelse return error.InvalidSessionTree;
        if (entry.* != .compaction) return error.InvalidSessionTree;
        return .{
            .summary = try session_manager.getCompactionSummary(entry.compaction),
            .first_kept_entry_id = entry.compaction.first_kept_entry_id,
            .tokens_before = entry.compaction.tokens_before,
        };
    }

    fn initWithManager(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        system_prompt: []const u8,
        model: ?ai.Model,
        api_key: ?[]const u8,
        thinking_level: agent.ThinkingLevel,
        tools: []const agent.AgentTool,
        compaction_settings: CompactionSettings,
        retry_settings: RetrySettings,
        extension_hosts: []const extension_runtime.RuntimeAdapter,
        extension_hook_timeout_ms: u64,
        manager: *session_manager.SessionManager,
        lifecycle_reason: []const u8,
    ) !AgentSession {
        var session_context = try manager.buildSessionContext(allocator);
        defer session_context.deinit(allocator);

        const effective_model = resolveModel(model, session_context.model);
        const effective_thinking_level = if (session_context.thinking_level != .off)
            session_context.thinking_level
        else
            thinking_level;

        const extension_hook_context: ?*ExtensionHookContext = if (extension_hosts.len > 0) blk: {
            const context = try allocator.create(ExtensionHookContext);
            context.* = .{
                .allocator = allocator,
                .hosts = extension_hosts,
                .timeout_ms = extension_hook_timeout_ms,
                .diagnostics = .empty,
            };
            break :blk context;
        } else null;
        errdefer if (extension_hook_context) |context| {
            context.deinit(allocator);
            allocator.destroy(context);
        };

        var agent_instance = try agent.Agent.init(allocator, .{
            .system_prompt = system_prompt,
            .model = effective_model,
            .api_key = api_key,
            .session_id = manager.getSessionId(),
            .thinking_level = effective_thinking_level,
            .tools = tools,
            .messages = session_context.messages,
            .io = io,
            .transform_context = if (extension_hook_context != null) transformContextHook else null,
            .transform_context_context = if (extension_hook_context) |context| context else null,
            .message_end_transform = if (extension_hook_context != null) messageEndHook else null,
            .message_end_transform_context = if (extension_hook_context) |context| context else null,
            .before_tool_call = if (extension_hook_context != null) beforeToolCallHook else null,
            .after_tool_call = if (extension_hook_context != null) afterToolCallHook else null,
            .extension_hook_context = if (extension_hook_context) |context| context else null,
        });
        errdefer agent_instance.deinit();

        var instance = AgentSession{
            .allocator = allocator,
            .io = io,
            .cwd = cwd,
            .system_prompt = system_prompt,
            .agent = agent_instance,
            .session_manager = manager,
            .subscriber = .{
                .context = manager,
                .callback = handleSessionManagerEvent,
            },
            .subscribed = false,
            .extension_event_subscriber = .{
                .context = extension_hook_context,
                .callback = handleExtensionLifecycleEvent,
            },
            .extension_event_subscribed = false,
            .compaction_settings = compaction_settings,
            .retry_settings = retry_settings,
            .retry_attempt = 0,
            .retry_lifecycle_callback = null,
            .compaction_lifecycle_callback = null,
            .retry_abort_requested = std.atomic.Value(bool).init(false),
            .retry_delay_active = std.atomic.Value(bool).init(false),
            .overflow_recovery_attempted = false,
            .compaction_active = std.atomic.Value(bool).init(false),
            .extension_hook_context = extension_hook_context,
        };

        try instance.agent.subscribe(instance.subscriber);
        instance.subscribed = true;
        if (extension_hook_context) |context| {
            instance.extension_event_subscriber.context = context;
            try instance.agent.subscribe(instance.extension_event_subscriber);
            instance.extension_event_subscribed = true;
        }
        errdefer instance.deinit();
        try instance.emitSessionStart(lifecycle_reason);
        try instance.emitResourcesDiscover(lifecycle_reason);
        return instance;
    }

    fn reloadFromSession(self: *AgentSession) !void {
        var context = try self.session_manager.buildSessionContext(self.allocator);
        defer context.deinit(self.allocator);

        try self.agent.setMessages(context.messages);
        self.agent.setThinkingLevel(context.thinking_level);

        if (context.model) |restored_model| {
            var current = self.agent.getModel();
            if (restored_model.api) |api_name| current.api = api_name;
            current.provider = restored_model.provider;
            current.id = restored_model.model_id;
            current.name = restored_model.model_id;
            self.agent.setModel(current);
        }
    }

    fn runHookedPrompt(
        self: *AgentSession,
        input: anytype,
        accepted_callback: ?agent.PromptAcceptedCallback,
    ) !bool {
        if (self.extension_hook_context == null) return false;
        const Input = @TypeOf(input);
        if (comptime isStringLike(Input)) {
            const original_text: []const u8 = input;
            const hooked_text = try self.runInputHook(original_text) orelse return true;
            defer self.allocator.free(hooked_text);
            const prompt_text = try self.runBeforeAgentStartHook(hooked_text) orelse return true;
            defer self.allocator.free(prompt_text.text);
            defer if (prompt_text.system_prompt) |system_prompt| self.allocator.free(system_prompt);
            const previous_system_prompt = self.agent.getSystemPrompt();
            if (prompt_text.system_prompt) |system_prompt| self.agent.setSystemPrompt(system_prompt);
            defer self.agent.setSystemPrompt(previous_system_prompt);
            try self.agent.promptWithAcceptedCallback(prompt_text.text, accepted_callback);
            try self.runPostPromptMaintenance();
            try self.flushExtensionHookDiagnostics();
            return true;
        }
        if (comptime isTextWithImagesPrompt(Input)) {
            const original_text: []const u8 = input.text;
            const hooked_text = try self.runInputHook(original_text) orelse return true;
            defer self.allocator.free(hooked_text);
            const prompt_text = try self.runBeforeAgentStartHook(hooked_text) orelse return true;
            defer self.allocator.free(prompt_text.text);
            defer if (prompt_text.system_prompt) |system_prompt| self.allocator.free(system_prompt);
            const previous_system_prompt = self.agent.getSystemPrompt();
            if (prompt_text.system_prompt) |system_prompt| self.agent.setSystemPrompt(system_prompt);
            defer self.agent.setSystemPrompt(previous_system_prompt);
            try self.agent.promptWithAcceptedCallback(.{ .text = prompt_text.text, .images = input.images }, accepted_callback);
            try self.runPostPromptMaintenance();
            try self.flushExtensionHookDiagnostics();
            return true;
        }
        return false;
    }

    const PromptHookText = struct {
        text: []u8,
        system_prompt: ?[]u8 = null,
    };

    fn runInputHook(self: *AgentSession, text: []const u8) !?[]u8 {
        const context = self.extension_hook_context orelse return try self.allocator.dupe(u8, text);
        if (!context.hasHook("input")) return try self.allocator.dupe(u8, text);
        var event = try makeObject(self.allocator);
        defer tools_common.deinitJsonValue(self.allocator, event);
        try putString(self.allocator, &event.object, "type", "input");
        try putString(self.allocator, &event.object, "text", text);
        try putString(self.allocator, &event.object, "source", "agent_session");
        var invocation = (try context.invokeDetailed(self.allocator, "input", event)) orelse return try self.allocator.dupe(u8, text);
        defer invocation.deinit(self.allocator);
        if (hookHandled(invocation.result)) {
            try self.appendHookDiagnostic("input", invocation.extension_id, invocation.result);
            return null;
        }
        return try self.allocator.dupe(u8, stringField(invocation.result, "text") orelse stringField(invocation.result, "input") orelse stringField(invocation.result, "prompt") orelse text);
    }

    fn runBeforeAgentStartHook(self: *AgentSession, text: []const u8) !?PromptHookText {
        const context = self.extension_hook_context orelse return .{ .text = try self.allocator.dupe(u8, text) };
        if (!context.hasHook("before_agent_start")) return .{ .text = try self.allocator.dupe(u8, text) };
        var event = try makeObject(self.allocator);
        defer tools_common.deinitJsonValue(self.allocator, event);
        try putString(self.allocator, &event.object, "type", "before_agent_start");
        try putString(self.allocator, &event.object, "text", text);
        try putString(self.allocator, &event.object, "systemPrompt", self.agent.getSystemPrompt());
        var invocation = (try context.invokeDetailed(self.allocator, "before_agent_start", event)) orelse return .{ .text = try self.allocator.dupe(u8, text) };
        defer invocation.deinit(self.allocator);
        if (hookHandled(invocation.result)) {
            try self.appendHookDiagnostic("before_agent_start", invocation.extension_id, invocation.result);
            return null;
        }
        return .{
            .text = try self.allocator.dupe(u8, stringField(invocation.result, "text") orelse stringField(invocation.result, "input") orelse stringField(invocation.result, "prompt") orelse text),
            .system_prompt = if (stringField(invocation.result, "systemPrompt") orelse stringField(invocation.result, "system_prompt")) |system_prompt| try self.allocator.dupe(u8, system_prompt) else null,
        };
    }

    fn appendHookDiagnostic(self: *AgentSession, hook_name: []const u8, extension_id: []const u8, result: std.json.Value) !void {
        const reason = hookReason(result);
        const diagnostic = try std.fmt.allocPrint(
            self.allocator,
            "Extension hook suppressed turn extensionId={s} hook={s} reason={s}",
            .{ extension_id, hook_name, reason },
        );
        defer self.allocator.free(diagnostic);
        var message = try makeDiagnosticAssistantMessage(self.allocator, self.agent.getModel(), diagnostic);
        defer agent.deinitMessage(self.allocator, &message);
        try self.agent.appendMessage(message);
        _ = try self.session_manager.appendMessage(message);
    }

    fn flushExtensionHookDiagnostics(self: *AgentSession) !void {
        const context = self.extension_hook_context orelse return;
        if (context.diagnostics.items.len == 0) return;
        var diagnostics = context.diagnostics;
        context.diagnostics = .empty;
        defer diagnostics.deinit(self.allocator);
        for (diagnostics.items) |diagnostic| {
            defer self.allocator.free(diagnostic);
            var message = try makeDiagnosticAssistantMessage(self.allocator, self.agent.getModel(), diagnostic);
            defer agent.deinitMessage(self.allocator, &message);
            try self.agent.appendMessage(message);
            _ = try self.session_manager.appendMessage(message);
        }
    }

    fn emitSessionStart(self: *AgentSession, reason: []const u8) !void {
        const context = self.extension_hook_context orelse return;
        if (!context.hasHook("session_start")) return;
        var event = try makeObject(self.allocator);
        defer tools_common.deinitJsonValue(self.allocator, event);
        try putString(self.allocator, &event.object, "type", "session_start");
        try putString(self.allocator, &event.object, "reason", reason);
        try context.invokeObservational(self.allocator, "session_start", event);
    }

    fn emitResourcesDiscover(self: *AgentSession, reason: []const u8) !void {
        const context = self.extension_hook_context orelse return;
        if (!context.hasHook("resources_discover")) return;
        var event = try makeObject(self.allocator);
        defer tools_common.deinitJsonValue(self.allocator, event);
        try putString(self.allocator, &event.object, "type", "resources_discover");
        try putString(self.allocator, &event.object, "cwd", self.cwd);
        try putString(self.allocator, &event.object, "reason", reason);
        try context.invokeObservational(self.allocator, "resources_discover", event);
    }

    fn emitSessionShutdown(self: *AgentSession, reason: []const u8) !void {
        const context = self.extension_hook_context orelse return;
        if (!context.hasHook("session_shutdown")) return;
        var event = try makeObject(self.allocator);
        defer tools_common.deinitJsonValue(self.allocator, event);
        try putString(self.allocator, &event.object, "type", "session_shutdown");
        try putString(self.allocator, &event.object, "reason", reason);
        try context.invokeObservational(self.allocator, "session_shutdown", event);
    }
};

const ExtensionHookContext = struct {
    allocator: std.mem.Allocator,
    hosts: []const extension_runtime.RuntimeAdapter,
    timeout_ms: u64,
    next_turn_index: usize = 0,
    active_turn_index: ?usize = null,
    diagnostics: std.ArrayList([]u8) = .empty,

    fn deinit(self: *ExtensionHookContext, allocator: std.mem.Allocator) void {
        for (self.diagnostics.items) |diagnostic| allocator.free(diagnostic);
        self.diagnostics.deinit(allocator);
        self.* = undefined;
    }

    fn recordDiagnostic(self: *ExtensionHookContext, diagnostic: []const u8) !void {
        try self.diagnostics.append(self.allocator, try self.allocator.dupe(u8, diagnostic));
    }

    fn hasHook(self: *const ExtensionHookContext, event_name: []const u8) bool {
        for (self.hosts) |host| {
            if (host.hasRegisteredHook(event_name)) return true;
        }
        return false;
    }

    fn invoke(self: *const ExtensionHookContext, allocator: std.mem.Allocator, event_name: []const u8, event: std.json.Value) !?std.json.Value {
        if (try self.invokeDetailed(allocator, event_name, event)) |invocation| {
            allocator.free(invocation.extension_id);
            return invocation.result;
        }
        return null;
    }

    const HookInvocation = struct {
        result: std.json.Value,
        extension_id: []u8,

        fn deinit(self: *HookInvocation, allocator: std.mem.Allocator) void {
            tools_common.deinitJsonValue(allocator, self.result);
            allocator.free(self.extension_id);
            self.* = undefined;
        }
    };

    fn invokeDetailed(self: *const ExtensionHookContext, allocator: std.mem.Allocator, event_name: []const u8, event: std.json.Value) !?HookInvocation {
        var last_result: ?std.json.Value = null;
        errdefer if (last_result) |value| tools_common.deinitJsonValue(allocator, value);
        var last_extension_id: ?[]u8 = null;
        errdefer if (last_extension_id) |value| allocator.free(value);
        var dispatch_entries = std.ArrayList(HookDispatchEntry).empty;
        defer dispatch_entries.deinit(allocator);
        for (self.hosts, 0..) |host, host_index| {
            if (!host.hasRegisteredHook(event_name)) continue;
            try dispatch_entries.append(allocator, hookDispatchEntryForHost(host, event_name, host_index));
        }
        std.mem.sort(HookDispatchEntry, dispatch_entries.items, {}, hookDispatchEntryLessThan);

        for (dispatch_entries.items) |entry| {
            const host = entry.host;
            if (try host.invokeExtensionEvent(allocator, event_name, event, self.timeout_ms)) |result| {
                if (last_result) |old| tools_common.deinitJsonValue(allocator, old);
                if (last_extension_id) |old_id| allocator.free(old_id);
                last_result = result;
                last_extension_id = try describeHookSource(allocator, host, event_name);
            }
        }
        const result = last_result orelse return null;
        last_result = null;
        const extension_id = last_extension_id orelse try allocator.dupe(u8, "unknown-extension");
        last_extension_id = null;
        return .{
            .result = result,
            .extension_id = extension_id,
        };
    }

    fn invokeObservational(self: *ExtensionHookContext, allocator: std.mem.Allocator, event_name: []const u8, event: std.json.Value) !void {
        var dispatch_entries = std.ArrayList(HookDispatchEntry).empty;
        defer dispatch_entries.deinit(allocator);
        for (self.hosts, 0..) |host, host_index| {
            if (!host.hasRegisteredHook(event_name)) continue;
            try dispatch_entries.append(allocator, hookDispatchEntryForHost(host, event_name, host_index));
        }
        std.mem.sort(HookDispatchEntry, dispatch_entries.items, {}, hookDispatchEntryLessThan);

        for (dispatch_entries.items) |entry| {
            const result = entry.host.invokeExtensionEvent(allocator, event_name, event, self.timeout_ms) catch |err| {
                try self.recordInvocationDiagnostic(allocator, entry.host, event_name, err);
                continue;
            };
            if (result) |value| tools_common.deinitJsonValue(allocator, value);
        }
    }

    fn recordInvocationDiagnostic(
        self: *ExtensionHookContext,
        allocator: std.mem.Allocator,
        host: extension_runtime.RuntimeAdapter,
        event_name: []const u8,
        err: anyerror,
    ) !void {
        const extension_id = describeHookSource(allocator, host, event_name) catch |source_err| {
            const fallback = try std.fmt.allocPrint(
                allocator,
                "Extension event invocation failed extensionId={s} event={s}: {s}",
                .{ host.kind.jsonName(), event_name, @errorName(source_err) },
            );
            defer allocator.free(fallback);
            try self.recordDiagnostic(fallback);
            return;
        };
        defer allocator.free(extension_id);
        const diagnostic = try std.fmt.allocPrint(
            allocator,
            "Extension event invocation failed extensionId={s} event={s}: {s}",
            .{ extension_id, event_name, @errorName(err) },
        );
        defer allocator.free(diagnostic);
        try self.recordDiagnostic(diagnostic);
    }

    fn invokeLifecycle(self: *ExtensionHookContext, allocator: std.mem.Allocator, event: agent.AgentEvent) !void {
        const event_name = switch (event.event_type) {
            .agent_start => "agent_start",
            .agent_end => "agent_end",
            .turn_start => "turn_start",
            .message_start => "message_start",
            .message_update => "message_update",
            .tool_execution_start => "tool_execution_start",
            .tool_execution_update => "tool_execution_update",
            .tool_execution_end => "tool_execution_end",
            .turn_end => "turn_end",
            else => return,
        };
        if (!self.hasHook(event_name)) return;

        if (event.event_type == .turn_start) {
            self.active_turn_index = self.next_turn_index;
            self.next_turn_index += 1;
        }

        const payload = try makeLifecycleEventObject(allocator, event_name, event, self.active_turn_index orelse 0);
        defer tools_common.deinitJsonValue(allocator, payload);
        try self.invokeObservational(allocator, event_name, payload);
    }
};

const HookDispatchEntry = struct {
    host: extension_runtime.RuntimeAdapter,
    host_index: usize,
    priority: i64 = 0,
    declaration_order: usize = 0,
};

const HookDispatchLookup = struct {
    event_name: []const u8,
    priority: i64 = 0,
    declaration_order: usize = 0,
};

fn hookDispatchEntryForHost(host: extension_runtime.RuntimeAdapter, event_name: []const u8, host_index: usize) HookDispatchEntry {
    var lookup = HookDispatchLookup{
        .event_name = event_name,
        .declaration_order = host_index,
    };
    host.withRegistry(&lookup, captureHookDispatchMetadata) catch {};
    return .{
        .host = host,
        .host_index = host_index,
        .priority = lookup.priority,
        .declaration_order = lookup.declaration_order,
    };
}

fn captureHookDispatchMetadata(context: ?*anyopaque, registry: *const extension_runtime.Registry) !void {
    const lookup: *HookDispatchLookup = @ptrCast(@alignCast(context orelse return));
    for (registry.hooks.items) |hook| {
        if (!std.mem.eql(u8, hook.event_name, lookup.event_name)) continue;
        lookup.priority = hook.priority;
        lookup.declaration_order = hook.declaration_order;
        return;
    }
}

fn hookDispatchEntryLessThan(_: void, lhs: HookDispatchEntry, rhs: HookDispatchEntry) bool {
    if (lhs.priority != rhs.priority) return lhs.priority < rhs.priority;
    if (lhs.declaration_order != rhs.declaration_order) return lhs.declaration_order < rhs.declaration_order;
    return lhs.host_index < rhs.host_index;
}

fn handleExtensionLifecycleEvent(context: ?*anyopaque, event: agent.AgentEvent) !void {
    const hook_context: *ExtensionHookContext = @ptrCast(@alignCast(context orelse return));
    try hook_context.invokeLifecycle(std.heap.page_allocator, event);
}

fn transformContextHook(
    allocator: std.mem.Allocator,
    messages: []const agent.AgentMessage,
    signal: ?*const std.atomic.Value(bool),
    transform_context: ?*anyopaque,
) ![]agent.AgentMessage {
    if (signal) |abort_signal| {
        if (abort_signal.load(.seq_cst)) return @constCast(messages);
    }
    const context: *ExtensionHookContext = @ptrCast(@alignCast(transform_context orelse return @constCast(messages)));
    if (!context.hasHook("context")) return @constCast(messages);
    var event = try makeObject(allocator);
    defer tools_common.deinitJsonValue(allocator, event);
    try putString(allocator, &event.object, "type", "context");
    try putMessagesSummary(allocator, &event.object, messages);
    var invocation = (try context.invokeDetailed(allocator, "context", event)) orelse return @constCast(messages);
    defer invocation.deinit(allocator);
    if (try contextHookContributionDiagnostic(allocator, invocation.extension_id, invocation.result)) |diagnostic| {
        defer allocator.free(diagnostic);
        try context.recordDiagnostic(diagnostic);
        return @constCast(messages);
    }
    const extra = try messagesFromHookResult(allocator, invocation.result);
    if (extra.len == 0) {
        allocator.free(extra);
        return @constCast(messages);
    }
    const output = try allocator.alloc(agent.AgentMessage, messages.len + extra.len);
    @memcpy(output[0..messages.len], messages);
    @memcpy(output[messages.len..], extra);
    allocator.free(extra);
    return output;
}

fn beforeToolCallHook(
    allocator: std.mem.Allocator,
    before_context: agent.types.BeforeToolCallContext,
    signal: ?*const std.atomic.Value(bool),
) !?agent.types.BeforeToolCallResult {
    if (signal) |abort_signal| {
        if (abort_signal.load(.seq_cst)) return null;
    }
    const context: *ExtensionHookContext = @ptrCast(@alignCast(before_context.context.extension_hook_context orelse return null));
    if (!context.hasHook("tool_call")) return null;
    const event = try toolCallEvent(allocator, "tool_call", before_context.tool_call, before_context.args.*);
    defer tools_common.deinitJsonValue(allocator, event);
    const result = try context.invoke(allocator, "tool_call", event) orelse return null;
    defer tools_common.deinitJsonValue(allocator, result);
    if (objectField(result, "input")) |input| {
        tools_common.deinitJsonValue(allocator, before_context.args.*);
        before_context.args.* = try tools_common.cloneJsonValue(allocator, input);
    }
    if (hookHandled(result) or boolField(result, "block") orelse false) {
        return .{
            .block = true,
            .reason = try allocator.dupe(u8, stringField(result, "reason") orelse stringField(result, "message") orelse "blocked by extension hook"),
        };
    }
    return null;
}

fn afterToolCallHook(
    allocator: std.mem.Allocator,
    after_context: agent.types.AfterToolCallContext,
    signal: ?*const std.atomic.Value(bool),
) !?agent.types.AfterToolCallResult {
    if (signal) |abort_signal| {
        if (abort_signal.load(.seq_cst)) return null;
    }
    const context: *ExtensionHookContext = @ptrCast(@alignCast(after_context.context.extension_hook_context orelse return null));
    if (!context.hasHook("tool_result")) return null;
    var event = try toolCallEvent(allocator, "tool_result", after_context.tool_call, after_context.args);
    defer tools_common.deinitJsonValue(allocator, event);
    try putString(allocator, &event.object, "toolCallId", after_context.tool_call.id);
    try putBool(allocator, &event.object, "isError", after_context.is_error);
    try putToolResultSummary(allocator, &event.object, after_context.result);
    const result = try context.invoke(allocator, "tool_result", event) orelse return null;
    defer tools_common.deinitJsonValue(allocator, result);
    var patch = agent.types.AfterToolCallResult{};
    if (stringField(result, "content")) |content| {
        patch.content = try tools_common.makeTextContent(allocator, content);
    }
    if (objectField(result, "details")) |details| {
        patch.details = try tools_common.cloneJsonValue(allocator, details);
    }
    if (boolField(result, "isError") orelse boolField(result, "is_error")) |is_error| {
        patch.is_error = is_error;
    }
    if (patch.content == null and patch.details == null and patch.is_error == null) return null;
    return patch;
}

fn messageEndHook(
    allocator: std.mem.Allocator,
    message: agent.AgentMessage,
    transform_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
) !?agent.AgentMessage {
    _ = signal;
    const context: *ExtensionHookContext = @ptrCast(@alignCast(transform_context orelse return null));
    if (!context.hasHook("message_end")) return null;
    const event = try json_event_wire.agentEventToJsonValue(allocator, .{
        .event_type = .message_end,
        .message = message,
    });
    defer tools_common.deinitJsonValue(allocator, event);
    var invocation = (try context.invokeDetailed(allocator, "message_end", event)) orelse return null;
    defer invocation.deinit(allocator);
    return try messageEndReplacementFromResult(allocator, context, invocation.extension_id, message, invocation.result);
}

fn messageEndReplacementFromResult(
    allocator: std.mem.Allocator,
    context: *ExtensionHookContext,
    extension_id: []const u8,
    message: agent.AgentMessage,
    result: std.json.Value,
) !?agent.AgentMessage {
    const current_role = messageRole(message);
    var replacement_role = stringField(result, "role");
    var replacement_text = stringField(result, "message") orelse stringField(result, "content");

    if (objectField(result, "message")) |message_value| {
        switch (message_value) {
            .string => |text| replacement_text = text,
            .object => {
                if (replacement_role == null) replacement_role = stringField(message_value, "role");
                if (replacement_text == null) replacement_text = stringField(message_value, "content") orelse firstTextFromJsonContent(message_value);
            },
            else => {},
        }
    }

    if (replacement_role) |role| {
        if (!std.mem.eql(u8, role, current_role)) {
            const diagnostic = try std.fmt.allocPrint(
                allocator,
                "Extension message_end hook ignored incompatible replacement extensionId={s}: message_end handlers must return a message with the same role",
                .{extension_id},
            );
            defer allocator.free(diagnostic);
            try context.recordDiagnostic(diagnostic);
            return null;
        }
    }
    const text = replacement_text orelse return null;
    var replacement = try agent.cloneMessage(allocator, message);
    errdefer agent.deinitMessage(allocator, &replacement);
    try replaceMessageText(allocator, &replacement, text);
    return replacement;
}

fn firstTextFromJsonContent(message_value: std.json.Value) ?[]const u8 {
    const content = objectField(message_value, "content") orelse return null;
    switch (content) {
        .string => |text| return text,
        .array => |array| {
            for (array.items) |item| {
                if (item != .object) continue;
                const item_type = stringField(item, "type") orelse continue;
                if (!std.mem.eql(u8, item_type, "text")) continue;
                if (stringField(item, "text")) |text| return text;
            }
        },
        else => {},
    }
    return null;
}

fn messageRole(message: agent.AgentMessage) []const u8 {
    return switch (message) {
        .user => "user",
        .assistant => "assistant",
        .tool_result => "toolResult",
    };
}

fn replaceMessageText(allocator: std.mem.Allocator, message: *agent.AgentMessage, text: []const u8) !void {
    const content = try tools_common.makeTextContent(allocator, text);
    switch (message.*) {
        .user => |*user| {
            tools_common.deinitContentBlocks(allocator, user.content);
            user.content = content;
        },
        .assistant => |*assistant| {
            tools_common.deinitContentBlocks(allocator, assistant.content);
            assistant.content = content;
        },
        .tool_result => |*tool_result| {
            tools_common.deinitContentBlocks(allocator, tool_result.content);
            tool_result.content = content;
        },
    }
}

fn makeObject(allocator: std.mem.Allocator) !std.json.Value {
    return .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
}

fn putString(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .string = try allocator.dupe(u8, value) });
}

fn putBool(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: bool) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .bool = value });
}

fn putInt(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: i64) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .integer = value });
}

fn putValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    try object.put(allocator, try allocator.dupe(u8, key), value);
}

fn jsonObjectWithString(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !std.json.Value {
    var object = try makeObject(allocator);
    errdefer tools_common.deinitJsonValue(allocator, object);
    try putString(allocator, &object.object, key, value);
    return object;
}

fn jsonObjectWithTruncateInput(
    allocator: std.mem.Allocator,
    content: []const u8,
    max_lines: i64,
    max_bytes: i64,
) !std.json.Value {
    var object = try makeObject(allocator);
    errdefer tools_common.deinitJsonValue(allocator, object);
    try putString(allocator, &object.object, "content", content);
    try putInt(allocator, &object.object, "maxLines", max_lines);
    try putInt(allocator, &object.object, "maxBytes", max_bytes);
    return object;
}

fn absoluteSessionTmpPath(allocator: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", sub_path, name });
}

fn expectToolResultContains(messages: []const agent.AgentMessage, tool_name: []const u8, expected: []const u8) !void {
    for (messages) |message| {
        if (message != .tool_result) continue;
        if (!std.mem.eql(u8, message.tool_result.tool_name, tool_name)) continue;
        for (message.tool_result.content) |block| {
            if (block != .text) continue;
            if (std.mem.indexOf(u8, block.text.text, expected) != null) return;
        }
    }
    return error.ExpectedToolResultNotFound;
}

fn crossNativeEchoExecute(ctx: *sdk.ToolContext) !agent.AgentToolResult {
    const allocator = ctx.allocator;
    const params = ctx.params;
    if (params != .object) return crossNativeInvalidInput(allocator);
    const value = params.object.get("value") orelse return crossNativeInvalidInput(allocator);
    if (value != .string) return crossNativeInvalidInput(allocator);
    const text = try std.fmt.allocPrint(allocator, "{{\"runtime\":\"native\",\"echo\":\"{s}\"}}", .{value.string});
    defer allocator.free(text);
    return .{ .content = try tools_common.makeTextContent(allocator, text) };
}

fn crossNativeInvalidInput(allocator: std.mem.Allocator) !agent.AgentToolResult {
    return .{
        .content = try tools_common.makeTextContent(allocator, "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"expected object with string value\"}}"),
        .is_error = true,
    };
}

const cross_native_tool: extension_runtime.NativeToolDefinition = .{
    .name = "native.cross.echo",
    .label = "Native Cross Echo",
    .description = "Echoes a string through the cross-runtime native fixture.",
    .input_schema_json = "{\"type\":\"object\",\"required\":[\"value\"],\"properties\":{\"value\":{\"type\":\"string\"}},\"additionalProperties\":false}",
    .output_schema_json = "{\"type\":\"object\"}",
    .extension_path = "native://cross/echo",
    .execute = crossNativeEchoExecute,
};

const cross_native_descriptor: extension_runtime.NativeDescriptor = .{
    .id = "com.pi.native-cross-runtime",
    .name = "Native Cross Runtime",
    .version = "0.1.0",
    .description = "Native fixture used by the cross-runtime workflow lifecycle contract.",
    .tools = &.{cross_native_tool},
};

fn putMessageSummary(allocator: std.mem.Allocator, object: *std.json.ObjectMap, message: agent.AgentMessage) !void {
    var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer tools_common.deinitJsonValue(allocator, .{ .object = entry });
    switch (message) {
        .user => |user| {
            try putString(allocator, &entry, "role", "user");
            try putString(allocator, &entry, "content", firstText(user.content) orelse "");
        },
        .assistant => |assistant| {
            try putString(allocator, &entry, "role", "assistant");
            try putString(allocator, &entry, "content", firstText(assistant.content) orelse "");
        },
        .tool_result => |tool| {
            try putString(allocator, &entry, "role", "tool");
            try putString(allocator, &entry, "content", firstText(tool.content) orelse "");
        },
    }
    try putValue(allocator, object, "message", .{ .object = entry });
}

fn putMessagesSummary(allocator: std.mem.Allocator, object: *std.json.ObjectMap, messages: []const agent.AgentMessage) !void {
    var array = std.json.Array.init(allocator);
    for (messages) |message| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        switch (message) {
            .user => |user| {
                try putString(allocator, &entry, "role", "user");
                try putString(allocator, &entry, "content", firstText(user.content) orelse "");
            },
            .assistant => |assistant| {
                try putString(allocator, &entry, "role", "assistant");
                try putString(allocator, &entry, "content", firstText(assistant.content) orelse "");
            },
            .tool_result => |tool| {
                try putString(allocator, &entry, "role", "tool");
                try putString(allocator, &entry, "content", firstText(tool.content) orelse "");
            },
        }
        try array.append(.{ .object = entry });
    }
    try putValue(allocator, object, "messages", .{ .array = array });
}

fn makeLifecycleEventObject(
    allocator: std.mem.Allocator,
    event_name: []const u8,
    event: agent.AgentEvent,
    turn_index: usize,
) !std.json.Value {
    var payload = try json_event_wire.agentEventToJsonValue(allocator, event);
    errdefer tools_common.deinitJsonValue(allocator, payload);
    _ = event_name;
    try putInt(allocator, &payload.object, "turnIndex", @intCast(turn_index));
    return payload;
}

fn toolCallEvent(allocator: std.mem.Allocator, event_name: []const u8, tool_call: ai.ToolCall, args: std.json.Value) !std.json.Value {
    var event = try makeObject(allocator);
    errdefer tools_common.deinitJsonValue(allocator, event);
    try putString(allocator, &event.object, "type", event_name);
    try putString(allocator, &event.object, "name", tool_call.name);
    try putString(allocator, &event.object, "id", tool_call.id);
    try putValue(allocator, &event.object, "input", try tools_common.cloneJsonValue(allocator, args));
    return event;
}

fn putToolResultSummary(allocator: std.mem.Allocator, object: *std.json.ObjectMap, result: agent.types.AgentToolResult) !void {
    try putString(allocator, object, "content", firstText(result.content) orelse "");
    if (result.details) |details| try putValue(allocator, object, "details", try tools_common.cloneJsonValue(allocator, details));
}

fn firstText(content: []const ai.ContentBlock) ?[]const u8 {
    for (content) |block| switch (block) {
        .text => |text| return text.text,
        else => {},
    };
    return null;
}

fn objectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = objectField(value, key) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

fn boolField(value: std.json.Value, key: []const u8) ?bool {
    const field = objectField(value, key) orelse return null;
    return switch (field) {
        .bool => |flag| flag,
        else => null,
    };
}

fn hookHandled(value: std.json.Value) bool {
    if (boolField(value, "handled") orelse false) return true;
    if (boolField(value, "block") orelse false) return true;
    if (stringField(value, "action")) |action| {
        return std.mem.eql(u8, action, "handled") or std.mem.eql(u8, action, "block") or std.mem.eql(u8, action, "deny");
    }
    return false;
}

fn hookReason(value: std.json.Value) []const u8 {
    return stringField(value, "reason") orelse
        stringField(value, "message") orelse
        stringField(value, "error") orelse
        stringField(value, "action") orelse
        if (boolField(value, "handled") orelse false) "handled" else "blocked";
}

const HookSourceLookup = struct {
    allocator: std.mem.Allocator,
    event_name: []const u8,
    extension_id: ?[]u8 = null,
};

fn describeHookSource(allocator: std.mem.Allocator, host: extension_runtime.RuntimeAdapter, event_name: []const u8) ![]u8 {
    var lookup = HookSourceLookup{
        .allocator = allocator,
        .event_name = event_name,
    };
    host.withRegistry(&lookup, captureHookSource) catch {};
    if (lookup.extension_id) |extension_id| return extension_id;
    return try allocator.dupe(u8, host.kind.jsonName());
}

fn captureHookSource(context: ?*anyopaque, registry: *const extension_runtime.Registry) !void {
    const lookup: *HookSourceLookup = @ptrCast(@alignCast(context orelse return));
    for (registry.hooks.items) |hook| {
        if (!std.mem.eql(u8, hook.event_name, lookup.event_name)) continue;
        lookup.extension_id = try lookup.allocator.dupe(u8, hook.extension_path);
        return;
    }
}

fn makeDiagnosticAssistantMessage(allocator: std.mem.Allocator, model: ai.Model, diagnostic: []const u8) !agent.AgentMessage {
    const content = try tools_common.makeTextContent(allocator, diagnostic);
    errdefer {
        allocator.free(content[0].text.text);
        allocator.free(content);
    }
    return .{ .assistant = .{
        .role = try allocator.dupe(u8, "assistant"),
        .content = content,
        .tool_calls = null,
        .api = try allocator.dupe(u8, model.api),
        .provider = try allocator.dupe(u8, model.provider),
        .model = try allocator.dupe(u8, model.id),
        .usage = ai.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = try allocator.dupe(u8, diagnostic),
        .timestamp = agent.types.nowMilliseconds(),
    } };
}

fn contextHookContributionDiagnostic(allocator: std.mem.Allocator, extension_id: []const u8, result: std.json.Value) !?[]u8 {
    if (result != .object) {
        return try formatContextHookContributionDiagnostic(allocator, extension_id, "$", "expected object result");
    }
    const messages = result.object.get("messages") orelse return null;
    if (messages != .array) {
        return try formatContextHookContributionDiagnostic(allocator, extension_id, "$.messages", "expected array");
    }
    for (messages.array.items, 0..) |message, index| {
        switch (message) {
            .string => {},
            .object => {
                if (stringField(message, "content") != null or stringField(message, "text") != null) continue;
                if (objectField(message, "content") != null) {
                    const path = try std.fmt.allocPrint(allocator, "$.messages[{d}].content", .{index});
                    defer allocator.free(path);
                    return try formatContextHookContributionDiagnostic(allocator, extension_id, path, "expected string");
                }
                if (objectField(message, "text") != null) {
                    const path = try std.fmt.allocPrint(allocator, "$.messages[{d}].text", .{index});
                    defer allocator.free(path);
                    return try formatContextHookContributionDiagnostic(allocator, extension_id, path, "expected string");
                }
                const path = try std.fmt.allocPrint(allocator, "$.messages[{d}]", .{index});
                defer allocator.free(path);
                return try formatContextHookContributionDiagnostic(allocator, extension_id, path, "missing string content or text field");
            },
            else => {
                const path = try std.fmt.allocPrint(allocator, "$.messages[{d}]", .{index});
                defer allocator.free(path);
                return try formatContextHookContributionDiagnostic(allocator, extension_id, path, "expected string or object");
            },
        }
    }
    return null;
}

fn formatContextHookContributionDiagnostic(
    allocator: std.mem.Allocator,
    extension_id: []const u8,
    path: []const u8,
    message: []const u8,
) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "Invalid extension context hook contribution extensionId={s} hook=context path={s}: {s}",
        .{ extension_id, path, message },
    );
}

fn messagesFromHookResult(allocator: std.mem.Allocator, result: std.json.Value) ![]agent.AgentMessage {
    const messages_value = objectField(result, "messages") orelse return allocator.alloc(agent.AgentMessage, 0);
    if (messages_value != .array) return allocator.alloc(agent.AgentMessage, 0);
    var output = std.ArrayList(agent.AgentMessage).empty;
    errdefer {
        agent.deinitMessageSlice(allocator, output.items);
        output.deinit(allocator);
    }
    for (messages_value.array.items) |message_value| {
        if (message_value == .string) {
            try output.append(allocator, try hookUserMessage(allocator, message_value.string));
        } else if (message_value == .object) {
            const content = stringField(message_value, "content") orelse stringField(message_value, "text") orelse continue;
            try output.append(allocator, try hookUserMessage(allocator, content));
        }
    }
    return try output.toOwnedSlice(allocator);
}

fn hookUserMessage(allocator: std.mem.Allocator, text: []const u8) !agent.AgentMessage {
    const content = try tools_common.makeTextContent(allocator, text);
    return .{ .user = .{
        .content = content,
        .timestamp = agent.types.nowMilliseconds(),
    } };
}

fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == u8,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == u8,
                else => false,
            },
            else => false,
        },
        .array => |array| array.child == u8,
        else => false,
    };
}

fn isTextWithImagesPrompt(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasField(T, "text") and @hasField(T, "images"),
        else => false,
    };
}

fn queuedUserMessage(
    allocator: std.mem.Allocator,
    text: []const u8,
    images: []const ai.ImageContent,
) !agent.AgentMessage {
    const content = try allocator.alloc(ai.ContentBlock, 1 + images.len);
    content[0] = .{ .text = .{ .text = text } };
    for (images, 0..) |image, index| {
        content[index + 1] = .{ .image = image };
    }
    return .{ .user = .{
        .content = content,
        .timestamp = 0,
    } };
}

fn deinitQueuedUserMessage(allocator: std.mem.Allocator, message: *agent.AgentMessage) void {
    switch (message.*) {
        .user => |user_message| allocator.free(user_message.content),
        else => {},
    }
}

fn queuedInputsFromMessages(
    allocator: std.mem.Allocator,
    messages: []const agent.AgentMessage,
) ![]QueuedInput {
    if (messages.len == 0) return try allocator.alloc(QueuedInput, 0);

    const queued = try allocator.alloc(QueuedInput, messages.len);
    var initialized: usize = 0;
    errdefer {
        for (queued[0..initialized]) |*item| item.deinit(allocator);
        allocator.free(queued);
    }

    for (messages, 0..) |message, index| {
        queued[index] = try queuedInputFromMessage(allocator, message);
        initialized += 1;
    }

    return queued;
}

fn queuedInputFromMessage(allocator: std.mem.Allocator, message: agent.AgentMessage) !QueuedInput {
    const user_message = switch (message) {
        .user => |user| user,
        else => return error.InvalidQueuedMessage,
    };

    var text_block: []const u8 = "";
    var image_count: usize = 0;
    for (user_message.content) |block| {
        switch (block) {
            .text => |text| {
                if (text_block.len == 0) text_block = text.text;
            },
            .image => image_count += 1,
            else => {},
        }
    }

    const images = try allocator.alloc(ai.ImageContent, image_count);
    var image_index: usize = 0;
    errdefer {
        for (images[0..image_index]) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        allocator.free(images);
    }

    for (user_message.content) |block| {
        switch (block) {
            .image => |image| {
                images[image_index] = .{
                    .data = try allocator.dupe(u8, image.data),
                    .mime_type = try allocator.dupe(u8, image.mime_type),
                };
                image_index += 1;
            },
            else => {},
        }
    }

    return .{
        .text = try allocator.dupe(u8, text_block),
        .images = images,
    };
}

fn resolveModel(explicit_model: ?ai.Model, restored: ?session_manager.SessionModelRef) ai.Model {
    if (explicit_model) |model| return model;
    if (restored) |restored_model| {
        var model = agent.DEFAULT_MODEL;
        if (restored_model.api) |api_name| model.api = api_name;
        model.provider = restored_model.provider;
        model.id = restored_model.model_id;
        model.name = restored_model.model_id;
        return model;
    }
    return agent.DEFAULT_MODEL;
}

fn treeNavigationLeaf(entry: *const session_manager.SessionEntry) ?[]const u8 {
    return switch (entry.*) {
        .message => |message_entry| switch (message_entry.message) {
            .user => message_entry.parent_id,
            else => entry.id(),
        },
        .custom_message => |custom_message_entry| custom_message_entry.parent_id,
        else => entry.id(),
    };
}

fn treeNavigationEditorText(allocator: std.mem.Allocator, entry: *const session_manager.SessionEntry) !?[]u8 {
    return switch (entry.*) {
        .message => |message_entry| switch (message_entry.message) {
            .user => |user_message| try contentBlocksTextAlloc(allocator, user_message.content),
            else => null,
        },
        .custom_message => |custom_message_entry| switch (custom_message_entry.content) {
            .text => |text| try allocator.dupe(u8, text),
            .blocks => |blocks| try contentBlocksTextAlloc(allocator, blocks),
        },
        else => null,
    };
}

fn contentBlocksTextAlloc(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    for (blocks) |block| {
        if (block == .text) try writer.writer.writeAll(block.text.text);
    }
    return try allocator.dupe(u8, writer.written());
}

fn handleSessionManagerEvent(context: ?*anyopaque, event: agent.AgentEvent) !void {
    const manager: *session_manager.SessionManager = @ptrCast(@alignCast(context.?));
    if (event.event_type != .message_end) return;
    if (event.message) |message| {
        _ = try manager.appendMessage(message);
    }
}

const CompactionPreparation = struct {
    summary_start_index: usize,
    first_kept_entry_index: usize,
    tokens_before: u32,
};

fn findLastAssistantMessage(messages: []const agent.AgentMessage) ?ai.AssistantMessage {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        switch (messages[index]) {
            .assistant => |assistant_message| return assistant_message,
            else => {},
        }
    }
    return null;
}

fn removeLastAssistantError(self: *AgentSession) bool {
    const messages = self.agent.getMessages();
    if (messages.len == 0) return false;
    switch (messages[messages.len - 1]) {
        .assistant => |assistant_message| {
            if (assistant_message.stop_reason != .error_reason) return false;
            _ = self.agent.removeLastMessage();
            return true;
        },
        else => return false,
    }
}

fn isContextOverflow(message: ai.AssistantMessage, context_window: u32) bool {
    _ = context_window;
    if (message.stop_reason != .error_reason) return false;
    const error_message = message.error_message orelse return false;
    return std.ascii.indexOfIgnoreCase(error_message, "overflow") != null or
        std.ascii.indexOfIgnoreCase(error_message, "context length") != null or
        std.ascii.indexOfIgnoreCase(error_message, "context window") != null or
        std.ascii.indexOfIgnoreCase(error_message, "too long") != null;
}

fn isRetryableError(message: ai.AssistantMessage, context_window: u32) bool {
    if (message.stop_reason != .error_reason) return false;
    const error_message = message.error_message orelse return false;
    if (isContextOverflow(message, context_window)) return false;

    return string_utils.containsIgnoreCase(error_message, "overloaded") or
        string_utils.containsIgnoreCase(error_message, "rate limit") or
        string_utils.containsIgnoreCase(error_message, "too many requests") or
        string_utils.containsIgnoreCase(error_message, "service unavailable") or
        string_utils.containsIgnoreCase(error_message, "server error") or
        string_utils.containsIgnoreCase(error_message, "internal error") or
        string_utils.containsIgnoreCase(error_message, "network error") or
        string_utils.containsIgnoreCase(error_message, "connection error") or
        string_utils.containsIgnoreCase(error_message, "connection refused") or
        string_utils.containsIgnoreCase(error_message, "connection lost") or
        string_utils.containsIgnoreCase(error_message, "socket hang up") or
        string_utils.containsIgnoreCase(error_message, "fetch failed") or
        string_utils.containsIgnoreCase(error_message, "timeout") or
        string_utils.containsIgnoreCase(error_message, "timed out") or
        string_utils.containsIgnoreCase(error_message, "429") or
        string_utils.containsIgnoreCase(error_message, "500") or
        string_utils.containsIgnoreCase(error_message, "502") or
        string_utils.containsIgnoreCase(error_message, "503") or
        string_utils.containsIgnoreCase(error_message, "504");
}

fn shouldAutoCompact(context_tokens: u32, context_window: u32, settings: CompactionSettings) bool {
    if (!settings.enabled or context_window == 0) return false;
    const threshold = if (context_window > settings.reserve_tokens) context_window - settings.reserve_tokens else 0;
    return context_tokens > threshold;
}

fn estimateContextTokens(messages: []const agent.AgentMessage) u32 {
    var total: u32 = 0;
    for (messages) |message| {
        total += estimateMessageTokens(message);
    }
    return total;
}

fn estimateMessageTokens(message: agent.AgentMessage) u32 {
    var chars: usize = 0;
    switch (message) {
        .user => |user_message| {
            for (user_message.content) |block| {
                switch (block) {
                    .text => |text| chars += text.text.len,
                    .image => chars += 4800,
                    .thinking => |thinking| chars += thinking.thinking.len,
                    .tool_call => |tool_call| {
                        chars += tool_call.name.len;
                        chars += jsonValueCharCount(tool_call.arguments);
                    },
                }
            }
        },
        .assistant => |assistant_message| {
            if (assistant_message.stop_reason == .error_reason) return 0;
            for (assistant_message.content) |block| {
                switch (block) {
                    .text => |text| chars += text.text.len,
                    .image => chars += 4800,
                    .thinking => |thinking| chars += thinking.thinking.len,
                    .tool_call => |tool_call| {
                        chars += tool_call.name.len;
                        chars += jsonValueCharCount(tool_call.arguments);
                    },
                }
            }
            if (!ai.hasInlineToolCalls(assistant_message)) {
                if (assistant_message.tool_calls) |tool_calls| {
                    for (tool_calls) |tool_call| {
                        chars += tool_call.name.len;
                        chars += jsonValueCharCount(tool_call.arguments);
                    }
                }
            }
        },
        .tool_result => |tool_result| {
            for (tool_result.content) |block| {
                switch (block) {
                    .text => |text| chars += text.text.len,
                    .image => chars += 4800,
                    .thinking => |thinking| chars += thinking.thinking.len,
                    .tool_call => |tool_call| {
                        chars += tool_call.name.len;
                        chars += jsonValueCharCount(tool_call.arguments);
                    },
                }
            }
        },
    }
    return @intCast((chars + 3) / 4);
}

fn jsonValueCharCount(value: std.json.Value) usize {
    return switch (value) {
        .null => 4,
        .bool => |bool_value| if (bool_value) 4 else 5,
        .integer => |integer| std.fmt.count("{}", .{integer}),
        .float => |float_value| std.fmt.count("{d}", .{float_value}),
        .number_string => |number_string| number_string.len,
        .string => |string| string.len,
        .array => |array| blk: {
            var total: usize = 2;
            for (array.items, 0..) |item, index| {
                if (index > 0) total += 1;
                total += jsonValueCharCount(item);
            }
            break :blk total;
        },
        .object => |object| blk: {
            var total: usize = 2;
            var iterator = object.iterator();
            var first = true;
            while (iterator.next()) |entry| {
                if (!first) total += 1;
                first = false;
                total += entry.key_ptr.*.len + jsonValueCharCount(entry.value_ptr.*) + 1;
            }
            break :blk total;
        },
    };
}

fn prepareCompaction(
    branch_entries: []const *const session_manager.SessionEntry,
    keep_recent_tokens: u32,
) ?CompactionPreparation {
    if (branch_entries.len == 0) return null;

    var latest_compaction_index: ?usize = null;
    for (branch_entries, 0..) |entry, index| {
        if (entry.* == .compaction) latest_compaction_index = index;
    }

    const summary_start_index = if (latest_compaction_index) |index| index + 1 else 0;
    if (summary_start_index >= branch_entries.len) return null;

    var tokens_before: u32 = 0;
    var first_visible_index: ?usize = null;
    for (branch_entries[summary_start_index..], summary_start_index..) |entry, index| {
        const entry_tokens = visibleEntryTokens(entry.*);
        if (entry_tokens == 0) continue;
        if (first_visible_index == null) first_visible_index = index;
        tokens_before += entry_tokens;
    }

    const first_visible = first_visible_index orelse return null;
    if (tokens_before <= keep_recent_tokens) return null;

    var kept_tokens: u32 = 0;
    var first_kept_entry_index = first_visible;
    var index = branch_entries.len;
    while (index > summary_start_index) {
        index -= 1;
        const entry_tokens = visibleEntryTokens(branch_entries[index].*);
        if (entry_tokens == 0) continue;
        kept_tokens += entry_tokens;
        first_kept_entry_index = index;
        if (kept_tokens >= keep_recent_tokens) break;
    }

    if (first_kept_entry_index <= first_visible) return null;

    return .{
        .summary_start_index = summary_start_index,
        .first_kept_entry_index = first_kept_entry_index,
        .tokens_before = tokens_before,
    };
}

fn prepareManualCompaction(branch_entries: []const *const session_manager.SessionEntry) ?CompactionPreparation {
    if (branch_entries.len == 0) return null;

    var latest_compaction_index: ?usize = null;
    for (branch_entries, 0..) |entry, index| {
        if (entry.* == .compaction) latest_compaction_index = index;
    }

    const summary_start_index = if (latest_compaction_index) |index| index + 1 else 0;
    if (summary_start_index >= branch_entries.len) return null;

    var visible_count: usize = 0;
    var last_visible_index: ?usize = null;
    var tokens_before: u32 = 0;
    for (branch_entries[summary_start_index..], summary_start_index..) |entry, index| {
        const entry_tokens = visibleEntryTokens(entry.*);
        if (entry_tokens == 0) continue;
        visible_count += 1;
        last_visible_index = index;
        tokens_before += entry_tokens;
    }

    if (visible_count < 2 or last_visible_index == null) return null;

    return .{
        .summary_start_index = summary_start_index,
        .first_kept_entry_index = last_visible_index.?,
        .tokens_before = tokens_before,
    };
}

fn visibleEntryTokens(entry: session_manager.SessionEntry) u32 {
    return switch (entry) {
        .message => |message_entry| estimateMessageTokens(message_entry.message),
        else => 0,
    };
}

fn buildCompactionSummary(
    allocator: std.mem.Allocator,
    branch_entries: []const *const session_manager.SessionEntry,
    start_index: usize,
    end_index: usize,
    custom_instructions: ?[]const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try writer.writer.writeAll("Earlier conversation summary:");
    if (custom_instructions) |instructions| {
        try writer.writer.print("\nFocus: {s}", .{instructions});
    }

    var wrote_line = false;
    for (branch_entries[start_index..end_index]) |entry| {
        if (entry.* != .message) continue;
        switch (entry.message.message) {
            .user => |user_message| {
                const text = summarizeBlocks(user_message.content);
                if (text.len == 0) continue;
                try writer.writer.print("\n- user: {s}", .{text});
                wrote_line = true;
            },
            .assistant => |assistant_message| {
                if (assistant_message.stop_reason == .error_reason or assistant_message.stop_reason == .aborted) continue;
                const text = summarizeAssistant(assistant_message);
                if (text.len == 0) continue;
                try writer.writer.print("\n- assistant: {s}", .{text});
                wrote_line = true;
            },
            .tool_result => |tool_result| {
                const text = summarizeBlocks(tool_result.content);
                if (text.len == 0) continue;
                try writer.writer.print("\n- tool {s}: {s}", .{ tool_result.tool_name, text });
                wrote_line = true;
            },
        }
    }

    if (!wrote_line) {
        try writer.writer.writeAll("\n- Session history was compacted to keep recent context available.");
    }

    return try allocator.dupe(u8, writer.written());
}

fn summarizeAssistant(message: ai.AssistantMessage) []const u8 {
    const text = summarizeBlocks(message.content);
    if (text.len > 0) return text;
    if (message.tool_calls) |tool_calls| {
        if (tool_calls.len > 0) return tool_calls[0].name;
    }
    return "";
}

fn summarizeBlocks(blocks: []const ai.ContentBlock) []const u8 {
    for (blocks) |block| {
        switch (block) {
            .text => |text| if (text.text.len > 0) return trimSummary(text.text),
            .thinking => |thinking| if (thinking.thinking.len > 0) return trimSummary(thinking.thinking),
            else => {},
        }
    }
    return "";
}

fn trimSummary(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \n\r\t");
    return if (trimmed.len > 120) trimmed[0..120] else trimmed;
}

fn exponentialBackoffMs(base_delay_ms: u64, attempt: u32) u64 {
    const exponent = if (attempt == 0) 0 else attempt - 1;
    if (exponent >= 63) return std.math.maxInt(u64);
    const multiplier = @as(u64, 1) << @intCast(exponent);
    const product, const overflowed = @mulWithOverflow(base_delay_ms, multiplier);
    return if (overflowed != 0) std.math.maxInt(u64) else product;
}

fn sleepMilliseconds(io: std.Io, delay_ms: u64) !void {
    const clamped = @min(delay_ms, @as(u64, std.math.maxInt(i64)));
    try std.Io.sleep(io, .fromMilliseconds(@intCast(clamped)), .awake);
}

test "agent session creation keeps model system prompt and working directory" {
    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/session-project",
        .system_prompt = "system prompt",
        .model = model,
    });
    defer session.deinit();

    try std.testing.expectEqualStrings("/tmp/session-project", session.cwd);
    try std.testing.expectEqualStrings("system prompt", session.system_prompt);
    try std.testing.expectEqualStrings("faux-session", session.agent.getModel().id);
    try std.testing.expectEqualStrings("system prompt", session.agent.getSystemPrompt());
    try std.testing.expectEqualStrings("/tmp/session-project", session.session_manager.getCwd());
}

test "agent session persists message_end events to jsonl and resumes transcript" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    const blocks = [_]faux.FauxContentBlock{faux.fauxText("hello back")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks[0..], .{}) },
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const absolute_dir = try std.fs.path.resolve(std.testing.allocator, &[_][]const u8{ cwd, relative_dir });
    defer std.testing.allocator.free(absolute_dir);

    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/session-project",
        .system_prompt = "system prompt",
        .model = registration.getModel(),
        .session_dir = absolute_dir,
    });
    defer session.deinit();

    try session.prompt("hello");

    const session_file = try std.testing.allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer std.testing.allocator.free(session_file);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"role\":\"user\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"role\":\"assistant\""));

    var resumed = try AgentSession.open(std.testing.allocator, std.testing.io, .{
        .session_file = session_file,
        .system_prompt = "system prompt",
    });
    defer resumed.deinit();

    const messages = resumed.agent.getMessages();
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("hello", messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("hello back", messages[1].assistant.content[0].text.text);
}

test "agent session navigation switches visible branch transcript" {
    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    const manager = try std.testing.allocator.create(session_manager.SessionManager);
    var manager_transferred = false;
    errdefer if (!manager_transferred) std.testing.allocator.destroy(manager);
    manager.* = try session_manager.SessionManager.inMemory(std.testing.allocator, std.testing.io, "/tmp/project");
    errdefer if (!manager_transferred) manager.deinit();

    var first = try makeUserMessage("root", 1);
    defer session_manager.deinitMessage(std.testing.allocator, &first);
    const root_id = try manager.appendMessage(first);

    var second = try makeAssistantMessage("main", model, 2);
    defer session_manager.deinitMessage(std.testing.allocator, &second);
    const main_id = try manager.appendMessage(second);

    try manager.branch(root_id);

    var alternate = try makeAssistantMessage("branch", model, 3);
    defer session_manager.deinitMessage(std.testing.allocator, &alternate);
    const branch_id = try manager.appendMessage(alternate);

    var session = try AgentSession.initWithManager(
        std.testing.allocator,
        std.testing.io,
        "/tmp/project",
        "system prompt",
        model,
        null,
        .off,
        &.{},
        .{},
        .{},
        &.{},
        1000,
        manager,
        "startup",
    );
    manager_transferred = true;
    defer session.deinit();

    try session.navigateTo(main_id);
    try std.testing.expectEqual(@as(usize, 2), session.agent.getMessages().len);
    try std.testing.expectEqualStrings("main", session.agent.getMessages()[1].assistant.content[0].text.text);

    try session.navigateTo(branch_id);
    try std.testing.expectEqual(@as(usize, 2), session.agent.getMessages().len);
    try std.testing.expectEqualStrings("branch", session.agent.getMessages()[1].assistant.content[0].text.text);
}

test "agent session tree navigation matches user parentage and summary attachment" {
    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    const manager = try std.testing.allocator.create(session_manager.SessionManager);
    var manager_transferred = false;
    errdefer if (!manager_transferred) std.testing.allocator.destroy(manager);
    manager.* = try session_manager.SessionManager.inMemory(std.testing.allocator, std.testing.io, "/tmp/project");
    errdefer if (!manager_transferred) manager.deinit();

    var root = try makeUserMessage("root prompt", 1);
    defer session_manager.deinitMessage(std.testing.allocator, &root);
    const root_id = try manager.appendMessage(root);

    var main = try makeAssistantMessage("main branch", model, 2);
    defer session_manager.deinitMessage(std.testing.allocator, &main);
    const main_id = try manager.appendMessage(main);

    try manager.branch(root_id);
    var alternate_prompt = try makeUserMessage("alternate prompt", 3);
    defer session_manager.deinitMessage(std.testing.allocator, &alternate_prompt);
    const alternate_user_id = try manager.appendMessage(alternate_prompt);

    var alternate_reply = try makeAssistantMessage("alternate reply", model, 4);
    defer session_manager.deinitMessage(std.testing.allocator, &alternate_reply);
    const alternate_reply_id = try manager.appendMessage(alternate_reply);

    try manager.branch(main_id);

    var session = try AgentSession.initWithManager(
        std.testing.allocator,
        std.testing.io,
        "/tmp/project",
        "system prompt",
        model,
        null,
        .off,
        &.{},
        .{},
        .{},
        &.{},
        1000,
        manager,
        "startup",
    );
    manager_transferred = true;
    defer session.deinit();

    var user_result = try session.navigateTree(std.testing.allocator, alternate_user_id, .{});
    defer user_result.deinit(std.testing.allocator);
    try std.testing.expect(user_result.editor_text != null);
    try std.testing.expectEqualStrings("alternate prompt", user_result.editor_text.?);
    try std.testing.expectEqualStrings(root_id, session.session_manager.getLeafId().?);
    try std.testing.expectEqual(@as(usize, 1), session.agent.getMessages().len);
    try std.testing.expectEqualStrings("root prompt", session.agent.getMessages()[0].user.content[0].text.text);

    try session.navigateTo(main_id);
    var summary_result = try session.navigateTree(std.testing.allocator, alternate_reply_id, .{
        .summarize = true,
        .summary_text = "summarized abandoned branch",
    });
    defer summary_result.deinit(std.testing.allocator);
    try std.testing.expect(summary_result.summary_entry_id != null);
    const summary_entry = session.session_manager.getEntry(summary_result.summary_entry_id.?);
    try std.testing.expect(summary_entry != null);
    try std.testing.expect(summary_entry.?.* == .branch_summary);
    try std.testing.expectEqualStrings(alternate_reply_id, summary_entry.?.branch_summary.parent_id.?);
    try std.testing.expectEqualStrings(summary_result.summary_entry_id.?, session.session_manager.getLeafId().?);
    try std.testing.expect(std.mem.indexOf(u8, session.agent.getMessages()[session.agent.getMessages().len - 1].user.content[0].text.text, "summarized abandoned branch") != null);
}

test "VAL-CROSS-006 session reload keeps errored partial assistant inert" {
    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    const manager = try std.testing.allocator.create(session_manager.SessionManager);
    var manager_transferred = false;
    errdefer if (!manager_transferred) std.testing.allocator.destroy(manager);
    manager.* = try session_manager.SessionManager.inMemory(std.testing.allocator, std.testing.io, "/tmp/project");
    errdefer if (!manager_transferred) manager.deinit();

    var prompt = try makeUserMessage("root", 1);
    defer session_manager.deinitMessage(std.testing.allocator, &prompt);
    _ = try manager.appendMessage(prompt);

    var errored = try makeErroredPartialAssistantMessage(model, 2);
    defer session_manager.deinitMessage(std.testing.allocator, &errored);
    _ = try manager.appendMessage(errored);

    var session = try AgentSession.initWithManager(
        std.testing.allocator,
        std.testing.io,
        "/tmp/project",
        "system prompt",
        model,
        null,
        .off,
        &.{},
        .{},
        .{},
        &.{},
        1000,
        manager,
        "startup",
    );
    manager_transferred = true;
    defer session.deinit();

    try session.reloadFromSession();
    try session.reloadFromSession();

    const messages = session.agent.getMessages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("root", messages[0].user.content[0].text.text);
    const entries = session.session_manager.getEntries();
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expect(entries[1] == .message);
    const assistant = entries[1].message.message.assistant;
    try std.testing.expectEqual(ai.StopReason.error_reason, assistant.stop_reason);
    try std.testing.expect(!ai.types.shouldReplayAssistantInProviderContext(assistant));
    try std.testing.expectEqual(@as(usize, 3), assistant.content.len);
    try std.testing.expectEqualStrings("partial text", assistant.content[0].text.text);
    try std.testing.expectEqualStrings("private thought", assistant.content[1].thinking.thinking);
    try std.testing.expectEqualStrings("partial-call", assistant.content[2].tool_call.id);
    try std.testing.expectEqualStrings("lookup", assistant.content[2].tool_call.name);
    try std.testing.expectEqualStrings("partial", assistant.content[2].tool_call.arguments.object.get("query").?.string);
    try std.testing.expect(assistant.tool_calls == null);
}

test "manual compaction replaces older history with a summary message" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("reply one with detail")}, .{}) },
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("reply two with detail")}, .{}) },
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("reply three with detail")}, .{}) },
    });

    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/session-project",
        .system_prompt = "system prompt",
        .model = registration.getModel(),
        .compaction = .{
            .keep_recent_tokens = 8,
        },
    });
    defer session.deinit();

    try session.prompt("first prompt with context");
    try session.prompt("second prompt with context");
    try session.prompt("third prompt with context");

    const result = try session.compact("focus on earlier work");
    try std.testing.expect(std.mem.containsAtLeast(u8, result.summary, 1, "focus on earlier work"));

    const messages = session.agent.getMessages();
    try std.testing.expect(messages.len >= 3);
    try std.testing.expectEqualStrings("[compaction]", messages[0].user.content[0].text.text[0..12]);
    try std.testing.expect(std.mem.containsAtLeast(u8, messages[0].user.content[0].text.text, 1, "first prompt"));
    try std.testing.expect(std.mem.containsAtLeast(u8, messages[messages.len - 2].user.content[0].text.text, 1, "third prompt"));
    try std.testing.expectEqualStrings("reply three with detail", messages[messages.len - 1].assistant.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), countCompactionEntries(session.session_manager.getEntries()));
}

test "auto compaction triggers when estimated context exceeds the threshold" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("assistant response one with extra text")}, .{}) },
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("assistant response two with extra text")}, .{}) },
    });

    var model = registration.getModel();
    model.context_window = 24;

    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/session-project",
        .system_prompt = "system prompt",
        .model = model,
        .compaction = .{
            .enabled = true,
            .reserve_tokens = 5,
            .keep_recent_tokens = 10,
        },
    });
    defer session.deinit();

    try session.prompt("first long prompt that fills context");
    try session.prompt("second long prompt that crosses the threshold");

    const messages = session.agent.getMessages();
    try std.testing.expect(messages.len >= 2);
    try std.testing.expect(messages[0] == .user);
    try std.testing.expect(std.mem.startsWith(u8, messages[0].user.content[0].text.text, "[compaction]\n"));
    try std.testing.expectEqualStrings("assistant response two with extra text", messages[messages.len - 1].assistant.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), countCompactionEntries(session.session_manager.getEntries()));
}

test "auto compaction recovers from overflow by compacting and continuing" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("warmup reply")}, .{}) },
        .{ .message = faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "Context overflow while generating" }) },
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("recovered after compaction")}, .{}) },
    });

    var model = registration.getModel();
    model.context_window = 32;

    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/session-project",
        .system_prompt = "system prompt",
        .model = model,
        .compaction = .{
            .enabled = true,
            .reserve_tokens = 4,
            .keep_recent_tokens = 8,
        },
    });
    defer session.deinit();

    try session.prompt("warmup prompt with detail");
    try session.prompt("second prompt that overflows");

    const messages = session.agent.getMessages();
    try std.testing.expect(messages.len >= 3);
    try std.testing.expect(std.mem.startsWith(u8, messages[0].user.content[0].text.text, "[compaction]\n"));
    try std.testing.expectEqualStrings("recovered after compaction", messages[messages.len - 1].assistant.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), countCompactionEntries(session.session_manager.getEntries()));
    try std.testing.expectEqual(@as(usize, 1), countAssistantMessagesWithStopReason(session.session_manager.getEntries(), .error_reason));
}

test "auto retry retries transient errors and eventually succeeds" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "503 service unavailable" }) },
        .{ .message = faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "connection lost" }) },
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("retry succeeded")}, .{}) },
    });

    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/session-project",
        .system_prompt = "system prompt",
        .model = registration.getModel(),
        .retry = .{
            .enabled = true,
            .max_retries = 3,
            .base_delay_ms = 1,
        },
    });
    defer session.deinit();

    try session.prompt("hello retry");

    const messages = session.agent.getMessages();
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("retry succeeded", messages[1].assistant.content[0].text.text);
    try std.testing.expectEqual(@as(u32, 0), session.retry_attempt);
    try std.testing.expectEqual(@as(usize, 2), countAssistantMessagesWithStopReason(session.session_manager.getEntries(), .error_reason));
}

test "auto retry gives up after the configured max attempts" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "503 service unavailable" }) },
        .{ .message = faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "503 service unavailable" }) },
        .{ .message = faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "503 service unavailable" }) },
    });

    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/session-project",
        .system_prompt = "system prompt",
        .model = registration.getModel(),
        .retry = .{
            .enabled = true,
            .max_retries = 2,
            .base_delay_ms = 1,
        },
    });
    defer session.deinit();

    try session.prompt("hello retry failure");

    const messages = session.agent.getMessages();
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expect(messages[1] == .assistant);
    try std.testing.expectEqual(ai.StopReason.error_reason, messages[1].assistant.stop_reason);
    try std.testing.expectEqualStrings("503 service unavailable", messages[1].assistant.error_message.?);
    try std.testing.expectEqual(@as(u32, 0), session.retry_attempt);
    try std.testing.expectEqual(@as(usize, 3), countAssistantMessagesWithStopReason(session.session_manager.getEntries(), .error_reason));
}

fn countCompactionEntries(entries: []const session_manager.SessionEntry) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (entry == .compaction) count += 1;
    }
    return count;
}

fn countAssistantMessagesWithStopReason(entries: []const session_manager.SessionEntry, stop_reason: ai.StopReason) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (entry != .message) continue;
        switch (entry.message.message) {
            .assistant => |assistant_message| {
                if (assistant_message.stop_reason == stop_reason) count += 1;
            },
            else => {},
        }
    }
    return count;
}

fn makeUserMessage(text: []const u8, timestamp: i64) !agent.AgentMessage {
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, text) } };
    return .{ .user = .{
        .role = try std.testing.allocator.dupe(u8, "user"),
        .content = blocks,
        .timestamp = timestamp,
    } };
}

fn makeAssistantMessage(text: []const u8, model: ai.Model, timestamp: i64) !agent.AgentMessage {
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, text) } };
    return .{ .assistant = .{
        .role = try std.testing.allocator.dupe(u8, "assistant"),
        .content = blocks,
        .tool_calls = null,
        .api = try std.testing.allocator.dupe(u8, model.api),
        .provider = try std.testing.allocator.dupe(u8, model.provider),
        .model = try std.testing.allocator.dupe(u8, model.id),
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = timestamp,
    } };
}

fn makeErroredPartialAssistantMessage(model: ai.Model, timestamp: i64) !agent.AgentMessage {
    var args_object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    try args_object.put(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, "query"),
        .{ .string = try std.testing.allocator.dupe(u8, "partial") },
    );
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 3);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, "partial text") } };
    blocks[1] = .{ .thinking = .{
        .thinking = try std.testing.allocator.dupe(u8, "private thought"),
        .thinking_signature = try std.testing.allocator.dupe(u8, "think-sig"),
    } };
    blocks[2] = .{ .tool_call = .{
        .id = try std.testing.allocator.dupe(u8, "partial-call"),
        .name = try std.testing.allocator.dupe(u8, "lookup"),
        .arguments = .{ .object = args_object },
        .thought_signature = try std.testing.allocator.dupe(u8, "tool-sig"),
    } };
    return .{ .assistant = .{
        .role = try std.testing.allocator.dupe(u8, "assistant"),
        .content = blocks,
        .tool_calls = null,
        .api = try std.testing.allocator.dupe(u8, model.api),
        .provider = try std.testing.allocator.dupe(u8, model.provider),
        .model = try std.testing.allocator.dupe(u8, model.id),
        .response_id = try std.testing.allocator.dupe(u8, "resp-partial-error"),
        .usage = ai.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = try std.testing.allocator.dupe(u8, "provider failed after partials"),
        .timestamp = timestamp,
    } };
}

const TestHookHost = struct {
    input: bool = false,
    before_agent_start: bool = false,
    context: bool = false,
    session_start: bool = false,
    resources_discover: bool = false,
    agent_start: bool = false,
    agent_end: bool = false,
    session_shutdown: bool = false,
    turn_start: bool = false,
    message_start: bool = false,
    message_update: bool = false,
    message_end: bool = false,
    turn_end: bool = false,
    tool_execution_start: bool = false,
    tool_execution_update: bool = false,
    tool_execution_end: bool = false,
    tool_call: bool = false,
    tool_result: bool = false,
    label: []const u8 = "",
    order_log: ?*std.ArrayList([]const u8) = null,
    order_allocator: ?std.mem.Allocator = null,
    input_calls: usize = 0,
    before_calls: usize = 0,
    context_calls: usize = 0,
    session_start_calls: usize = 0,
    resources_discover_calls: usize = 0,
    agent_start_calls: usize = 0,
    agent_end_calls: usize = 0,
    session_shutdown_calls: usize = 0,
    turn_start_calls: usize = 0,
    message_start_calls: usize = 0,
    message_update_calls: usize = 0,
    message_end_calls: usize = 0,
    turn_end_calls: usize = 0,
    tool_execution_start_calls: usize = 0,
    tool_execution_update_calls: usize = 0,
    tool_execution_end_calls: usize = 0,
    tool_call_calls: usize = 0,
    tool_result_calls: usize = 0,
    input_handled: bool = false,
    before_agent_start_handled: bool = false,
    context_invalid: bool = false,
    message_end_replacement: ?[]const u8 = null,
    saw_agent_end_messages: bool = false,
    saw_message_update_assistant_event: bool = false,
    saw_tool_result_message_start: bool = false,
    saw_tool_result_message_end: bool = false,
    saw_tool_execution_identity: bool = false,
    saw_tool_execution_partial_result: bool = false,
    saw_tool_execution_result: bool = false,
    fail_event_name: ?[]const u8 = null,

    fn adapter(self: *TestHookHost) extension_runtime.RuntimeAdapter {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &test_hook_vtable,
            .kind = .process_jsonl,
        };
    }
};

fn testHookHost(ptr: *anyopaque) *TestHookHost {
    return @ptrCast(@alignCast(ptr));
}

fn testHookWait(ptr: *anyopaque, timeout_ms: u64) !void {
    _ = ptr;
    _ = timeout_ms;
}
fn testHookZero(ptr: *anyopaque) usize {
    _ = ptr;
    return 0;
}
fn testHookFalse(ptr: *anyopaque) bool {
    _ = ptr;
    return false;
}
fn testHookCategoryCount(ptr: *anyopaque, category: extension_runtime.DiagnosticCategory) usize {
    _ = ptr;
    _ = category;
    return 0;
}
fn testHookHasCommand(ptr: *anyopaque, name: []const u8) bool {
    _ = ptr;
    _ = name;
    return false;
}
fn testHookHasHook(ptr: *anyopaque, event_name: []const u8) bool {
    const host = testHookHost(ptr);
    if (std.mem.eql(u8, event_name, "input")) return host.input;
    if (std.mem.eql(u8, event_name, "before_agent_start")) return host.before_agent_start;
    if (std.mem.eql(u8, event_name, "context")) return host.context;
    if (std.mem.eql(u8, event_name, "session_start")) return host.session_start;
    if (std.mem.eql(u8, event_name, "resources_discover")) return host.resources_discover;
    if (std.mem.eql(u8, event_name, "agent_start")) return host.agent_start;
    if (std.mem.eql(u8, event_name, "agent_end")) return host.agent_end;
    if (std.mem.eql(u8, event_name, "session_shutdown")) return host.session_shutdown;
    if (std.mem.eql(u8, event_name, "turn_start")) return host.turn_start;
    if (std.mem.eql(u8, event_name, "message_start")) return host.message_start;
    if (std.mem.eql(u8, event_name, "message_update")) return host.message_update;
    if (std.mem.eql(u8, event_name, "message_end")) return host.message_end;
    if (std.mem.eql(u8, event_name, "turn_end")) return host.turn_end;
    if (std.mem.eql(u8, event_name, "tool_execution_start")) return host.tool_execution_start;
    if (std.mem.eql(u8, event_name, "tool_execution_update")) return host.tool_execution_update;
    if (std.mem.eql(u8, event_name, "tool_execution_end")) return host.tool_execution_end;
    if (std.mem.eql(u8, event_name, "tool_call")) return host.tool_call;
    if (std.mem.eql(u8, event_name, "tool_result")) return host.tool_result;
    return false;
}
fn testHookSnapshot(ptr: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    _ = ptr;
    return try allocator.dupe(u8, "{}");
}
fn testHookWithRegistry(ptr: *anyopaque, context: ?*anyopaque, callback: extension_runtime.RegistryCallback) !void {
    _ = ptr;
    _ = context;
    _ = callback;
}
fn testHookApplyFlags(ptr: *anyopaque, entries: []const @import("../extensions/extension_registry.zig").ParsedCliFlag) !void {
    _ = ptr;
    _ = entries;
}
fn testHookAgentTool(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) !?agent.AgentTool {
    _ = ptr;
    _ = allocator;
    _ = name;
    return null;
}
fn testHookUiRequests(ptr: *anyopaque, allocator: std.mem.Allocator) ![]extension_runtime.ExtensionUiRequest {
    _ = ptr;
    return try allocator.alloc(extension_runtime.ExtensionUiRequest, 0);
}
fn testHookUiResponse(ptr: *anyopaque, id: []const u8, payload_json: []const u8) !void {
    _ = ptr;
    _ = id;
    _ = payload_json;
}
fn testHookEventFrame(ptr: *anyopaque, frame_json: []const u8) void {
    _ = ptr;
    _ = frame_json;
}
fn testHookInvoke(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    event_name: []const u8,
    event: std.json.Value,
    timeout_ms: u64,
) !?std.json.Value {
    _ = timeout_ms;
    const host = testHookHost(ptr);
    if (host.order_log) |log| {
        const name = if (host.label.len > 0) host.label else event_name;
        try log.append(host.order_allocator orelse allocator, name);
    }
    if (host.fail_event_name) |fail_event_name| {
        if (std.mem.eql(u8, event_name, fail_event_name)) return error.TestHookHostInjectedFailure;
    }
    var result = try makeObject(allocator);
    errdefer tools_common.deinitJsonValue(allocator, result);
    if (std.mem.eql(u8, event_name, "input")) {
        host.input_calls += 1;
        if (host.input_handled) {
            try putString(allocator, &result.object, "action", "handled");
            try putString(allocator, &result.object, "reason", "input denied by fixture");
            return result;
        }
        try putString(allocator, &result.object, "text", "hooked input");
        return result;
    }
    if (std.mem.eql(u8, event_name, "before_agent_start")) {
        host.before_calls += 1;
        if (host.before_agent_start_handled) {
            try putString(allocator, &result.object, "action", "deny");
            try putString(allocator, &result.object, "reason", "startup denied by fixture");
            return result;
        }
        try putString(allocator, &result.object, "text", "hooked before");
        try putString(allocator, &result.object, "systemPrompt", "hook system");
        return result;
    }
    if (std.mem.eql(u8, event_name, "context")) {
        host.context_calls += 1;
        var messages = std.json.Array.init(allocator);
        if (host.context_invalid) {
            var invalid = try makeObject(allocator);
            try putString(allocator, &invalid.object, "role", "user");
            try messages.append(invalid);
            try putValue(allocator, &result.object, "messages", .{ .array = messages });
            return result;
        }
        try messages.append(.{ .string = try allocator.dupe(u8, "hook context") });
        try putValue(allocator, &result.object, "messages", .{ .array = messages });
        return result;
    }
    if (std.mem.eql(u8, event_name, "session_start")) {
        host.session_start_calls += 1;
        try std.testing.expectEqualStrings("session_start", event.object.get("type").?.string);
        try std.testing.expectEqualStrings("startup", event.object.get("reason").?.string);
        return result;
    }
    if (std.mem.eql(u8, event_name, "resources_discover")) {
        host.resources_discover_calls += 1;
        try std.testing.expectEqualStrings("resources_discover", event.object.get("type").?.string);
        try std.testing.expectEqualStrings("/tmp/lifecycle-forwarding", event.object.get("cwd").?.string);
        try std.testing.expectEqualStrings("startup", event.object.get("reason").?.string);
        var skills = std.json.Array.init(allocator);
        try skills.append(.{ .string = try allocator.dupe(u8, "fixture/skills") });
        try putValue(allocator, &result.object, "skillPaths", .{ .array = skills });
        return result;
    }
    if (std.mem.eql(u8, event_name, "agent_start")) {
        host.agent_start_calls += 1;
        try std.testing.expectEqualStrings("agent_start", event.object.get("type").?.string);
        return result;
    }
    if (std.mem.eql(u8, event_name, "agent_end")) {
        host.agent_end_calls += 1;
        try std.testing.expectEqualStrings("agent_end", event.object.get("type").?.string);
        if (event.object.get("messages")) |messages| {
            if (messages == .array and messages.array.items.len > 0) {
                host.saw_agent_end_messages = true;
            }
        }
        return result;
    }
    if (std.mem.eql(u8, event_name, "session_shutdown")) {
        host.session_shutdown_calls += 1;
        try std.testing.expectEqualStrings("session_shutdown", event.object.get("type").?.string);
        try std.testing.expectEqualStrings("quit", event.object.get("reason").?.string);
        return result;
    }
    if (std.mem.eql(u8, event_name, "turn_start")) {
        host.turn_start_calls += 1;
        return result;
    }
    if (std.mem.eql(u8, event_name, "message_start")) {
        host.message_start_calls += 1;
        try testHookExpectToolResultMessage(host, event, true);
        return result;
    }
    if (std.mem.eql(u8, event_name, "message_update")) {
        host.message_update_calls += 1;
        try testHookExpectMessageUpdate(host, event);
        return result;
    }
    if (std.mem.eql(u8, event_name, "message_end")) {
        host.message_end_calls += 1;
        const message = event.object.get("message").?.object;
        const role = message.get("role").?.string;
        try testHookExpectToolResultMessage(host, event, false);
        if (host.message_end_replacement) |replacement| {
            if (std.mem.eql(u8, role, "assistant")) {
                try putString(allocator, &result.object, "role", "assistant");
                try putString(allocator, &result.object, "message", replacement);
            }
        }
        return result;
    }
    if (std.mem.eql(u8, event_name, "turn_end")) {
        host.turn_end_calls += 1;
        return result;
    }
    if (std.mem.eql(u8, event_name, "tool_execution_start")) {
        host.tool_execution_start_calls += 1;
        try testHookExpectToolExecutionStart(host, event);
        return result;
    }
    if (std.mem.eql(u8, event_name, "tool_execution_update")) {
        host.tool_execution_update_calls += 1;
        try testHookExpectToolExecutionUpdate(host, event);
        return result;
    }
    if (std.mem.eql(u8, event_name, "tool_execution_end")) {
        host.tool_execution_end_calls += 1;
        try testHookExpectToolExecutionEnd(host, event);
        return result;
    }
    if (std.mem.eql(u8, event_name, "tool_call")) {
        host.tool_call_calls += 1;
        var input = try makeObject(allocator);
        try putString(allocator, &input.object, "value", "mutated");
        try putValue(allocator, &result.object, "input", input);
        return result;
    }
    if (std.mem.eql(u8, event_name, "tool_result")) {
        host.tool_result_calls += 1;
        try putString(allocator, &result.object, "content", "patched result");
        try putBool(allocator, &result.object, "isError", false);
        return result;
    }
    return result;
}

fn testHookExpectToolResultMessage(host: *TestHookHost, event: std.json.Value, is_start: bool) !void {
    const message = event.object.get("message").?.object;
    const role = message.get("role").?.string;
    if (!std.mem.eql(u8, role, "toolResult")) return;
    if (is_start) {
        host.saw_tool_result_message_start = true;
    } else {
        host.saw_tool_result_message_end = true;
    }
    try std.testing.expectEqualStrings("lifecycle-call", message.get("toolCallId").?.string);
    try std.testing.expectEqualStrings("lifecycle_tool", message.get("toolName").?.string);
    try std.testing.expect(message.get("details") != null);
    try std.testing.expect(!message.get("isError").?.bool);
}

fn testHookExpectMessageUpdate(host: *TestHookHost, event: std.json.Value) !void {
    try std.testing.expectEqualStrings("message_update", event.object.get("type").?.string);
    try std.testing.expectEqualStrings("assistant", event.object.get("message").?.object.get("role").?.string);
    if (event.object.get("assistantMessageEvent")) |assistant_event| {
        if (assistant_event == .object and assistant_event.object.get("type") != null) {
            host.saw_message_update_assistant_event = true;
        }
    }
}

fn testHookExpectToolExecutionStart(host: *TestHookHost, event: std.json.Value) !void {
    try std.testing.expectEqualStrings("lifecycle-call", event.object.get("toolCallId").?.string);
    try std.testing.expectEqualStrings("lifecycle_tool", event.object.get("toolName").?.string);
    try std.testing.expectEqualStrings("tool input", event.object.get("args").?.object.get("value").?.string);
    host.saw_tool_execution_identity = true;
}

fn testHookExpectToolExecutionUpdate(host: *TestHookHost, event: std.json.Value) !void {
    try std.testing.expectEqualStrings("lifecycle-call", event.object.get("toolCallId").?.string);
    try std.testing.expectEqualStrings("lifecycle_tool", event.object.get("toolName").?.string);
    const partial_result = event.object.get("partialResult").?.object;
    try std.testing.expectEqualStrings("partial tool output", partial_result.get("content").?.array.items[0].object.get("text").?.string);
    host.saw_tool_execution_partial_result = true;
}

fn testHookExpectToolExecutionEnd(host: *TestHookHost, event: std.json.Value) !void {
    try std.testing.expectEqualStrings("lifecycle-call", event.object.get("toolCallId").?.string);
    try std.testing.expectEqualStrings("lifecycle_tool", event.object.get("toolName").?.string);
    const tool_result = event.object.get("result").?.object;
    try std.testing.expectEqualStrings("final tool output", tool_result.get("content").?.array.items[0].object.get("text").?.string);
    try std.testing.expect(!event.object.get("isError").?.bool);
    host.saw_tool_execution_result = true;
}

fn testHookShutdown(ptr: *anyopaque) !void {
    _ = ptr;
}
fn testHookDeinit(ptr: *anyopaque) void {
    _ = ptr;
}

const test_hook_vtable: extension_runtime.RuntimeAdapter.VTable = .{
    .wait_for_ready = testHookWait,
    .pending_count = testHookZero,
    .diagnostic_count = testHookZero,
    .diagnostic_category_count = testHookCategoryCount,
    .has_shutdown_complete = testHookFalse,
    .registry_frames_applied = testHookZero,
    .has_registered_command = testHookHasCommand,
    .has_registered_hook = testHookHasHook,
    .snapshot_registry_json = testHookSnapshot,
    .with_registry = testHookWithRegistry,
    .apply_cli_flag_values = testHookApplyFlags,
    .agent_tool = testHookAgentTool,
    .take_ui_requests = testHookUiRequests,
    .send_extension_ui_response = testHookUiResponse,
    .send_extension_event_frame = testHookEventFrame,
    .invoke_extension_event = testHookInvoke,
    .shutdown = testHookShutdown,
    .deinit = testHookDeinit,
};

test "mixed runtime adapter helper covers tool hook workflow shutdown contracts" {
    const allocator = std.testing.allocator;
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const response_allocator = arena.allocator();

    const process_args = try jsonObjectWithString(response_allocator, "value", "process-input");
    const wasm_args = try jsonObjectWithTruncateInput(response_allocator, "alpha\nbravo\ncharlie", 2, 1024);
    const native_args = try jsonObjectWithString(response_allocator, "value", "native-input");
    const workflow_args = try jsonObjectWithString(response_allocator, "issue", "mixed-flow");
    const blocks = try response_allocator.alloc(faux.FauxContentBlock, 4);
    blocks[0] = try faux.fauxToolCall(response_allocator, "process-cross-tool", process_args, .{ .id = "cross-process-call" });
    blocks[1] = try faux.fauxToolCall(response_allocator, "builtin.truncateHead", wasm_args, .{ .id = "cross-wasm-call" });
    blocks[2] = try faux.fauxToolCall(response_allocator, "native.cross.echo", native_args, .{ .id = "cross-native-call" });
    blocks[3] = try faux.fauxToolCall(response_allocator, "workflow.cross-chain", workflow_args, .{ .id = "cross-workflow-call" });
    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("mixed runtime complete")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use }) },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const process_capture_path = try absoluteSessionTmpPath(allocator, &tmp.sub_path, "cross-runtime-process-capture.jsonl");
    defer allocator.free(process_capture_path);
    const process_script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; printf '%s\\n' \"$init\" > {s}; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "printf '{{\"type\":\"register_tool\",\"name\":\"process-cross-tool\",\"label\":\"Process Cross Tool\",\"description\":\"cross runtime process tool\",\"parameters\":{{\"type\":\"object\",\"required\":[\"value\"],\"properties\":{{\"value\":{{\"type\":\"string\"}}}},\"additionalProperties\":false}},\"extensionPath\":\"fixture/process-cross.ts\"}}\\n'; " ++
            "for hook in input before_agent_start context tool_call tool_result turn_start message_end turn_end; do printf '{{\"type\":\"register_hook\",\"event\":\"%s\",\"priority\":0,\"declarationOrder\":0,\"errorPolicy\":\"continue\",\"extensionPath\":\"fixture/process-cross.ts\"}}\\n' \"$hook\"; done; " ++
            "printf '{{\"type\":\"register_workflow\",\"id\":\"cross-chain\",\"description\":\"Mixed runtime workflow\",\"inputSchema\":{{\"type\":\"object\",\"required\":[\"issue\"],\"properties\":{{\"issue\":{{\"type\":\"string\"}}}},\"additionalProperties\":false}},\"outputSchema\":{{\"type\":\"object\",\"required\":[\"summary\"],\"properties\":{{\"summary\":{{\"type\":\"string\"}}}}}},\"toolName\":\"workflow.cross-chain\",\"commandName\":\"workflow-cross-chain\",\"presetId\":\"workflow-cross-chain-preset\",\"permissions\":[\"agent.delegate\"],\"childAgentLimits\":{{\"maxChildren\":1,\"maxTurns\":1,\"maxToolCalls\":1,\"timeoutMs\":100}},\"steps\":[{{\"id\":\"process-step\",\"kind\":\"side_effect\",\"input\":{{\"value\":\"from-workflow\"}},\"output\":{{\"runtime\":\"process\"}},\"replayMode\":\"recorded\",\"selectedCapability\":\"process-cross-tool\"}},{{\"id\":\"wasm-step\",\"kind\":\"side_effect\",\"input\":{{\"content\":\"alpha\\\\nbravo\",\"maxLines\":1,\"maxBytes\":1024}},\"output\":{{\"runtime\":\"wasm\"}},\"replayMode\":\"recorded\",\"selectedCapability\":\"builtin.truncateHead\"}},{{\"id\":\"native-step\",\"kind\":\"side_effect\",\"input\":{{\"value\":\"from-workflow\"}},\"output\":{{\"runtime\":\"native\"}},\"replayMode\":\"recorded\",\"selectedCapability\":\"native.cross.echo\"}},{{\"id\":\"child-step\",\"kind\":\"child_agent\",\"childDelta\":{{\"childrenStarted\":1,\"turns\":1,\"toolCalls\":1,\"elapsedMs\":10,\"permission\":\"agent.delegate\"}},\"output\":{{\"summary\":\"mixed workflow complete\"}},\"selectedCapability\":\"agent.delegate\"}}],\"extensionPath\":\"fixture/workflows.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_workflow\",\"id\":\"cross-cancel\",\"description\":\"Cancellable mixed workflow\",\"inputSchema\":{{\"type\":\"object\"}},\"outputSchema\":{{}},\"toolName\":\"workflow.cross-cancel\",\"steps\":[{{\"id\":\"active\",\"runtimeWork\":true,\"output\":{{\"ok\":true}}}}],\"extensionPath\":\"fixture/workflows.ts\"}}\\n'; " ++
            "while IFS= read -r line; do " ++
            "printf '%s\\n' \"$line\" >> {s}; " ++
            "case \"$line\" in " ++
            "*'\"type\":\"extension_event\"'*) event_id=$(printf '%s' \"$line\" | sed -n 's/.*\"eventId\":\"\\([^\"]*\\)\".*/\\1/p'); printf '{{\"type\":\"extension_event_result\",\"eventId\":\"%s\",\"result\":{{}}}}\\n' \"$event_id\";; " ++
            "*'\"toolName\":\"process-cross-tool\"'*) tool_call_id=$(printf '%s' \"$line\" | sed -n 's/.*\"toolCallId\":\"\\([^\"]*\\)\".*/\\1/p'); printf '{{\"type\":\"tool_result\",\"toolCallId\":\"%s\",\"content\":[{{\"type\":\"text\",\"text\":\"process cross ok\"}}],\"details\":{{\"runtime\":\"process_jsonl\",\"phase\":\"call\"}}}}\\n' \"$tool_call_id\";; " ++
            "*'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; " ++
            "esac; done",
        .{ process_capture_path, process_capture_path },
    );
    defer allocator.free(process_script);
    const process_argv = [_][]const u8{ "/bin/sh", "-c", process_script, "cross-runtime-process" };
    const process_adapter = try extension_runtime.startRuntimeAdapter(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &process_argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "cross-runtime-process",
            .cwd = "/cross-runtime-cwd",
            .fixture = "cross-runtime-process",
        },
        .shutdown_timeout_ms = 500,
    } });
    defer process_adapter.deinit();
    try process_adapter.waitForReady(500);
    var process_elapsed: u64 = 0;
    while (process_adapter.registryFramesApplied() < 11 and process_elapsed <= 1000) : (process_elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 11), process_adapter.registryFramesApplied());

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const wasm_adapter = try extension_runtime.startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
        .manifest = extension_runtime.WasmManifestHandoff.fromManifest(&manifest_result.valid),
    } });
    defer wasm_adapter.deinit();
    try wasm_adapter.waitForReady(0);

    const native_adapter = try extension_runtime.startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
        .descriptor = &cross_native_descriptor,
    } });
    defer native_adapter.deinit();
    try native_adapter.waitForReady(0);

    var process_tool = (try process_adapter.agentTool(allocator, "process-cross-tool")).?;
    defer extension_runtime.deinitAgentTool(allocator, &process_tool);
    var wasm_tool = (try wasm_adapter.agentTool(allocator, "builtin.truncateHead")).?;
    defer extension_runtime.deinitAgentTool(allocator, &wasm_tool);
    var native_tool = (try native_adapter.agentTool(allocator, "native.cross.echo")).?;
    defer extension_runtime.deinitAgentTool(allocator, &native_tool);
    var workflow_tool = (try process_adapter.agentTool(allocator, "workflow.cross-chain")).?;
    defer extension_runtime.deinitAgentTool(allocator, &workflow_tool);
    var cancel_tool = (try process_adapter.agentTool(allocator, "workflow.cross-cancel")).?;
    defer extension_runtime.deinitAgentTool(allocator, &cancel_tool);

    const extension_hosts = [_]extension_runtime.RuntimeAdapter{ process_adapter, wasm_adapter, native_adapter };
    var session_tools = [_]agent.AgentTool{ process_tool, wasm_tool, native_tool, workflow_tool };
    try extension_runtime.attachWorkflowDispatchAdapters(allocator, session_tools[0..], extension_hosts[0..]);
    var session = try AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/cross-runtime-e2e",
        .system_prompt = "system",
        .model = registration.getModel(),
        .tools = session_tools[0..],
        .extension_hosts = extension_hosts[0..],
    });
    defer session.deinit();
    try session.prompt("run mixed runtime flow");

    const messages = session.agent.getMessages();
    try std.testing.expect(messages.len >= 7);
    try std.testing.expectEqualStrings("mixed runtime complete", messages[messages.len - 1].assistant.content[0].text.text);
    try expectToolResultContains(messages, "process-cross-tool", "process cross ok");
    try expectToolResultContains(messages, "builtin.truncateHead", "\"content\":\"alpha\\nbravo\"");
    try expectToolResultContains(messages, "native.cross.echo", "\"runtime\":\"native\"");
    try expectToolResultContains(messages, "workflow.cross-chain", "mixed workflow complete");

    var cancel_signal = std.atomic.Value(bool).init(true);
    var empty_input = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer empty_input.deinit();
    const cancelled = try cancel_tool.execute.?(allocator, "cross-cancel-call", empty_input.value, cancel_tool.execute_context, &cancel_signal, null, null);
    defer tools_common.deinitContentBlocks(allocator, cancelled.content);
    defer if (cancelled.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), cancelled.is_error);
    try std.testing.expectEqualStrings("cancelled", cancelled.details.?.object.get("state").?.string);
    try std.testing.expectEqualStrings("active", cancelled.details.?.object.get("workflow").?.object.get("cancellationPoint").?.string);

    const process_capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, process_capture_path, allocator, .unlimited);
    defer allocator.free(process_capture);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "\"type\":\"initialize\",\"marker\":\"cross-runtime-process\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "\"type\":\"extension_event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "process-cross-tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "builtin.truncateHead") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "native.cross.echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "workflow.cross-chain") != null);

    const loaded_process_snapshot = try process_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(loaded_process_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, loaded_process_snapshot, "\"name\":\"process-cross-tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, loaded_process_snapshot, "\"id\":\"cross-chain\"") != null);
    const loaded_wasm_snapshot = try wasm_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(loaded_wasm_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, loaded_wasm_snapshot, "\"name\":\"builtin.truncateHead\"") != null);
    const loaded_native_snapshot = try native_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(loaded_native_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, loaded_native_snapshot, "\"name\":\"native.cross.echo\"") != null);

    try process_adapter.shutdown();
    try wasm_adapter.shutdown();
    try native_adapter.shutdown();
    try std.testing.expect(process_adapter.hasShutdownComplete());
    try std.testing.expect(wasm_adapter.hasShutdownComplete());
    try std.testing.expect(native_adapter.hasShutdownComplete());
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try process_adapter.agentTool(allocator, "process-cross-tool"));
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try wasm_adapter.agentTool(allocator, "builtin.truncateHead"));
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try native_adapter.agentTool(allocator, "native.cross.echo"));

    var stale_process_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"stale\"}", .{});
    defer stale_process_params.deinit();
    const stale_process = try process_tool.execute.?(allocator, "stale-process-call", stale_process_params.value, process_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, stale_process.content);
    defer if (stale_process.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), stale_process.is_error);
    try std.testing.expectEqualStrings("ToolNotRegistered", stale_process.details.?.object.get("code").?.string);

    var stale_wasm_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"content\":\"alpha\",\"maxLines\":1,\"maxBytes\":1024}", .{});
    defer stale_wasm_params.deinit();
    try std.testing.expectError(error.WasmToolNotRegistered, wasm_tool.execute.?(allocator, "stale-wasm-call", stale_wasm_params.value, wasm_tool.execute_context, null, null, null));

    var stale_native_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"stale\"}", .{});
    defer stale_native_params.deinit();
    try std.testing.expectError(error.NativeToolNotRegistered, native_tool.execute.?(allocator, "stale-native-call", stale_native_params.value, native_tool.execute_context, null, null, null));

    const shutdown_process_snapshot = try process_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(shutdown_process_snapshot);
    const shutdown_wasm_snapshot = try wasm_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(shutdown_wasm_snapshot);
    const shutdown_native_snapshot = try native_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(shutdown_native_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, shutdown_process_snapshot, "\"tools\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, shutdown_wasm_snapshot, "\"tools\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, shutdown_native_snapshot, "\"tools\":[]") != null);
}

test "extension event hooks mutate input before start and context during session prompt" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("reply")}, .{}) },
    });

    var fixture = TestHookHost{
        .input = true,
        .before_agent_start = true,
        .context = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("original");

    try std.testing.expectEqual(@as(usize, 1), fixture.input_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.before_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.context_calls);
    try std.testing.expectEqualStrings("system", session.agent.getSystemPrompt());
    try std.testing.expectEqualStrings("hooked before", session.agent.getMessages()[0].user.content[0].text.text);
}

test "extension input hook handled result records visible diagnostic and skips provider turn" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("must not run")}, .{}) },
    });

    var fixture = TestHookHost{
        .input = true,
        .input_handled = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/input-hook-denial",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("denied");

    try std.testing.expectEqual(@as(usize, 1), fixture.input_calls);
    const messages = session.agent.getMessages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expect(messages[0] == .assistant);
    try std.testing.expectEqual(ai.StopReason.error_reason, messages[0].assistant.stop_reason);
    try std.testing.expect(std.mem.indexOf(u8, messages[0].assistant.error_message.?, "extensionId=process_jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages[0].assistant.error_message.?, "hook=input") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages[0].assistant.error_message.?, "reason=input denied by fixture") != null);
}

test "extension before_agent_start denial records visible diagnostic and skips provider turn" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("must not run")}, .{}) },
    });

    var fixture = TestHookHost{
        .before_agent_start = true,
        .before_agent_start_handled = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/before-hook-denial",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("denied before");

    try std.testing.expectEqual(@as(usize, 1), fixture.before_calls);
    const messages = session.agent.getMessages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expect(messages[0] == .assistant);
    try std.testing.expectEqual(ai.StopReason.error_reason, messages[0].assistant.stop_reason);
    try std.testing.expect(std.mem.indexOf(u8, messages[0].assistant.error_message.?, "extensionId=process_jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages[0].assistant.error_message.?, "hook=before_agent_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages[0].assistant.error_message.?, "reason=startup denied by fixture") != null);
}

test "extension context hook records invalid contribution diagnostic and preserves base context" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("base-only reply")}, .{}) },
    });

    var fixture = TestHookHost{
        .context = true,
        .context_invalid = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/invalid-context-hook",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("base prompt");

    try std.testing.expectEqual(@as(usize, 1), fixture.context_calls);
    const messages = session.agent.getMessages();
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqualStrings("base prompt", messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("base-only reply", messages[1].assistant.content[0].text.text);
    try std.testing.expect(messages[2] == .assistant);
    try std.testing.expectEqual(ai.StopReason.error_reason, messages[2].assistant.stop_reason);
    const diagnostic = messages[2].assistant.error_message.?;
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "Invalid extension context hook contribution") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "extensionId=process_jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "hook=context") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "path=$.messages[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "missing string content or text field") != null);
}

test "extension tool hooks mutate arguments and patch results" {
    var fixture = TestHookHost{
        .tool_call = true,
        .tool_result = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    const hook_context = ExtensionHookContext{
        .allocator = std.testing.allocator,
        .hosts = adapters[0..],
        .timeout_ms = 1000,
    };
    var args = try makeObject(std.testing.allocator);
    defer tools_common.deinitJsonValue(std.testing.allocator, args);
    try putString(std.testing.allocator, &args.object, "value", "original");
    const tool_call = ai.ToolCall{
        .id = "tool-1",
        .name = "fixture-tool",
        .arguments = .null,
    };
    const agent_context = agent.AgentContext{
        .system_prompt = "system",
        .messages = &.{},
        .tools = &.{},
        .extension_hook_context = @constCast(&hook_context),
    };
    _ = try beforeToolCallHook(std.testing.allocator, .{
        .assistant_message = .{
            .content = &.{},
            .api = "faux",
            .provider = "faux",
            .model = "faux-1",
            .usage = ai.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 1,
        },
        .tool_call = tool_call,
        .args = &args,
        .context = agent_context,
    }, null);
    try std.testing.expectEqual(@as(usize, 1), fixture.tool_call_calls);
    try std.testing.expectEqualStrings("mutated", args.object.get("value").?.string);

    const raw_content = try tools_common.makeTextContent(std.testing.allocator, "raw result");
    defer {
        std.testing.allocator.free(raw_content[0].text.text);
        std.testing.allocator.free(raw_content);
    }
    const patch = (try afterToolCallHook(std.testing.allocator, .{
        .assistant_message = .{
            .content = &.{},
            .api = "faux",
            .provider = "faux",
            .model = "faux-1",
            .usage = ai.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 1,
        },
        .tool_call = tool_call,
        .args = args,
        .result = .{ .content = raw_content },
        .is_error = false,
        .context = agent_context,
    }, null)).?;
    defer if (patch.content) |content| {
        std.testing.allocator.free(content[0].text.text);
        std.testing.allocator.free(content);
    };
    try std.testing.expectEqual(@as(usize, 1), fixture.tool_result_calls);
    try std.testing.expectEqualStrings("patched result", patch.content.?[0].text.text);
    try std.testing.expectEqual(false, patch.is_error.?);
}

fn lifecycleToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    _: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    try std.testing.expectEqualStrings("tool input", params.object.get("value").?.string);
    if (on_update) |callback| {
        const partial_content = try tools_common.makeTextContent(allocator, "partial tool output");
        try callback(on_update_context, .{ .content = partial_content });
    }
    var details = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try putString(allocator, &details, "phase", "final");
    return .{
        .content = try tools_common.makeTextContent(allocator, "final tool output"),
        .details = .{ .object = details },
        .is_error = false,
    };
}

fn firstEventIndex(events: []const []const u8, name: []const u8) !usize {
    for (events, 0..) |event_name, index| {
        if (std.mem.eql(u8, event_name, name)) return index;
    }
    return error.ExpectedEventNotFound;
}

test "extension subscribers receive message tool and agent_end payloads" {
    const allocator = std.testing.allocator;
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    var response_arena = std.heap.ArenaAllocator.init(allocator);
    defer response_arena.deinit();
    const response_allocator = response_arena.allocator();
    var args = try makeObject(response_allocator);
    try putString(response_allocator, &args.object, "value", "tool input");
    const tool_call_blocks = try response_allocator.alloc(faux.FauxContentBlock, 1);
    tool_call_blocks[0] = try faux.fauxToolCall(response_allocator, "lifecycle_tool", args, .{ .id = "lifecycle-call" });
    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("final assistant")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(tool_call_blocks, .{ .stop_reason = .tool_use }) },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    var order_log = std.ArrayList([]const u8).empty;
    defer order_log.deinit(allocator);
    var fixture = TestHookHost{
        .agent_end = true,
        .message_start = true,
        .message_update = true,
        .message_end = true,
        .tool_execution_start = true,
        .tool_execution_update = true,
        .tool_execution_end = true,
        .order_log = &order_log,
        .order_allocator = allocator,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    const tool = agent.AgentTool{
        .name = "lifecycle_tool",
        .description = "lifecycle tool fixture",
        .label = "Lifecycle Tool",
        .parameters = .null,
        .execute = lifecycleToolExecute,
        .execution_mode = .sequential,
    };
    var session = try AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/message-tool-lifecycle",
        .system_prompt = "system",
        .model = registration.getModel(),
        .tools = &[_]agent.AgentTool{tool},
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("hello lifecycle");

    try std.testing.expect(fixture.message_start_calls >= 4);
    try std.testing.expect(fixture.message_update_calls >= 1);
    try std.testing.expect(fixture.message_end_calls >= 4);
    try std.testing.expectEqual(@as(usize, 1), fixture.tool_execution_start_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.tool_execution_update_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.tool_execution_end_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.agent_end_calls);
    try std.testing.expect(fixture.saw_agent_end_messages);
    try std.testing.expect(fixture.saw_message_update_assistant_event);
    try std.testing.expect(fixture.saw_tool_result_message_start);
    try std.testing.expect(fixture.saw_tool_result_message_end);
    try std.testing.expect(fixture.saw_tool_execution_identity);
    try std.testing.expect(fixture.saw_tool_execution_partial_result);
    try std.testing.expect(fixture.saw_tool_execution_result);

    const tool_start_index = try firstEventIndex(order_log.items, "tool_execution_start");
    const tool_update_index = try firstEventIndex(order_log.items, "tool_execution_update");
    const tool_end_index = try firstEventIndex(order_log.items, "tool_execution_end");
    try std.testing.expect(tool_start_index < tool_update_index);
    try std.testing.expect(tool_update_index < tool_end_index);
}

test "extension message_end hook replaces final assistant content before persistence" {
    const allocator = std.testing.allocator;
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("raw assistant")}, .{}) },
    });

    var fixture = TestHookHost{
        .message_end = true,
        .message_end_replacement = "patched assistant",
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/message-end-replacement",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("hello replacement");

    const messages = session.agent.getMessages();
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("hello replacement", messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("patched assistant", messages[1].assistant.content[0].text.text);

    const entries = session.session_manager.getEntries();
    var persisted_replacement = false;
    for (entries) |entry| {
        if (entry != .message) continue;
        if (entry.message.message != .assistant) continue;
        if (std.mem.eql(u8, entry.message.message.assistant.content[0].text.text, "patched assistant")) {
            persisted_replacement = true;
        }
    }
    try std.testing.expect(persisted_replacement);
    try std.testing.expectEqual(@as(usize, 2), fixture.message_end_calls);
}

test "extension lifecycle hooks fire once per turn and message in agent order" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("lifecycle reply")}, .{}) },
    });

    var order_log = std.ArrayList([]const u8).empty;
    defer order_log.deinit(std.testing.allocator);
    var fixture = TestHookHost{
        .turn_start = true,
        .message_end = true,
        .turn_end = true,
        .order_log = &order_log,
        .order_allocator = std.testing.allocator,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/lifecycle-hooks",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("hello lifecycle");

    try std.testing.expectEqual(@as(usize, 1), fixture.turn_start_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.message_end_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.turn_end_calls);
    try std.testing.expect(order_log.items.len >= 4);
    try std.testing.expectEqualStrings("turn_start", order_log.items[0]);
    try std.testing.expectEqualStrings("message_end", order_log.items[1]);
    try std.testing.expectEqualStrings("message_end", order_log.items[2]);
    try std.testing.expectEqualStrings("turn_end", order_log.items[3]);
}

test "extension session and agent lifecycle hooks fire in canonical order" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("lifecycle reply")}, .{}) },
    });

    var order_log = std.ArrayList([]const u8).empty;
    defer order_log.deinit(std.testing.allocator);
    var fixture = TestHookHost{
        .session_start = true,
        .resources_discover = true,
        .agent_start = true,
        .turn_start = true,
        .turn_end = true,
        .agent_end = true,
        .session_shutdown = true,
        .order_log = &order_log,
        .order_allocator = std.testing.allocator,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/lifecycle-forwarding",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });

    try session.prompt("hello lifecycle forwarding");
    session.deinit();

    try std.testing.expectEqual(@as(usize, 1), fixture.session_start_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.resources_discover_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.agent_start_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.turn_start_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.turn_end_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.agent_end_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.session_shutdown_calls);

    const expected = [_][]const u8{
        "session_start",
        "resources_discover",
        "agent_start",
        "turn_start",
        "turn_end",
        "agent_end",
        "session_shutdown",
    };
    try std.testing.expectEqual(expected.len, order_log.items.len);
    for (expected, order_log.items) |expected_name, actual_name| {
        try std.testing.expectEqualStrings(expected_name, actual_name);
    }
}

test "native runtime adapter observes production session lifecycle event invocations" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("native lifecycle reply")}, .{}) },
    });

    const native_hooks = [_]extension_runtime.NativeHookDefinition{
        .{ .event_name = "session_start", .extension_path = "native://lifecycle/session-start" },
        .{ .event_name = "resources_discover", .extension_path = "native://lifecycle/resources" },
        .{ .event_name = "agent_start", .extension_path = "native://lifecycle/agent-start" },
        .{ .event_name = "turn_start", .extension_path = "native://lifecycle/turn-start" },
        .{ .event_name = "turn_end", .extension_path = "native://lifecycle/turn-end" },
        .{ .event_name = "agent_end", .extension_path = "native://lifecycle/agent-end" },
        .{ .event_name = "session_shutdown", .extension_path = "native://lifecycle/session-shutdown" },
    };
    const descriptor = extension_runtime.NativeDescriptor{
        .id = "com.pi.native-lifecycle-observer",
        .name = "Native Lifecycle Observer",
        .version = "0.1.0",
        .description = "Observes production session lifecycle events.",
        .hooks = &native_hooks,
    };
    var effects = native_runtime.NativeHostEffects{};
    const adapter = try extension_runtime.startRuntimeAdapter(std.testing.allocator, std.testing.io, .{ .native = .{
        .descriptor = &descriptor,
        .host_effects = &effects,
    } });
    defer adapter.deinit();
    try adapter.waitForReady(0);

    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/native-lifecycle-forwarding",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = &.{adapter},
    });
    try session.prompt("hello native lifecycle");
    session.deinit();

    try std.testing.expectEqual(@as(u64, native_hooks.len), effects.extension_event_invocations);
}

test "extension lifecycle hooks run deterministically by host order" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("ordered reply")}, .{}) },
    });

    var order_log = std.ArrayList([]const u8).empty;
    defer order_log.deinit(std.testing.allocator);
    var first = TestHookHost{
        .turn_start = true,
        .label = "first",
        .order_log = &order_log,
        .order_allocator = std.testing.allocator,
    };
    var second = TestHookHost{
        .turn_start = true,
        .label = "second",
        .order_log = &order_log,
        .order_allocator = std.testing.allocator,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{ first.adapter(), second.adapter() };
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/lifecycle-hook-order",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("hello ordering");

    try std.testing.expect(order_log.items.len >= 2);
    try std.testing.expectEqualStrings("first", order_log.items[0]);
    try std.testing.expectEqualStrings("second", order_log.items[1]);
    try std.testing.expectEqual(@as(usize, 1), first.turn_start_calls);
    try std.testing.expectEqual(@as(usize, 1), second.turn_start_calls);
}

test "extension lifecycle observer failures do not block later subscribers" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("isolated reply")}, .{}) },
    });

    var order_log = std.ArrayList([]const u8).empty;
    defer order_log.deinit(std.testing.allocator);
    var failing = TestHookHost{
        .agent_start = true,
        .label = "failing",
        .order_log = &order_log,
        .order_allocator = std.testing.allocator,
        .fail_event_name = "agent_start",
    };
    var later = TestHookHost{
        .agent_start = true,
        .label = "later",
        .order_log = &order_log,
        .order_allocator = std.testing.allocator,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{ failing.adapter(), later.adapter() };
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/lifecycle-failure-isolation",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("hello failure isolation");

    try std.testing.expectEqual(@as(usize, 0), failing.agent_start_calls);
    try std.testing.expectEqual(@as(usize, 1), later.agent_start_calls);
    try std.testing.expect(order_log.items.len >= 2);
    try std.testing.expectEqualStrings("failing", order_log.items[0]);
    try std.testing.expectEqualStrings("later", order_log.items[1]);
    const messages = session.agent.getMessages();
    try std.testing.expect(messages.len >= 3);
    const diagnostic = messages[messages.len - 1].assistant.error_message.?;
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "agent_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "TestHookHostInjectedFailure") != null);
}
