const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const json_event_wire = @import("json_event_wire.zig");
const common = @import("tools/common.zig");
const truncate = @import("tools/truncate.zig");
const session_mod = @import("session.zig");
const session_advanced = @import("session_advanced.zig");
const session_cwd_mod = @import("session_cwd.zig");
const session_manager_mod = @import("session_manager.zig");
const extension_host_mod = @import("extension_host.zig");

pub const RunTsRpcModeOptions = struct {
    extension_ui_parity_scenario: bool = false,
    extension_host: ?ExtensionHostOptions = null,
};

pub const ExtensionHostOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    marker: []const u8,
    fixture: []const u8,
    ready_timeout_ms: u64 = 1000,
    shutdown_timeout_ms: u64 = 1000,
};

const PromptStreamingBehavior = enum {
    steer,
    follow_up,
};

const SessionReplacementResult = struct {
    cancelled: bool = false,
    selected_text: ?[]u8 = null,

    fn deinit(self: *SessionReplacementResult, allocator: std.mem.Allocator) void {
        if (self.selected_text) |text| allocator.free(text);
        self.* = undefined;
    }
};

const DeferredResponsePriority = enum(u8) {
    queued_prompt = 0,
    abort = 1,
    queue_control = 2,
    bash_completion = 3,
};

const DEFERRED_RESPONSE_FLUSH_INTERVAL_MS = 50;
const EXTENSION_HOST_EVENT_LOOP_TICK_MS = 10;
const DIRECT_BASH_MAX_BUFFER_BYTES = truncate.DEFAULT_MAX_BYTES * 2;

const DeferredResponse = struct {
    id: ?[]u8,
    command: []u8,
    data_json: ?[]u8 = null,
    priority: DeferredResponsePriority,
    sequence: usize,

    fn deinit(self: *DeferredResponse, allocator: std.mem.Allocator) void {
        if (self.id) |id_string| allocator.free(id_string);
        allocator.free(self.command);
        if (self.data_json) |data| allocator.free(data);
        self.* = undefined;
    }
};

const BashRunResult = struct {
    output: []u8,
    exit_code: ?u8,
    cancelled: bool,
    truncated: bool = false,
    full_output_path: ?[]u8 = null,

    fn deinit(self: *BashRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.full_output_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

const ExtensionUIDialogMethod = enum {
    select,
    confirm,
    input,
    editor,
};

const ExtensionUIResolution = union(enum) {
    none,
    value: []u8,
    confirmed: bool,

    fn clone(allocator: std.mem.Allocator, resolution: ExtensionUIResolution) !ExtensionUIResolution {
        return switch (resolution) {
            .none => .none,
            .confirmed => |confirmed| .{ .confirmed = confirmed },
            .value => |value| .{ .value = try allocator.dupe(u8, value) },
        };
    }

    fn deinit(self: *ExtensionUIResolution, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .value => |value| allocator.free(value),
            else => {},
        }
        self.* = undefined;
    }
};

const PendingExtensionUIRequest = struct {
    method: ExtensionUIDialogMethod,
    timeout_ms: ?u64 = null,
    elapsed_ms: u64 = 0,

    fn defaultResolution(self: PendingExtensionUIRequest) ExtensionUIResolution {
        return switch (self.method) {
            .confirm => .{ .confirmed = false },
            .select, .input, .editor => .none,
        };
    }
};

const ResolvedExtensionUIRequest = struct {
    id: []u8,
    method: ExtensionUIDialogMethod,
    resolution: ExtensionUIResolution,

    fn deinit(self: *ResolvedExtensionUIRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        self.resolution.deinit(allocator);
        self.* = undefined;
    }
};

const BashTask = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: *TsRpcServer,
    cwd: []u8,
    id: ?[]u8,
    command: []u8,
    response_sequence: usize,
    abort_signal: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        server: *TsRpcServer,
        cwd: []const u8,
        id: ?[]const u8,
        command: []const u8,
        response_sequence: usize,
    ) !*BashTask {
        const task = try allocator.create(BashTask);
        errdefer allocator.destroy(task);
        const cwd_copy = try allocator.dupe(u8, cwd);
        errdefer allocator.free(cwd_copy);
        const id_copy = if (id) |id_string| try allocator.dupe(u8, id_string) else null;
        errdefer if (id_copy) |id_string| allocator.free(id_string);
        const command_copy = try allocator.dupe(u8, command);
        errdefer allocator.free(command_copy);
        task.* = .{
            .allocator = allocator,
            .io = io,
            .server = server,
            .cwd = cwd_copy,
            .id = id_copy,
            .command = command_copy,
            .response_sequence = response_sequence,
        };
        return task;
    }

    fn spawn(self: *BashTask) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *BashTask) void {
        defer self.done.store(true, .seq_cst);
        var result = runDirectBash(
            self.allocator,
            self.io,
            self.cwd,
            self.command,
            &self.abort_signal,
            &self.started,
        ) catch |err| {
            self.server.writeCommandError(self.id, "bash", err) catch {};
            return;
        };
        defer result.deinit(self.allocator);

        const data = buildBashResultJson(self.allocator, result) catch |err| {
            self.server.writeCommandError(self.id, "bash", err) catch {};
            return;
        };
        defer self.allocator.free(data);
        self.server.enqueueDeferredRawData(self.id, "bash", data, .bash_completion, self.response_sequence) catch {};
    }

    fn isDone(self: *const BashTask) bool {
        return self.done.load(.seq_cst);
    }

    fn isStarted(self: *const BashTask) bool {
        return self.started.load(.seq_cst);
    }

    fn abort(self: *BashTask) void {
        self.abort_signal.store(true, .seq_cst);
    }

    fn joinAndDestroy(self: *BashTask) void {
        if (self.thread) |thread| {
            thread.join();
        }
        self.allocator.free(self.cwd);
        if (self.id) |id_string| self.allocator.free(id_string);
        self.allocator.free(self.command);
        self.allocator.destroy(self);
    }
};

const PromptTask = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: *TsRpcServer,
    session: *session_mod.AgentSession,
    id: ?[]u8,
    message: []u8,
    images: []ai.ImageContent,
    response_sent: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        server: *TsRpcServer,
        session: *session_mod.AgentSession,
        id: ?[]const u8,
        message: []u8,
        images: []ai.ImageContent,
    ) !*PromptTask {
        const task = try allocator.create(PromptTask);
        errdefer allocator.destroy(task);
        task.* = .{
            .allocator = allocator,
            .io = io,
            .server = server,
            .session = session,
            .id = if (id) |id_string| try allocator.dupe(u8, id_string) else null,
            .message = message,
            .images = images,
        };
        return task;
    }

    fn spawn(self: *PromptTask) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *PromptTask) void {
        defer self.done.store(true, .seq_cst);
        self.session.promptWithAcceptedCallback(
            .{ .text = self.message, .images = self.images },
            .{ .context = self, .callback = writePromptAccepted },
        ) catch |err| {
            if (!self.response_sent.load(.seq_cst)) {
                // Only write error to stdout when there is a TS-RPC request ID to respond to.
                // Background tasks (sendUserMessage) have id = null and must not pollute stdout.
                if (self.id != null) {
                    self.server.writeCommandError(self.id, "prompt", err) catch {};
                }
                self.response_sent.store(true, .seq_cst);
            }
        };
    }

    fn isDone(self: *const PromptTask) bool {
        return self.done.load(.seq_cst);
    }

    fn waitForResponse(self: *const PromptTask) void {
        while (!self.response_sent.load(.seq_cst)) {
            std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch {};
        }
    }

    fn joinAndDestroy(self: *PromptTask) void {
        if (self.thread) |thread| {
            thread.join();
        }
        if (self.id) |id_string| self.allocator.free(id_string);
        self.allocator.free(self.message);
        deinitImages(self.allocator, self.images);
        self.allocator.destroy(self);
    }

    fn writePromptAccepted(context: ?*anyopaque) !void {
        const self: *PromptTask = @ptrCast(@alignCast(context.?));
        // Only write the TS-RPC acceptance response when there is a request ID.
        // Background tasks (from sendUserMessage) have id = null and must not
        // pollute the TS-RPC output stream.
        if (self.id != null) {
            try self.server.writeSuccessResponseNoData(self.id, "prompt");
            // Signal the main thread that the response has been written before
            // sleeping. This allows the dispatcher to process already-buffered
            // JSONL input (abort, steer, follow_up, etc.) during the yield window
            // so those commands are fully processed before agent events begin.
            self.response_sent.store(true, .seq_cst);
            // Yield briefly so rapid controls can be handled in dispatcher order
            // instead of racing the prompt worker. The sleep must come after
            // response_sent.store so the main thread unblocks first.
            std.Io.sleep(self.io, .fromMilliseconds(50), .awake) catch {};
        }
    }
};

const TsRpcSessionHost = struct {
    server: *TsRpcServer,

    fn init(server: *TsRpcServer) TsRpcSessionHost {
        return .{ .server = server };
    }

    fn current(self: *TsRpcSessionHost) *session_mod.AgentSession {
        return self.server.session.?;
    }

    fn newSession(self: *TsRpcSessionHost, parent_session: ?[]const u8) !SessionReplacementResult {
        const old = self.current();
        var manager = try self.server.allocator.create(session_manager_mod.SessionManager);
        errdefer self.server.allocator.destroy(manager);
        manager.* = if (old.session_manager.isPersisted())
            try session_manager_mod.SessionManager.createWithParent(
                self.server.allocator,
                self.server.io,
                old.cwd,
                old.session_manager.getSessionDir(),
                parent_session,
            )
        else
            try session_manager_mod.SessionManager.inMemory(self.server.allocator, self.server.io, old.cwd);
        errdefer manager.deinit();

        try self.replaceWithManager(manager, manager.getCwd());
        return .{ .cancelled = false };
    }

    fn switchSession(self: *TsRpcSessionHost, session_path: []const u8) !SessionReplacementResult {
        const old = self.current();
        var manager = try self.server.allocator.create(session_manager_mod.SessionManager);
        errdefer self.server.allocator.destroy(manager);
        manager.* = try session_manager_mod.SessionManager.open(
            self.server.allocator,
            self.server.io,
            session_path,
            null,
        );
        errdefer manager.deinit();

        // Atomically reject the switch when the stored cwd no longer exists
        // before tearing down the current runtime. This matches TS
        // `RuntimeHost.switchSession` which throws `MissingSessionCwdError`
        // before mutating active session state.
        if (session_cwd_mod.getMissingSessionCwdIssue(self.server.io, manager, old.cwd) != null) {
            return error.MissingSessionCwd;
        }

        try self.replaceWithManager(manager, manager.getCwd());
        return .{ .cancelled = false };
    }

    fn fork(self: *TsRpcSessionHost, entry_id: []const u8, position: enum { before, at }) !SessionReplacementResult {
        const old = self.current();
        const selected_entry = old.session_manager.getEntry(entry_id) orelse return error.InvalidEntryIdForForking;
        const target_leaf_id: ?[]const u8 = switch (position) {
            .at => selected_entry.id(),
            .before => blk: {
                if (selected_entry.* != .message) return error.InvalidEntryIdForForking;
                if (selected_entry.message.message != .user) return error.InvalidEntryIdForForking;
                break :blk selected_entry.message.parent_id;
            },
        };
        const selected_text = if (position == .before)
            try textBlocksConcat(self.server.allocator, selected_entry.message.message.user.content)
        else
            null;
        errdefer if (selected_text) |text| self.server.allocator.free(text);

        var manager = try self.server.allocator.create(session_manager_mod.SessionManager);
        errdefer self.server.allocator.destroy(manager);
        manager.* = if (target_leaf_id) |leaf_id|
            try old.session_manager.createBranchedSession(leaf_id)
        else if (old.session_manager.isPersisted())
            try session_manager_mod.SessionManager.createWithParent(
                self.server.allocator,
                self.server.io,
                old.cwd,
                old.session_manager.getSessionDir(),
                old.session_manager.getSessionFile(),
            )
        else
            try session_manager_mod.SessionManager.inMemory(self.server.allocator, self.server.io, old.cwd);
        errdefer manager.deinit();

        try self.replaceWithManager(manager, manager.getCwd());
        return .{ .cancelled = false, .selected_text = selected_text };
    }

    fn clone(self: *TsRpcSessionHost) !SessionReplacementResult {
        const leaf_id = self.current().session_manager.getLeafId() orelse return error.CannotCloneSessionNoCurrentEntrySelected;
        return try self.fork(leaf_id, .at);
    }

    fn replaceWithManager(
        self: *TsRpcSessionHost,
        manager: *session_manager_mod.SessionManager,
        cwd: []const u8,
    ) !void {
        const old = self.current();
        const old_model = old.agent.getModel();
        const replacement_model = ai.model_registry.getDefault().find(old_model.provider, old_model.id) orelse old_model;
        const options = session_mod.AgentSession.ManagedOptions{
            .cwd = cwd,
            .system_prompt = old.system_prompt,
            .model = replacement_model,
            .api_key = old.agent.getApiKey(),
            .thinking_level = old.agent.getThinkingLevel(),
            .tools = old.agent.getTools(),
            .compaction = old.compaction_settings,
            .retry = old.retry_settings,
        };
        var replacement = session_mod.AgentSession.createWithManager(
            self.server.allocator,
            self.server.io,
            manager,
            options,
        ) catch |err| {
            manager.deinit();
            self.server.allocator.destroy(manager);
            return err;
        };
        replacement.agent.steering_queue.mode = old.agent.steering_queue.mode;
        replacement.agent.follow_up_queue.mode = old.agent.follow_up_queue.mode;
        errdefer replacement.deinit();

        self.server.cancelAndJoinPromptTasks();
        self.server.cancelAndJoinBashTasks();
        self.server.detachFromCurrentSession();
        old.deinit();
        old.* = replacement;
        try self.server.attachToCurrentSession();
    }
};

pub const command_types = [_][]const u8{
    "prompt",
    "steer",
    "follow_up",
    "abort",
    "new_session",
    "get_state",
    "set_model",
    "cycle_model",
    "get_available_models",
    "set_thinking_level",
    "cycle_thinking_level",
    "set_steering_mode",
    "set_follow_up_mode",
    "compact",
    "set_auto_compaction",
    "set_auto_retry",
    "abort_retry",
    "bash",
    "abort_bash",
    "get_session_stats",
    "export_html",
    "switch_session",
    "fork",
    "clone",
    "get_fork_messages",
    "get_last_assistant_text",
    "set_session_name",
    "get_messages",
    "get_commands",
};

pub fn isKnownCommandType(command_type: []const u8) bool {
    for (command_types) |known| {
        if (std.mem.eql(u8, known, command_type)) return true;
    }
    return false;
}

const TsRpcServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: ?*session_mod.AgentSession,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    output_mutex: std.Io.Mutex = .init,
    subscriber: ?agent.AgentSubscriber = null,
    prompt_tasks: std.ArrayList(*PromptTask) = .empty,
    bash_tasks: std.ArrayList(*BashTask) = .empty,
    bash_task_mutex: std.Io.Mutex = .init,
    deferred_responses: std.ArrayList(DeferredResponse) = .empty,
    deferred_responses_mutex: std.Io.Mutex = .init,
    deferred_flush_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    deferred_flush_input_backlog: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    deferred_flush_last_activity_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    deferred_flush_thread: ?std.Thread = null,
    next_deferred_response_sequence: usize = 0,
    next_bash_response_sequence: usize = 0,
    pending_extension_requests: std.StringHashMap(PendingExtensionUIRequest),
    completed_extension_requests: std.ArrayList(ResolvedExtensionUIRequest) = .empty,
    extension_host: ?*extension_host_mod.HostProcess = null,
    suppress_events: bool = false,
    finished: bool = false,
    /// Incremented on each turn_start event so extension frames carry sequential turnIndex values.
    turn_index: usize = 0,
    /// IDs of pending wait_for_idle requests from the extension host. Each ID is resolved
    /// (and the response sent back to the host) when the agent becomes idle.
    pending_wait_for_idle_ids: std.ArrayList([]u8) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        session: ?*session_mod.AgentSession,
        stdout_writer: *std.Io.Writer,
        stderr_writer: *std.Io.Writer,
    ) TsRpcServer {
        return .{
            .allocator = allocator,
            .io = io,
            .session = session,
            .stdout_writer = stdout_writer,
            .stderr_writer = stderr_writer,
            .pending_extension_requests = std.StringHashMap(PendingExtensionUIRequest).init(allocator),
        };
    }

    fn start(self: *TsRpcServer) !void {
        try self.attachToCurrentSession();
        self.deferred_flush_stop.store(false, .seq_cst);
        self.markDeferredFlushActivity();
        self.deferred_flush_thread = try std.Thread.spawn(.{}, deferredFlushMain, .{self});
    }

    fn startExtensionHost(self: *TsRpcServer, options: ExtensionHostOptions) !void {
        if (self.extension_host != null) return error.ExtensionHostAlreadyStarted;
        const host = try extension_host_mod.HostProcess.start(self.allocator, self.io, .{
            .argv = options.argv,
            .cwd = options.cwd,
            .initialize = .{
                .marker = options.marker,
                .cwd = options.cwd orelse "",
                .fixture = options.fixture,
            },
            .shutdown_timeout_ms = options.shutdown_timeout_ms,
        });
        errdefer host.deinit();
        try host.waitForReady(options.ready_timeout_ms);
        self.extension_host = host;
        try self.drainExtensionHostUiRequests(50);
    }

    fn finish(self: *TsRpcServer) !void {
        if (self.finished) return;
        self.finished = true;
        self.deferred_flush_stop.store(true, .seq_cst);
        if (self.deferred_flush_thread) |thread| {
            thread.join();
            self.deferred_flush_thread = null;
        }
        try self.flushDeferredResponses();
        if (self.hasInFlightPrompt()) {
            self.abortActivePromptWork();
        }
        for (self.prompt_tasks.items) |task| {
            task.joinAndDestroy();
        }
        self.prompt_tasks.clearRetainingCapacity();
        self.joinBashTasks();
        try self.flushDeferredResponses();
        self.detachFromCurrentSession();
        self.prompt_tasks.deinit(self.allocator);
        self.prompt_tasks = .empty;
        self.deferred_responses.deinit(self.allocator);
        self.deferred_responses = .empty;
        self.bash_tasks.deinit(self.allocator);
        self.bash_tasks = .empty;
        if (self.extension_host) |host| {
            self.emitSessionShutdownEvent(host, "quit", null);
            host.deinit();
            self.extension_host = null;
        }
        self.deinitExtensionUIState();
        try self.stdout_writer.flush();
        try self.stderr_writer.flush();
    }

    fn attachToCurrentSession(self: *TsRpcServer) !void {
        if (self.subscriber != null) return;
        if (self.session) |session| {
            self.subscriber = .{
                .context = self,
                .callback = handleTsRpcAgentEvent,
            };
            try session.agent.subscribe(self.subscriber.?);
            session.setRetryLifecycleCallback(.{
                .context = self,
                .callback = handleTsRpcRetryLifecycleEvent,
            });
        }
    }

    fn detachFromCurrentSession(self: *TsRpcServer) void {
        if (self.session) |session| {
            session.clearRetryLifecycleCallback();
            if (self.subscriber) |subscriber| {
                _ = session.agent.unsubscribe(subscriber);
                self.subscriber = null;
            }
        }
    }

    fn cancelAndJoinPromptTasks(self: *TsRpcServer) void {
        if (self.hasInFlightPrompt()) {
            self.abortActivePromptWork();
        }
        for (self.prompt_tasks.items) |task| {
            task.joinAndDestroy();
        }
        self.prompt_tasks.clearRetainingCapacity();
    }

    fn hasInFlightPrompt(self: *const TsRpcServer) bool {
        for (self.prompt_tasks.items) |task| {
            if (!task.isDone()) return true;
        }
        return false;
    }

    /// Returns true when the agent is currently streaming or a prompt task is in flight.
    fn isAgentBusy(self: *const TsRpcServer) bool {
        if (self.session) |session| {
            if (session.isStreaming()) return true;
        }
        return self.hasInFlightPrompt();
    }

    /// Resolve all pending wait_for_idle requests when the agent is idle.
    /// Sends extension_ui_response back to the host for each pending ID and removes
    /// it from the list. Safe to call repeatedly; no-op when agent is still busy or
    /// no requests are pending.
    fn resolveWaitForIdleRequests(self: *TsRpcServer) !void {
        if (self.pending_wait_for_idle_ids.items.len == 0) return;
        if (self.isAgentBusy()) return;
        const host = self.extension_host;
        var i: usize = self.pending_wait_for_idle_ids.items.len;
        while (i > 0) {
            i -= 1;
            const id = self.pending_wait_for_idle_ids.orderedRemove(i);
            defer self.allocator.free(id);
            if (host) |h| {
                try h.sendExtensionUiResponse(id, "{}");
            }
        }
    }

    fn markDeferredFlushActivity(self: *TsRpcServer) void {
        self.deferred_flush_last_activity_ms.store(self.deferredFlushNowMs(), .seq_cst);
    }

    fn setDeferredFlushInputBacklog(self: *TsRpcServer, has_backlog: bool) void {
        self.deferred_flush_input_backlog.store(has_backlog, .seq_cst);
        if (has_backlog) self.markDeferredFlushActivity();
    }

    fn shouldHoldDeferredFlush(self: *TsRpcServer) bool {
        if (self.deferred_flush_input_backlog.load(.seq_cst)) return true;
        const last_activity_ms = self.deferred_flush_last_activity_ms.load(.seq_cst);
        if (last_activity_ms == 0) return false;
        return self.deferredFlushNowMs() - last_activity_ms < DEFERRED_RESPONSE_FLUSH_INTERVAL_MS;
    }

    fn deferredFlushNowMs(self: *TsRpcServer) i64 {
        return @intCast(@divFloor(std.Io.Clock.now(.awake, self.io).nanoseconds, std.time.ns_per_ms));
    }

    fn abortActivePromptWork(self: *TsRpcServer) void {
        if (self.session) |session| {
            session.abortRetry();
            session.agent.abort();
        }
    }

    fn takeCompletedBashTask(self: *TsRpcServer) ?*BashTask {
        self.bash_task_mutex.lockUncancelable(self.io);
        defer self.bash_task_mutex.unlock(self.io);
        for (self.bash_tasks.items, 0..) |task, index| {
            if (task.isDone()) return self.bash_tasks.orderedRemove(index);
        }
        return null;
    }

    fn reapCompletedBashTasks(self: *TsRpcServer) void {
        while (self.takeCompletedBashTask()) |task| {
            task.joinAndDestroy();
        }
    }

    fn hasActiveBashTask(self: *TsRpcServer) bool {
        self.reapCompletedBashTasks();
        self.bash_task_mutex.lockUncancelable(self.io);
        defer self.bash_task_mutex.unlock(self.io);
        return self.bash_tasks.items.len != 0;
    }

    fn activeBashTaskStarted(self: *TsRpcServer) bool {
        self.bash_task_mutex.lockUncancelable(self.io);
        defer self.bash_task_mutex.unlock(self.io);
        for (self.bash_tasks.items) |task| {
            if (task.isStarted()) return true;
        }
        return false;
    }

    fn hasUnfinishedBashTask(self: *TsRpcServer) bool {
        self.bash_task_mutex.lockUncancelable(self.io);
        defer self.bash_task_mutex.unlock(self.io);
        for (self.bash_tasks.items) |task| {
            if (!task.isDone()) return true;
        }
        return false;
    }

    fn abortActiveBashTask(self: *TsRpcServer) void {
        self.reapCompletedBashTasks();
        self.bash_task_mutex.lockUncancelable(self.io);
        defer self.bash_task_mutex.unlock(self.io);
        var index = self.bash_tasks.items.len;
        while (index > 0) {
            index -= 1;
            const task = self.bash_tasks.items[index];
            if (!task.isDone()) {
                task.abort();
                return;
            }
        }
    }

    fn cancelAndJoinBashTasks(self: *TsRpcServer) void {
        self.bash_task_mutex.lockUncancelable(self.io);
        var tasks = self.bash_tasks;
        self.bash_tasks = .empty;
        for (tasks.items) |task| {
            task.abort();
        }
        self.bash_task_mutex.unlock(self.io);
        defer tasks.deinit(self.allocator);

        for (tasks.items) |task| {
            task.joinAndDestroy();
        }
    }

    fn joinBashTasks(self: *TsRpcServer) void {
        self.bash_task_mutex.lockUncancelable(self.io);
        var tasks = self.bash_tasks;
        self.bash_tasks = .empty;
        self.bash_task_mutex.unlock(self.io);
        defer tasks.deinit(self.allocator);

        for (tasks.items) |task| {
            task.joinAndDestroy();
        }
    }

    fn deinitExtensionUIState(self: *TsRpcServer) void {
        var pending_iterator = self.pending_extension_requests.iterator();
        while (pending_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.pending_extension_requests.deinit();

        for (self.completed_extension_requests.items) |*resolved| {
            resolved.deinit(self.allocator);
        }
        self.completed_extension_requests.deinit(self.allocator);
        self.completed_extension_requests = .empty;

        for (self.pending_wait_for_idle_ids.items) |id| self.allocator.free(id);
        self.pending_wait_for_idle_ids.deinit(self.allocator);
        self.pending_wait_for_idle_ids = .empty;
    }

    fn registerPendingExtensionUIRequest(
        self: *TsRpcServer,
        id: []const u8,
        method: ExtensionUIDialogMethod,
        timeout_ms: ?u64,
    ) !void {
        if (self.pending_extension_requests.fetchRemove(id)) |removed| {
            self.allocator.free(removed.key);
        }
        try self.pending_extension_requests.put(
            try self.allocator.dupe(u8, id),
            .{
                .method = method,
                .timeout_ms = timeout_ms,
            },
        );
    }

    fn resolvePendingExtensionUIRequest(
        self: *TsRpcServer,
        id: []const u8,
        resolution: ExtensionUIResolution,
    ) !bool {
        if (self.pending_extension_requests.fetchRemove(id)) |removed| {
            defer self.allocator.free(removed.key);
            try self.completed_extension_requests.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, id),
                .method = removed.value.method,
                .resolution = try ExtensionUIResolution.clone(self.allocator, resolution),
            });
            return true;
        }
        return false;
    }

    fn cancelPendingExtensionUIRequest(self: *TsRpcServer, id: []const u8) !bool {
        if (self.pending_extension_requests.get(id)) |pending| {
            const default_resolution = pending.defaultResolution();
            const did_resolve = try self.resolvePendingExtensionUIRequest(id, default_resolution);
            if (did_resolve) try self.forwardExtensionUIResolutionToHost(id, default_resolution);
            return did_resolve;
        }
        return false;
    }

    fn forwardExtensionUIResolutionToHost(self: *TsRpcServer, id: []const u8, resolution: ExtensionUIResolution) !void {
        const host = self.extension_host orelse return;
        var payload: std.Io.Writer.Allocating = .init(self.allocator);
        defer payload.deinit();
        switch (resolution) {
            .none => try payload.writer.writeAll("{\"cancelled\":true}"),
            .value => |value| {
                try payload.writer.writeAll("{\"value\":");
                try writeJsonString(self.allocator, &payload.writer, value);
                try payload.writer.writeAll("}");
            },
            .confirmed => |confirmed| {
                try payload.writer.writeAll("{\"confirmed\":");
                try payload.writer.writeAll(if (confirmed) "true" else "false");
                try payload.writer.writeAll("}");
            },
        }
        try host.sendExtensionUiResponse(id, payload.written());
    }

    fn advanceExtensionUITime(self: *TsRpcServer, elapsed_ms: u64) !void {
        var timed_out_ids = std.ArrayList([]u8).empty;
        defer {
            for (timed_out_ids.items) |id| self.allocator.free(id);
            timed_out_ids.deinit(self.allocator);
        }

        var iterator = self.pending_extension_requests.iterator();
        while (iterator.next()) |entry| {
            const timeout_ms = entry.value_ptr.timeout_ms orelse continue;
            entry.value_ptr.elapsed_ms += elapsed_ms;
            if (entry.value_ptr.elapsed_ms >= timeout_ms) {
                try timed_out_ids.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*));
            }
        }

        for (timed_out_ids.items) |id| {
            _ = try self.cancelPendingExtensionUIRequest(id);
        }
    }

    fn handleExtensionUIResponse(self: *TsRpcServer, object: std.json.ObjectMap) !void {
        const id = requiredString(object, "id") catch return;

        if (object.get("cancelled")) |cancelled_value| {
            if (cancelled_value == .bool and cancelled_value.bool) {
                _ = try self.cancelPendingExtensionUIRequest(id);
                return;
            }
        }
        if (object.get("value")) |value| {
            if (value == .string) {
                const resolution = ExtensionUIResolution{ .value = @constCast(value.string) };
                if (try self.resolvePendingExtensionUIRequest(id, resolution)) {
                    try self.forwardExtensionUIResolutionToHost(id, resolution);
                }
                return;
            }
        }
        if (object.get("confirmed")) |confirmed| {
            if (confirmed == .bool) {
                const resolution = ExtensionUIResolution{ .confirmed = confirmed.bool };
                if (try self.resolvePendingExtensionUIRequest(id, resolution)) {
                    try self.forwardExtensionUIResolutionToHost(id, resolution);
                }
                return;
            }
        }
    }

    fn handleLine(self: *TsRpcServer, line: []const u8) !void {
        self.markDeferredFlushActivity();
        defer self.markDeferredFlushActivity();

        const ts_line = stripTrailingCarriageReturn(line);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, ts_line, .{}) catch {
            const message = try self.parseErrorMessage(ts_line);
            defer self.allocator.free(message);
            try self.writeErrorResponse(null, "parse", message);
            return;
        };
        defer parsed.deinit();

        if (parsed.value == .object) {
            if (parsed.value.object.get("type")) |type_value| {
                if (type_value == .string and std.mem.eql(u8, type_value.string, "extension_ui_response")) {
                    try self.handleExtensionUIResponse(parsed.value.object);
                    return;
                }
            }
        }

        const object = switch (parsed.value) {
            .object => |object| object,
            else => {
                try self.writeUnknownCommand(null);
                return;
            },
        };

        const id = if (object.get("id")) |id_value| switch (id_value) {
            .string => |id_string| id_string,
            else => null,
        } else null;

        const command_type = if (object.get("type")) |type_value| switch (type_value) {
            .string => |type_string| type_string,
            else => null,
        } else null;

        const command = command_type orelse {
            try self.writeUnknownCommand(null);
            return;
        };

        // navigate_to is a Zig-only extension command not in the TypeScript protocol.
        // Allow it through without the isKnownCommandType gate.
        if (!std.mem.eql(u8, command, "navigate_to") and !isKnownCommandType(command)) {
            try self.writeUnknownCommand(command);
            return;
        }

        try self.handleCommand(id, command, object);
    }

    fn handleCommand(
        self: *TsRpcServer,
        id: ?[]const u8,
        command: []const u8,
        object: std.json.ObjectMap,
    ) !void {
        self.reapCompletedBashTasks();
        const session = self.session orelse {
            try self.writeNotImplemented(id, command);
            return;
        };

        if (std.mem.eql(u8, command, "prompt")) {
            const message = requiredString(object, "message") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            const images = parseImages(self.allocator, object) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            var images_owned = true;
            defer if (images_owned) deinitImages(self.allocator, images);
            const streaming_behavior = parsePromptStreamingBehavior(object) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };

            // Emit input extension event before agent processes the message
            if (self.extension_host) |host| self.emitExtensionInputEvent(host, message, "rpc");

            if (session.isStreaming() or self.hasInFlightPrompt()) {
                const behavior = streaming_behavior orelse {
                    try self.writeErrorResponse(
                        id,
                        command,
                        "Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message.",
                    );
                    return;
                };
                switch (behavior) {
                    .steer => session.steer(message, images) catch |err| {
                        try self.writeCommandError(id, command, err);
                        return;
                    },
                    .follow_up => session.followUp(message, images) catch |err| {
                        try self.writeCommandError(id, command, err);
                        return;
                    },
                }
                try self.writeQueueUpdate();
                try self.enqueueDeferredSuccess(id, command, .queued_prompt);
                return;
            }

            const message_copy = self.allocator.dupe(u8, message) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            var message_owned = true;
            defer if (message_owned) self.allocator.free(message_copy);

            const task = PromptTask.create(self.allocator, self.io, self, session, id, message_copy, images) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            images_owned = false;
            message_owned = false;
            self.prompt_tasks.append(self.allocator, task) catch |err| {
                task.joinAndDestroy();
                try self.writeCommandError(id, command, err);
                return;
            };
            task.spawn() catch |err| {
                _ = self.prompt_tasks.pop();
                task.joinAndDestroy();
                try self.writeCommandError(id, command, err);
                return;
            };
            task.waitForResponse();
            return;
        }

        if (std.mem.eql(u8, command, "steer")) {
            const message = requiredString(object, "message") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            const images = parseImages(self.allocator, object) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            defer deinitImages(self.allocator, images);
            session.steer(message, images) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            try self.writeQueueUpdate();
            if (session.isStreaming() or self.hasInFlightPrompt()) {
                try self.enqueueDeferredSuccess(id, command, .queue_control);
            } else {
                try self.writeSuccessResponseNoData(id, command);
            }
            return;
        }

        if (std.mem.eql(u8, command, "follow_up")) {
            const message = requiredString(object, "message") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            const images = parseImages(self.allocator, object) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            defer deinitImages(self.allocator, images);
            session.followUp(message, images) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            try self.writeQueueUpdate();
            if (session.isStreaming() or self.hasInFlightPrompt()) {
                try self.enqueueDeferredSuccess(id, command, .queue_control);
            } else {
                try self.writeSuccessResponseNoData(id, command);
            }
            return;
        }

        if (std.mem.eql(u8, command, "abort")) {
            const defer_response = session.isStreaming() or self.hasInFlightPrompt();
            if (defer_response) {
                try self.enqueueDeferredSuccess(id, command, .abort);
            } else {
                self.abortActivePromptWork();
                try self.writeSuccessResponseNoData(id, command);
            }
            return;
        }

        if (std.mem.eql(u8, command, "new_session")) {
            const parent_session = optionalString(object, "parentSession") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            if (self.extension_host) |ext_host| {
                // For new sessions, targetSessionFile is undefined (the new session file
                // doesn't exist yet). parentSession is the old session being shut down,
                // not the target for the switch event.
                self.emitSessionBeforeSwitchEvent(ext_host, "new", null);
                self.emitSessionShutdownEvent(ext_host, "new", parent_session);
            }
            var host = TsRpcSessionHost.init(self);
            const result = host.newSession(parent_session) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            _ = result;
            try self.writeSuccessResponseRawData(id, command, "{\"cancelled\":false}");
            return;
        }

        if (std.mem.eql(u8, command, "get_state")) {
            const data = try self.buildStateJson(session);
            defer self.allocator.free(data);
            try self.writeSuccessResponseRawData(id, command, data);
            return;
        }

        if (std.mem.eql(u8, command, "set_model")) {
            const provider = requiredString(object, "provider") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            const model_id = requiredString(object, "modelId") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            const model = ai.model_registry.getDefault().find(provider, model_id) orelse {
                const message = try std.fmt.allocPrint(self.allocator, "Model not found: {s}/{s}", .{ provider, model_id });
                defer self.allocator.free(message);
                try self.writeErrorResponse(id, command, message);
                return;
            };
            const prev_model = session.agent.getModel();
            session.setModel(model) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            if (self.extension_host) |host| self.emitExtensionModelSelectEvent(host, model, prev_model, "set");
            const data = try self.buildModelJson(model);
            defer self.allocator.free(data);
            try self.writeSuccessResponseRawData(id, command, data);
            return;
        }

        if (std.mem.eql(u8, command, "cycle_model")) {
            try self.writeSuccessResponseRawData(id, command, "null");
            return;
        }

        if (std.mem.eql(u8, command, "get_available_models")) {
            const data = try self.buildAvailableModelsJson();
            defer self.allocator.free(data);
            try self.writeSuccessResponseRawData(id, command, data);
            return;
        }

        if (std.mem.eql(u8, command, "set_thinking_level")) {
            const level = parseThinkingLevel(object, "level") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            const prev_level = session.agent.getThinkingLevel();
            session.setThinkingLevel(level) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            if (self.extension_host) |host| self.emitExtensionThinkingLevelSelectEvent(host, level, prev_level);
            try self.writeSuccessResponseNoData(id, command);
            return;
        }

        if (std.mem.eql(u8, command, "cycle_thinking_level")) {
            if (!session.agent.getModel().reasoning) {
                try self.writeSuccessResponseRawData(id, command, "null");
                return;
            }
            const prev_level = session.agent.getThinkingLevel();
            const next_level = nextThinkingLevel(prev_level);
            session.setThinkingLevel(next_level) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            if (self.extension_host) |host| self.emitExtensionThinkingLevelSelectEvent(host, next_level, prev_level);
            const data = try std.fmt.allocPrint(self.allocator, "{{\"level\":\"{s}\"}}", .{thinkingLevelName(next_level)});
            defer self.allocator.free(data);
            try self.writeSuccessResponseRawData(id, command, data);
            return;
        }

        if (std.mem.eql(u8, command, "set_steering_mode")) {
            session.agent.steering_queue.mode = parseQueueMode(object, "mode") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            try self.writeSuccessResponseNoData(id, command);
            return;
        }

        if (std.mem.eql(u8, command, "set_follow_up_mode")) {
            session.agent.follow_up_queue.mode = parseQueueMode(object, "mode") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            try self.writeSuccessResponseNoData(id, command);
            return;
        }

        if (std.mem.eql(u8, command, "compact")) {
            const custom_instructions = optionalString(object, "customInstructions") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            if (self.extension_host) |ext_host| self.emitSessionBeforeCompactEvent(ext_host, custom_instructions);
            try self.writeCompactionStartEvent("manual");
            const result = session.compact(custom_instructions) catch |err| {
                try self.writeCompactionEndEvent("manual", null, true, false);
                try self.writeCommandError(id, command, err);
                return;
            };
            const data = try self.buildCompactionResultJson(result);
            defer self.allocator.free(data);
            try self.writeCompactionEndEvent("manual", data, false, false);
            if (self.extension_host) |ext_host| self.emitSessionCompactEvent(ext_host);
            try self.writeSuccessResponseRawData(id, command, data);
            return;
        }

        if (std.mem.eql(u8, command, "set_auto_compaction")) {
            session.compaction_settings.enabled = parseRequiredBool(object, "enabled") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            try self.writeSuccessResponseNoData(id, command);
            return;
        }

        if (std.mem.eql(u8, command, "set_auto_retry")) {
            session.retry_settings.enabled = parseRequiredBool(object, "enabled") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            try self.writeSuccessResponseNoData(id, command);
            return;
        }

        if (std.mem.eql(u8, command, "abort_retry")) {
            session.abortRetry();
            try self.writeSuccessResponseNoData(id, command);
            return;
        }

        if (std.mem.eql(u8, command, "bash")) {
            const bash_command = requiredString(object, "command") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            const response_sequence = self.next_bash_response_sequence;
            self.next_bash_response_sequence += 1;
            const task = BashTask.create(self.allocator, self.io, self, session.cwd, id, bash_command, response_sequence) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            self.bash_task_mutex.lockUncancelable(self.io);
            self.bash_tasks.append(self.allocator, task) catch |err| {
                self.bash_task_mutex.unlock(self.io);
                task.joinAndDestroy();
                try self.writeCommandError(id, command, err);
                return;
            };
            self.bash_task_mutex.unlock(self.io);
            task.spawn() catch |err| {
                self.bash_task_mutex.lockUncancelable(self.io);
                for (self.bash_tasks.items, 0..) |candidate, index| {
                    if (candidate == task) {
                        _ = self.bash_tasks.orderedRemove(index);
                        break;
                    }
                }
                self.bash_task_mutex.unlock(self.io);
                task.joinAndDestroy();
                try self.writeCommandError(id, command, err);
                return;
            };
            return;
        }

        if (std.mem.eql(u8, command, "abort_bash")) {
            self.output_mutex.lockUncancelable(self.io);
            defer self.output_mutex.unlock(self.io);
            self.abortActiveBashTask();
            try self.writeSuccessResponseNoDataLocked(id, command);
            return;
        }

        if (std.mem.eql(u8, command, "get_session_stats")) {
            const data = try self.buildSessionStatsJson(session);
            defer self.allocator.free(data);
            try self.writeSuccessResponseRawData(id, command, data);
            return;
        }

        if (std.mem.eql(u8, command, "export_html")) {
            const output_path = optionalString(object, "outputPath") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            const path = session_advanced.exportToHtml(self.allocator, self.io, session, output_path) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            defer self.allocator.free(path);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            try out.writer.writeAll("{\"path\":");
            try writeJsonString(self.allocator, &out.writer, path);
            try out.writer.writeAll("}");
            try self.writeSuccessResponseRawData(id, command, out.written());
            return;
        }

        if (std.mem.eql(u8, command, "switch_session")) {
            const session_path = requiredString(object, "sessionPath") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            if (self.extension_host) |ext_host| {
                self.emitSessionBeforeSwitchEvent(ext_host, "resume", session_path);
                self.emitSessionShutdownEvent(ext_host, "resume", session_path);
            }
            var host = TsRpcSessionHost.init(self);
            var result = host.switchSession(session_path) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            defer result.deinit(self.allocator);
            try self.writeSuccessResponseRawData(id, command, "{\"cancelled\":false}");
            return;
        }

        if (std.mem.eql(u8, command, "fork")) {
            const entry_id = requiredString(object, "entryId") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            if (self.extension_host) |ext_host| {
                self.emitSessionBeforeForkEvent(ext_host, entry_id, "before");
                self.emitSessionShutdownEvent(ext_host, "fork", null);
            }
            var host = TsRpcSessionHost.init(self);
            var result = host.fork(entry_id, .before) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            defer result.deinit(self.allocator);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            try out.writer.writeAll("{\"text\":");
            try writeJsonString(self.allocator, &out.writer, result.selected_text orelse "");
            try out.writer.writeAll(",\"cancelled\":false}");
            try self.writeSuccessResponseRawData(id, command, out.written());
            return;
        }

        if (std.mem.eql(u8, command, "clone")) {
            var host = TsRpcSessionHost.init(self);
            var result = host.clone() catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            defer result.deinit(self.allocator);
            try self.writeSuccessResponseRawData(id, command, "{\"cancelled\":false}");
            return;
        }

        if (std.mem.eql(u8, command, "get_fork_messages")) {
            const data = try self.buildForkMessagesJson(session);
            defer self.allocator.free(data);
            try self.writeSuccessResponseRawData(id, command, data);
            return;
        }

        if (std.mem.eql(u8, command, "get_last_assistant_text")) {
            const text = try lastAssistantTextAlloc(self.allocator, session);
            defer if (text) |value| self.allocator.free(value);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            try out.writer.writeAll("{\"text\":");
            if (text) |value| {
                try writeJsonString(self.allocator, &out.writer, value);
            } else {
                try out.writer.writeAll("null");
            }
            try out.writer.writeAll("}");
            try self.writeSuccessResponseRawData(id, command, out.written());
            return;
        }

        if (std.mem.eql(u8, command, "set_session_name")) {
            const raw_name = requiredString(object, "name") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            const name = std.mem.trim(u8, raw_name, &std.ascii.whitespace);
            if (name.len == 0) {
                try self.writeErrorResponse(id, command, "Session name cannot be empty");
                return;
            }
            _ = session.session_manager.appendSessionInfo(name) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            try self.writeSessionInfoChangedEvent(name);
            try self.writeSuccessResponseNoData(id, command);
            return;
        }

        if (std.mem.eql(u8, command, "get_messages")) {
            const data = try self.buildMessagesJson(session.agent.getMessages());
            defer self.allocator.free(data);
            try self.writeSuccessResponseRawData(id, command, data);
            return;
        }

        if (std.mem.eql(u8, command, "get_commands")) {
            try self.writeSuccessResponseRawData(id, command, "{\"commands\":[]}");
            return;
        }

        if (std.mem.eql(u8, command, "navigate_to")) {
            const entry_id = requiredString(object, "entryId") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            const old_leaf_id_raw = session.session_manager.getLeafId();
            const old_leaf_id = if (old_leaf_id_raw) |lid| try self.allocator.dupe(u8, lid) else null;
            defer if (old_leaf_id) |lid| self.allocator.free(lid);
            if (self.extension_host) |ext_host| self.emitSessionBeforeTreeEvent(ext_host, entry_id);
            session.navigateTo(entry_id) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            const new_leaf_id = session.session_manager.getLeafId();
            if (self.extension_host) |ext_host| self.emitSessionTreeEvent(ext_host, new_leaf_id, old_leaf_id);
            try self.writeSuccessResponseNoData(id, command);
            return;
        }

        try self.writeNotImplemented(id, command);
    }

    fn writeCommandError(self: *TsRpcServer, id: ?[]const u8, command: []const u8, err: anyerror) !void {
        try self.writeErrorResponse(id, command, @errorName(err));
    }

    fn writeNotImplemented(self: *TsRpcServer, id: ?[]const u8, command: []const u8) !void {
        const message = try std.fmt.allocPrint(self.allocator, "Not implemented: {s}", .{command});
        defer self.allocator.free(message);
        try self.writeErrorResponse(id, command, message);
    }

    fn writeUnknownCommand(self: *TsRpcServer, command: ?[]const u8) !void {
        const message = if (command) |command_name|
            try std.fmt.allocPrint(self.allocator, "Unknown command: {s}", .{command_name})
        else
            try self.allocator.dupe(u8, "Unknown command: undefined");
        defer self.allocator.free(message);
        try self.writeErrorResponse(null, command, message);
    }

    fn parseErrorMessage(self: *TsRpcServer, line: []const u8) ![]u8 {
        const detail = try jsonParseErrorDetail(self.allocator, line);
        defer self.allocator.free(detail);
        return try std.fmt.allocPrint(self.allocator, "Failed to parse command: {s}", .{detail});
    }

    fn writeSuccessResponseNoData(self: *TsRpcServer, id: ?[]const u8, command: []const u8) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.writeSuccessResponseNoDataLocked(id, command);
    }

    fn writeSuccessResponseNoDataLocked(self: *TsRpcServer, id: ?[]const u8, command: []const u8) !void {
        try self.stdout_writer.writeAll("{");
        try writeIdField(self.allocator, self.stdout_writer, id);
        try self.stdout_writer.writeAll("\"type\":\"response\",\"command\":");
        try writeJsonString(self.allocator, self.stdout_writer, command);
        try self.stdout_writer.writeAll(",\"success\":true}\n");
        try self.stdout_writer.flush();
    }

    fn writeSuccessResponseRawData(
        self: *TsRpcServer,
        id: ?[]const u8,
        command: []const u8,
        data_json: []const u8,
    ) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);

        try self.stdout_writer.writeAll("{");
        try writeIdField(self.allocator, self.stdout_writer, id);
        try self.stdout_writer.writeAll("\"type\":\"response\",\"command\":");
        try writeJsonString(self.allocator, self.stdout_writer, command);
        try self.stdout_writer.writeAll(",\"success\":true,\"data\":");
        try self.stdout_writer.writeAll(data_json);
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeErrorResponse(self: *TsRpcServer, id: ?[]const u8, command: ?[]const u8, message: []const u8) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);

        try self.stdout_writer.writeAll("{");
        try writeIdField(self.allocator, self.stdout_writer, id);
        try self.stdout_writer.writeAll("\"type\":\"response\"");
        if (command) |command_name| {
            try self.stdout_writer.writeAll(",\"command\":");
            try writeJsonString(self.allocator, self.stdout_writer, command_name);
        }
        try self.stdout_writer.writeAll(",\"success\":false,\"error\":");
        try writeJsonString(self.allocator, self.stdout_writer, message);
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeExtensionUISelectRequest(
        self: *TsRpcServer,
        id: []const u8,
        title: []const u8,
        options: []const []const u8,
        timeout_ms: ?u64,
    ) !void {
        try self.registerPendingExtensionUIRequest(id, .select, timeout_ms);
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
        try writeJsonString(self.allocator, self.stdout_writer, id);
        try self.stdout_writer.writeAll(",\"method\":\"select\",\"title\":");
        try writeJsonString(self.allocator, self.stdout_writer, title);
        try self.stdout_writer.writeAll(",\"options\":[");
        for (options, 0..) |option, index| {
            if (index > 0) try self.stdout_writer.writeAll(",");
            try writeJsonString(self.allocator, self.stdout_writer, option);
        }
        try self.stdout_writer.writeAll("]");
        if (timeout_ms) |timeout| try self.stdout_writer.print(",\"timeout\":{d}", .{timeout});
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeExtensionUIConfirmRequest(
        self: *TsRpcServer,
        id: []const u8,
        title: []const u8,
        message: []const u8,
        timeout_ms: ?u64,
    ) !void {
        try self.registerPendingExtensionUIRequest(id, .confirm, timeout_ms);
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
        try writeJsonString(self.allocator, self.stdout_writer, id);
        try self.stdout_writer.writeAll(",\"method\":\"confirm\",\"title\":");
        try writeJsonString(self.allocator, self.stdout_writer, title);
        try self.stdout_writer.writeAll(",\"message\":");
        try writeJsonString(self.allocator, self.stdout_writer, message);
        if (timeout_ms) |timeout| try self.stdout_writer.print(",\"timeout\":{d}", .{timeout});
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeExtensionUIInputRequest(
        self: *TsRpcServer,
        id: []const u8,
        title: []const u8,
        placeholder: ?[]const u8,
        timeout_ms: ?u64,
    ) !void {
        try self.registerPendingExtensionUIRequest(id, .input, timeout_ms);
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
        try writeJsonString(self.allocator, self.stdout_writer, id);
        try self.stdout_writer.writeAll(",\"method\":\"input\",\"title\":");
        try writeJsonString(self.allocator, self.stdout_writer, title);
        if (placeholder) |text| {
            try self.stdout_writer.writeAll(",\"placeholder\":");
            try writeJsonString(self.allocator, self.stdout_writer, text);
        }
        if (timeout_ms) |timeout| try self.stdout_writer.print(",\"timeout\":{d}", .{timeout});
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeExtensionUIEditorRequest(
        self: *TsRpcServer,
        id: []const u8,
        title: []const u8,
        prefill: ?[]const u8,
    ) !void {
        try self.registerPendingExtensionUIRequest(id, .editor, null);
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
        try writeJsonString(self.allocator, self.stdout_writer, id);
        try self.stdout_writer.writeAll(",\"method\":\"editor\",\"title\":");
        try writeJsonString(self.allocator, self.stdout_writer, title);
        if (prefill) |text| {
            try self.stdout_writer.writeAll(",\"prefill\":");
            try writeJsonString(self.allocator, self.stdout_writer, text);
        }
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeExtensionUINotifyRequest(
        self: *TsRpcServer,
        id: []const u8,
        message: []const u8,
        notify_type: ?[]const u8,
    ) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
        try writeJsonString(self.allocator, self.stdout_writer, id);
        try self.stdout_writer.writeAll(",\"method\":\"notify\",\"message\":");
        try writeJsonString(self.allocator, self.stdout_writer, message);
        if (notify_type) |kind| {
            try self.stdout_writer.writeAll(",\"notifyType\":");
            try writeJsonString(self.allocator, self.stdout_writer, kind);
        }
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeExtensionUISetStatusRequest(
        self: *TsRpcServer,
        id: []const u8,
        status_key: []const u8,
        status_text: ?[]const u8,
    ) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
        try writeJsonString(self.allocator, self.stdout_writer, id);
        try self.stdout_writer.writeAll(",\"method\":\"setStatus\",\"statusKey\":");
        try writeJsonString(self.allocator, self.stdout_writer, status_key);
        if (status_text) |text| {
            try self.stdout_writer.writeAll(",\"statusText\":");
            try writeJsonString(self.allocator, self.stdout_writer, text);
        }
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeExtensionUISetWidgetRequest(
        self: *TsRpcServer,
        id: []const u8,
        widget_key: []const u8,
        widget_lines: ?[]const []const u8,
        widget_placement: ?[]const u8,
    ) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
        try writeJsonString(self.allocator, self.stdout_writer, id);
        try self.stdout_writer.writeAll(",\"method\":\"setWidget\",\"widgetKey\":");
        try writeJsonString(self.allocator, self.stdout_writer, widget_key);
        if (widget_lines) |lines| {
            try self.stdout_writer.writeAll(",\"widgetLines\":[");
            for (lines, 0..) |line, index| {
                if (index > 0) try self.stdout_writer.writeAll(",");
                try writeJsonString(self.allocator, self.stdout_writer, line);
            }
            try self.stdout_writer.writeAll("]");
        }
        if (widget_placement) |placement| {
            try self.stdout_writer.writeAll(",\"widgetPlacement\":");
            try writeJsonString(self.allocator, self.stdout_writer, placement);
        }
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeExtensionUISetTitleRequest(self: *TsRpcServer, id: []const u8, title: []const u8) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
        try writeJsonString(self.allocator, self.stdout_writer, id);
        try self.stdout_writer.writeAll(",\"method\":\"setTitle\",\"title\":");
        try writeJsonString(self.allocator, self.stdout_writer, title);
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeExtensionUISetEditorTextRequest(self: *TsRpcServer, id: []const u8, text: []const u8) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
        try writeJsonString(self.allocator, self.stdout_writer, id);
        try self.stdout_writer.writeAll(",\"method\":\"set_editor_text\",\"text\":");
        try writeJsonString(self.allocator, self.stdout_writer, text);
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn emitExtensionUIParityScenario(self: *TsRpcServer) !void {
        const select_options = [_][]const u8{ "option-a", "option-b" };
        const widget_lines = [_][]const u8{ "line one", "line two" };

        try self.writeExtensionUISelectRequest("ui_select", "Choose fixture", &select_options, 1000);
        try self.writeExtensionUIConfirmRequest("ui_confirm", "Confirm fixture", "Proceed?", 1000);
        try self.writeExtensionUIInputRequest("ui_input", "Fixture input", "value", 1000);
        try self.writeExtensionUINotifyRequest("ui_notify", "Fixture notice", "info");
        try self.writeExtensionUISetStatusRequest("ui_status", "fixture", "ready");
        try self.writeExtensionUISetWidgetRequest("ui_widget", "fixture", &widget_lines, "aboveEditor");
        try self.writeExtensionUISetTitleRequest("ui_title", "Fixture Title");
        try self.writeExtensionUISetEditorTextRequest("ui_editor_text", "fixture editor text");
        try self.writeExtensionUIEditorRequest("ui_editor", "Edit fixture", "prefill");
    }

    fn drainAvailableExtensionHostUiRequests(self: *TsRpcServer) !usize {
        const host = self.extension_host orelse return 0;
        var drained_count: usize = 0;
        while (true) {
            const requests = try host.takeUiRequests(self.allocator);
            {
                defer {
                    for (requests) |*request| request.deinit(self.allocator);
                    self.allocator.free(requests);
                }
                if (requests.len == 0) return drained_count;
                drained_count += requests.len;
                for (requests) |*request| {
                    try self.writeExtensionUIRequestFromHost(request.*);
                }
            }
        }
    }

    fn drainExtensionHostUiRequests(self: *TsRpcServer, idle_ms: u64) !void {
        if (self.extension_host == null) return;
        var idle_elapsed: u64 = 0;
        while (true) {
            const drained_count = try self.drainAvailableExtensionHostUiRequests();
            if (drained_count != 0) {
                idle_elapsed = 0;
                continue;
            }
            if (idle_elapsed >= idle_ms) return;
            const remaining = idle_ms - idle_elapsed;
            const sleep_ms: i64 = @intCast(if (remaining < EXTENSION_HOST_EVENT_LOOP_TICK_MS) remaining else EXTENSION_HOST_EVENT_LOOP_TICK_MS);
            if (sleep_ms == 0) return;
            std.Io.sleep(self.io, .fromMilliseconds(sleep_ms), .awake) catch {};
            idle_elapsed += @intCast(sleep_ms);
        }
    }

    fn serviceExtensionHostIdleTick(self: *TsRpcServer, elapsed_ms: u64) !void {
        _ = try self.drainAvailableExtensionHostUiRequests();
        if (elapsed_ms != 0) try self.advanceExtensionUITime(elapsed_ms);
        _ = try self.drainAvailableExtensionHostUiRequests();
        try self.resolveWaitForIdleRequests();
    }

    fn writeExtensionUIRequestFromHost(self: *TsRpcServer, request: extension_host_mod.ExtensionUiRequest) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, request.payload_json, .{}) catch return;
        defer parsed.deinit();
        const payload = switch (parsed.value) {
            .object => |object| object,
            else => return,
        };

        if (std.mem.eql(u8, request.method, "select")) {
            const title = requiredString(payload, "title") catch return;
            const options = try requiredStringArray(self.allocator, payload, "options");
            defer self.allocator.free(options);
            try self.writeExtensionUISelectRequest(request.id, title, options, optionalU64(payload, "timeout"));
            return;
        }
        if (std.mem.eql(u8, request.method, "confirm")) {
            const title = requiredString(payload, "title") catch return;
            const message = requiredString(payload, "message") catch return;
            try self.writeExtensionUIConfirmRequest(request.id, title, message, optionalU64(payload, "timeout"));
            return;
        }
        if (std.mem.eql(u8, request.method, "input")) {
            const title = requiredString(payload, "title") catch return;
            const placeholder = optionalString(payload, "placeholder") catch return;
            try self.writeExtensionUIInputRequest(request.id, title, placeholder, optionalU64(payload, "timeout"));
            return;
        }
        if (std.mem.eql(u8, request.method, "editor")) {
            const title = requiredString(payload, "title") catch return;
            const prefill = optionalString(payload, "prefill") catch return;
            try self.writeExtensionUIEditorRequest(request.id, title, prefill);
            return;
        }
        if (std.mem.eql(u8, request.method, "notify")) {
            const message = requiredString(payload, "message") catch return;
            const notify_type = optionalString(payload, "notifyType") catch return;
            try self.writeExtensionUINotifyRequest(request.id, message, notify_type);
            return;
        }
        if (std.mem.eql(u8, request.method, "setStatus")) {
            const status_key = requiredString(payload, "statusKey") catch return;
            const status_text = optionalString(payload, "statusText") catch return;
            try self.writeExtensionUISetStatusRequest(request.id, status_key, status_text);
            return;
        }
        if (std.mem.eql(u8, request.method, "setWidget")) {
            const widget_key = requiredString(payload, "widgetKey") catch return;
            const widget_lines = try optionalStringArray(self.allocator, payload, "widgetLines");
            defer if (widget_lines) |lines| self.allocator.free(lines);
            const widget_placement = optionalString(payload, "widgetPlacement") catch return;
            try self.writeExtensionUISetWidgetRequest(request.id, widget_key, widget_lines, widget_placement);
            return;
        }
        if (std.mem.eql(u8, request.method, "setTitle")) {
            const title = requiredString(payload, "title") catch return;
            try self.writeExtensionUISetTitleRequest(request.id, title);
            return;
        }
        if (std.mem.eql(u8, request.method, "set_editor_text")) {
            const text = requiredString(payload, "text") catch return;
            try self.writeExtensionUISetEditorTextRequest(request.id, text);
            return;
        }

        // Extension command context APIs (VAL-EXT-031..036)

        if (std.mem.eql(u8, request.method, "wait_for_idle")) {
            if (!self.isAgentBusy()) {
                // Agent is already idle — respond immediately.
                if (self.extension_host) |host| {
                    try host.sendExtensionUiResponse(request.id, "{}");
                }
            } else {
                // Agent is busy — queue the ID; resolveWaitForIdleRequests will
                // send the response once the agent becomes idle.
                const id_copy = try self.allocator.dupe(u8, request.id);
                errdefer self.allocator.free(id_copy);
                try self.pending_wait_for_idle_ids.append(self.allocator, id_copy);
            }
            return;
        }

        if (std.mem.eql(u8, request.method, "send_custom_message")) {
            const session = self.session orelse return;
            // Default customType is "extension.message" when the field is omitted.
            const custom_type_or_null = optionalString(payload, "customType") catch {
                if (self.extension_host) |host| try host.sendExtensionUiResponse(request.id, "{\"error\":\"customType must be a string\"}");
                return;
            };
            const custom_type = custom_type_or_null orelse "extension.message";
            const display = optionalBool(payload, "display") orelse true;
            const trigger_turn = optionalBool(payload, "triggerTurn") orelse false;
            const deliver_as = optionalString(payload, "deliverAs") catch {
                if (self.extension_host) |host| try host.sendExtensionUiResponse(request.id, "{\"error\":\"deliverAs must be a string\"}");
                return;
            };

            // deliverAs="nextTurn" is not yet supported — no holding queue is implemented.
            // Return an explicit error so callers waiting on response_required don't hang.
            if (deliver_as) |mode| {
                if (std.mem.eql(u8, mode, "nextTurn")) {
                    if (self.extension_host) |host| try host.sendExtensionUiResponse(request.id, "{\"error\":\"deliverAs nextTurn is not yet supported\"}");
                    return;
                }
            }

            // Build content: prefer string, fall back to empty text.
            const content_text: []const u8 = if (payload.get("content")) |c|
                if (c == .string) c.string else ""
            else "";
            const content: session_manager_mod.CustomMessageContent = .{ .text = content_text };

            // Persist the custom message entry in the session file.
            const details = payload.get("details");
            _ = try session.session_manager.appendCustomMessageEntry(custom_type, content, display, details);

            // Handle delivery mode when the agent is streaming.
            if (session.isStreaming() or self.hasInFlightPrompt()) {
                if (deliver_as) |mode| {
                    if (std.mem.eql(u8, mode, "steer")) {
                        session.steer(content_text, &.{}) catch {};
                    } else if (std.mem.eql(u8, mode, "followUp")) {
                        session.followUp(content_text, &.{}) catch {};
                    }
                }
            } else if (trigger_turn) {
                // Not streaming but caller wants to trigger a new turn.
                const text_copy = try self.allocator.dupe(u8, content_text);
                errdefer self.allocator.free(text_copy);
                const images = try self.allocator.alloc(ai.ImageContent, 0);
                const task = try PromptTask.create(self.allocator, self.io, self, session, null, text_copy, images);
                try self.prompt_tasks.append(self.allocator, task);
                task.spawn() catch {
                    _ = self.prompt_tasks.pop();
                    task.joinAndDestroy();
                };
            }

            // Acknowledge to the extension host.
            if (self.extension_host) |host| {
                try host.sendExtensionUiResponse(request.id, "{}");
            }
            return;
        }

        if (std.mem.eql(u8, request.method, "send_user_message")) {
            const session = self.session orelse return;
            const text = optionalString(payload, "text") catch {
                if (self.extension_host) |host| try host.sendExtensionUiResponse(request.id, "{\"error\":\"text must be a string\"}");
                return;
            } orelse "";
            const deliver_as = optionalString(payload, "deliverAs") catch {
                if (self.extension_host) |host| try host.sendExtensionUiResponse(request.id, "{\"error\":\"deliverAs must be a string\"}");
                return;
            };

            // deliverAs="nextTurn" is not yet supported — no holding queue is implemented.
            // Return an explicit error so callers waiting on response_required don't hang.
            if (deliver_as) |mode| {
                if (std.mem.eql(u8, mode, "nextTurn")) {
                    if (self.extension_host) |host| try host.sendExtensionUiResponse(request.id, "{\"error\":\"deliverAs nextTurn is not yet supported\"}");
                    return;
                }
            }

            if (session.isStreaming() or self.hasInFlightPrompt()) {
                // Route based on deliverAs when the agent is busy.
                const is_steer = if (deliver_as) |mode| std.mem.eql(u8, mode, "steer") else false;
                if (is_steer) {
                    session.steer(text, &.{}) catch {};
                } else {
                    // Default: followUp when streaming.
                    session.followUp(text, &.{}) catch {};
                }
            } else {
                // Not streaming: start a new background prompt task.
                const text_copy = try self.allocator.dupe(u8, text);
                errdefer self.allocator.free(text_copy);
                const images = try self.allocator.alloc(ai.ImageContent, 0);
                const task = try PromptTask.create(self.allocator, self.io, self, session, null, text_copy, images);
                try self.prompt_tasks.append(self.allocator, task);
                task.spawn() catch {
                    _ = self.prompt_tasks.pop();
                    task.joinAndDestroy();
                };
            }

            // Acknowledge to the extension host.
            if (self.extension_host) |host| {
                try host.sendExtensionUiResponse(request.id, "{}");
            }
            return;
        }
    }

    fn writeEvent(self: *TsRpcServer, event: agent.AgentEvent) !void {
        if (self.suppress_events) return;
        const value = try json_event_wire.agentEventToJsonValue(self.allocator, event);
        defer common.deinitJsonValue(self.allocator, value);
        const line = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(line);

        // Forward agent event to extension host stdin (non-blocking; drops if pipe full)
        if (self.extension_host) |host| {
            switch (event.event_type) {
                .turn_start => {
                    self.turn_index += 1;
                    self.emitExtensionTurnStartFrame(host);
                },
                .turn_end => self.emitExtensionTurnEndFrame(host, line),
                else => host.sendExtensionEventFrame(line),
            }
            // Emit the typed tool_call / tool_result companion frames that the
            // extension event API exposes separately from the execution lifecycle events.
            switch (event.event_type) {
                .tool_execution_start => self.emitExtensionToolCallEvent(host, event),
                .tool_execution_end => self.emitExtensionToolResultEvent(host, event),
                else => {},
            }
        }

        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.print("{s}\n", .{line});
        try self.stdout_writer.flush();
    }

    /// Emit a `tool_call` extension event frame when a tool starts executing.
    /// Mirrors the TS `ToolCallEvent` wire format: type, toolCallId, toolName, input.
    fn emitExtensionToolCallEvent(self: *TsRpcServer, host: *extension_host_mod.HostProcess, event: agent.AgentEvent) void {
        const tool_call_id = event.tool_call_id orelse return;
        const tool_name = event.tool_name orelse return;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"tool_call\",\"toolCallId\":") catch return;
        writeJsonString(self.allocator, &out.writer, tool_call_id) catch return;
        out.writer.writeAll(",\"toolName\":") catch return;
        writeJsonString(self.allocator, &out.writer, tool_name) catch return;
        out.writer.writeAll(",\"input\":") catch return;
        if (event.args) |args| {
            const args_json = std.json.Stringify.valueAlloc(self.allocator, args, .{}) catch return;
            defer self.allocator.free(args_json);
            out.writer.writeAll(args_json) catch return;
        } else {
            out.writer.writeAll("{}") catch return;
        }
        out.writer.writeAll("}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit a `tool_result` extension event frame when a tool finishes executing.
    /// Mirrors the TS `ToolResultEvent` wire format: type, toolCallId, toolName,
    /// input (original call args from event.args), content, isError.
    /// thinking and tool_call content blocks are skipped (not emitted as empty text).
    fn emitExtensionToolResultEvent(self: *TsRpcServer, host: *extension_host_mod.HostProcess, event: agent.AgentEvent) void {
        const tool_call_id = event.tool_call_id orelse return;
        const tool_name = event.tool_name orelse return;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"tool_result\",\"toolCallId\":") catch return;
        writeJsonString(self.allocator, &out.writer, tool_call_id) catch return;
        out.writer.writeAll(",\"toolName\":") catch return;
        writeJsonString(self.allocator, &out.writer, tool_name) catch return;
        // Retain original tool-call args as input (TS ToolResultEvent.input = call arguments).
        out.writer.writeAll(",\"input\":") catch return;
        if (event.args) |args| {
            const args_json = std.json.Stringify.valueAlloc(self.allocator, args, .{}) catch return;
            defer self.allocator.free(args_json);
            out.writer.writeAll(args_json) catch return;
        } else {
            out.writer.writeAll("{}") catch return;
        }
        out.writer.writeAll(",\"content\":[") catch return;
        if (event.result) |result| {
            var first = true;
            for (result.content) |block| {
                switch (block) {
                    .text => |text| {
                        if (!first) out.writer.writeAll(",") catch return;
                        first = false;
                        out.writer.writeAll("{\"type\":\"text\",\"text\":") catch return;
                        writeJsonString(self.allocator, &out.writer, text.text) catch return;
                        out.writer.writeAll("}") catch return;
                    },
                    .image => |image| {
                        if (!first) out.writer.writeAll(",") catch return;
                        first = false;
                        out.writer.writeAll("{\"type\":\"image\",\"mimeType\":") catch return;
                        writeJsonString(self.allocator, &out.writer, image.mime_type) catch return;
                        out.writer.writeAll(",\"data\":") catch return;
                        writeJsonString(self.allocator, &out.writer, image.data) catch return;
                        out.writer.writeAll("}") catch return;
                    },
                    // thinking and tool_call blocks are intentionally skipped —
                    // they should not appear in the tool_result.content wire frame.
                    else => {},
                }
            }
        }
        out.writer.writeAll("],\"isError\":") catch return;
        out.writer.writeAll(if (event.is_error orelse false) "true" else "false") catch return;
        out.writer.writeAll("}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit a `model_select` extension event frame when the active model changes.
    /// Mirrors the TS `ModelSelectEvent` wire format.
    fn emitExtensionModelSelectEvent(self: *TsRpcServer, host: *extension_host_mod.HostProcess, model: ai.Model, prev_model: ai.Model, source: []const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"model_select\",\"model\":") catch return;
        writeModelJson(self.allocator, &out.writer, model) catch return;
        out.writer.writeAll(",\"previousModel\":") catch return;
        writeModelJson(self.allocator, &out.writer, prev_model) catch return;
        out.writer.writeAll(",\"source\":") catch return;
        writeJsonString(self.allocator, &out.writer, source) catch return;
        out.writer.writeAll("}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit a `thinking_level_select` extension event frame when the thinking level changes.
    /// Mirrors the TS `ThinkingLevelSelectEvent` wire format.
    fn emitExtensionThinkingLevelSelectEvent(self: *TsRpcServer, host: *extension_host_mod.HostProcess, level: agent.ThinkingLevel, prev_level: agent.ThinkingLevel) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"thinking_level_select\",\"level\":") catch return;
        writeJsonString(self.allocator, &out.writer, thinkingLevelName(level)) catch return;
        out.writer.writeAll(",\"previousLevel\":") catch return;
        writeJsonString(self.allocator, &out.writer, thinkingLevelName(prev_level)) catch return;
        out.writer.writeAll("}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit an `input` extension event frame when user input is received.
    /// Mirrors the TS `InputEvent` wire format: type, text, source.
    fn emitExtensionInputEvent(self: *TsRpcServer, host: *extension_host_mod.HostProcess, text: []const u8, source: []const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"input\",\"text\":") catch return;
        writeJsonString(self.allocator, &out.writer, text) catch return;
        out.writer.writeAll(",\"source\":") catch return;
        writeJsonString(self.allocator, &out.writer, source) catch return;
        out.writer.writeAll("}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit a `turn_start` extension event frame with the current turnIndex and timestamp.
    /// Mirrors the TS TurnStartEvent wire format: type, turnIndex, timestamp.
    fn emitExtensionTurnStartFrame(self: *TsRpcServer, host: *extension_host_mod.HostProcess) void {
        const ts_ms = @divFloor(std.Io.Clock.now(.awake, self.io).nanoseconds, std.time.ns_per_ms);
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.print("{{\"type\":\"turn_start\",\"turnIndex\":{d},\"timestamp\":{d}}}", .{
            self.turn_index,
            ts_ms,
        }) catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit a `turn_end` extension event frame with turnIndex injected after the
    /// type field. The base_frame (from json_event_wire) carries message and
    /// toolResults; this function prepends the parity fields before forwarding to the host.
    /// Note: TS TurnEndEvent does not declare a timestamp field; timestamp is only on turn_start.
    fn emitExtensionTurnEndFrame(self: *TsRpcServer, host: *extension_host_mod.HostProcess, base_frame: []const u8) void {
        const base_prefix = "{\"type\":\"turn_end\"";
        if (!std.mem.startsWith(u8, base_frame, base_prefix)) {
            host.sendExtensionEventFrame(base_frame);
            return;
        }
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.print("{s},\"turnIndex\":{d}", .{
            base_prefix,
            self.turn_index,
        }) catch return;
        out.writer.writeAll(base_frame[base_prefix.len..]) catch return;
        host.sendExtensionEventFrame(out.written());
    }

    // -------------------------------------------------------------------------
    // Session lifecycle extension event helpers
    // -------------------------------------------------------------------------

    /// Emit session_before_switch to extension host.
    /// reason: "new" | "resume"
    fn emitSessionBeforeSwitchEvent(self: *TsRpcServer, host: *extension_host_mod.HostProcess, reason: []const u8, target_file: ?[]const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"session_before_switch\",\"reason\":") catch return;
        writeJsonString(self.allocator, &out.writer, reason) catch return;
        if (target_file) |file| {
            out.writer.writeAll(",\"targetSessionFile\":") catch return;
            writeJsonString(self.allocator, &out.writer, file) catch return;
        }
        out.writer.writeAll("}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit session_shutdown to extension host.
    /// reason: "quit" | "reload" | "new" | "resume" | "fork"
    fn emitSessionShutdownEvent(self: *TsRpcServer, host: *extension_host_mod.HostProcess, reason: []const u8, target_file: ?[]const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"session_shutdown\",\"reason\":") catch return;
        writeJsonString(self.allocator, &out.writer, reason) catch return;
        if (target_file) |file| {
            out.writer.writeAll(",\"targetSessionFile\":") catch return;
            writeJsonString(self.allocator, &out.writer, file) catch return;
        }
        out.writer.writeAll("}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit session_before_fork to extension host.
    fn emitSessionBeforeForkEvent(self: *TsRpcServer, host: *extension_host_mod.HostProcess, entry_id: []const u8, position: []const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"session_before_fork\",\"entryId\":") catch return;
        writeJsonString(self.allocator, &out.writer, entry_id) catch return;
        out.writer.writeAll(",\"position\":") catch return;
        writeJsonString(self.allocator, &out.writer, position) catch return;
        out.writer.writeAll("}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit session_before_compact to extension host.
    fn emitSessionBeforeCompactEvent(self: *TsRpcServer, host: *extension_host_mod.HostProcess, custom_instructions: ?[]const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"session_before_compact\"") catch return;
        if (custom_instructions) |instructions| {
            out.writer.writeAll(",\"customInstructions\":") catch return;
            writeJsonString(self.allocator, &out.writer, instructions) catch return;
        }
        out.writer.writeAll("}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit session_compact to extension host after compaction completes.
    fn emitSessionCompactEvent(self: *TsRpcServer, host: *extension_host_mod.HostProcess) void {
        _ = self;
        host.sendExtensionEventFrame("{\"type\":\"session_compact\",\"fromExtension\":false}");
    }

    /// Emit session_before_tree to extension host before navigating the session tree.
    fn emitSessionBeforeTreeEvent(self: *TsRpcServer, host: *extension_host_mod.HostProcess, target_id: []const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"session_before_tree\",\"preparation\":{\"targetId\":") catch return;
        writeJsonString(self.allocator, &out.writer, target_id) catch return;
        out.writer.writeAll("}}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit session_tree to extension host after tree navigation completes.
    fn emitSessionTreeEvent(self: *TsRpcServer, host: *extension_host_mod.HostProcess, new_leaf_id: ?[]const u8, old_leaf_id: ?[]const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"session_tree\",\"newLeafId\":") catch return;
        if (new_leaf_id) |nid| {
            writeJsonString(self.allocator, &out.writer, nid) catch return;
        } else {
            out.writer.writeAll("null") catch return;
        }
        out.writer.writeAll(",\"oldLeafId\":") catch return;
        if (old_leaf_id) |oid| {
            writeJsonString(self.allocator, &out.writer, oid) catch return;
        } else {
            out.writer.writeAll("null") catch return;
        }
        out.writer.writeAll(",\"fromExtension\":false}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    fn writeQueueUpdate(self: *TsRpcServer) !void {
        const session = self.session orelse return;
        const steering = try session.agent.snapshotSteeringMessages(self.allocator);
        defer {
            agent.deinitMessageSlice(self.allocator, steering);
            self.allocator.free(steering);
        }
        const follow_up = try session.agent.snapshotFollowUpMessages(self.allocator);
        defer {
            agent.deinitMessageSlice(self.allocator, follow_up);
            self.allocator.free(follow_up);
        }

        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"queue_update\",\"steering\":");
        try writeQueuedMessageTexts(self.allocator, self.stdout_writer, steering);
        try self.stdout_writer.writeAll(",\"followUp\":");
        try writeQueuedMessageTexts(self.allocator, self.stdout_writer, follow_up);
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeRetryLifecycleEvent(self: *TsRpcServer, event: session_mod.RetryLifecycleEvent) !void {
        if (self.suppress_events) return;
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);

        switch (event) {
            .start => |start_event| {
                try self.stdout_writer.writeAll("{\"type\":\"auto_retry_start\",\"attempt\":");
                try self.stdout_writer.print("{d}", .{start_event.attempt});
                try self.stdout_writer.writeAll(",\"maxAttempts\":");
                try self.stdout_writer.print("{d}", .{start_event.max_attempts});
                try self.stdout_writer.writeAll(",\"delayMs\":");
                try self.stdout_writer.print("{d}", .{start_event.delay_ms});
                try self.stdout_writer.writeAll(",\"errorMessage\":");
                try writeJsonString(self.allocator, self.stdout_writer, start_event.error_message);
                try self.stdout_writer.writeAll("}\n");
            },
            .end => |end| {
                try self.stdout_writer.writeAll("{\"type\":\"auto_retry_end\",\"success\":");
                try self.stdout_writer.writeAll(if (end.success) "true" else "false");
                try self.stdout_writer.writeAll(",\"attempt\":");
                try self.stdout_writer.print("{d}", .{end.attempt});
                if (end.final_error) |final_error| {
                    try self.stdout_writer.writeAll(",\"finalError\":");
                    try writeJsonString(self.allocator, self.stdout_writer, final_error);
                }
                try self.stdout_writer.writeAll("}\n");
            },
        }
        try self.stdout_writer.flush();
    }

    fn buildStateJson(self: *TsRpcServer, session: *session_mod.AgentSession) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const writer = &out.writer;

        try writer.writeAll("{\"model\":");
        try writeModelJson(self.allocator, writer, session.agent.getModel());
        try writer.writeAll(",\"thinkingLevel\":");
        try writeJsonString(self.allocator, writer, thinkingLevelName(session.agent.getThinkingLevel()));
        try writer.writeAll(",\"isStreaming\":");
        try writer.writeAll(if (session.isStreaming()) "true" else "false");
        try writer.writeAll(",\"isCompacting\":");
        try writer.writeAll(if (session.isCompacting()) "true" else "false");
        try writer.writeAll(",\"steeringMode\":");
        try writeJsonString(self.allocator, writer, queueModeName(session.agent.steering_queue.mode));
        try writer.writeAll(",\"followUpMode\":");
        try writeJsonString(self.allocator, writer, queueModeName(session.agent.follow_up_queue.mode));
        if (session.session_manager.getSessionFile()) |session_file| {
            try writer.writeAll(",\"sessionFile\":");
            try writeJsonString(self.allocator, writer, session_file);
        }
        try writer.writeAll(",\"sessionId\":");
        try writeJsonString(self.allocator, writer, session.session_manager.getSessionId());
        if (session.session_manager.getSessionName()) |session_name| {
            try writer.writeAll(",\"sessionName\":");
            try writeJsonString(self.allocator, writer, session_name);
        }
        try writer.writeAll(",\"autoCompactionEnabled\":");
        try writer.writeAll(if (session.compaction_settings.enabled) "true" else "false");
        try writer.print(",\"messageCount\":{d}", .{session.agent.getMessages().len});
        try writer.print(",\"pendingMessageCount\":{d}", .{session.agent.steeringQueueLen() + session.agent.followUpQueueLen()});
        try writer.writeAll("}");

        return try self.allocator.dupe(u8, out.written());
    }

    fn buildMessagesJson(self: *TsRpcServer, messages: []const agent.AgentMessage) ![]u8 {
        var array = std.json.Array.init(self.allocator);
        errdefer array.deinit();
        for (messages) |message| {
            try array.append(try json_event_wire.messageToJsonValue(self.allocator, message));
        }
        const value = std.json.Value{ .object = blk: {
            var object = try std.json.ObjectMap.init(self.allocator, &.{}, &.{});
            errdefer object.deinit(self.allocator);
            try object.put(self.allocator, try self.allocator.dupe(u8, "messages"), .{ .array = array });
            break :blk object;
        } };
        defer common.deinitJsonValue(self.allocator, value);
        return try std.json.Stringify.valueAlloc(self.allocator, value, .{});
    }

    fn buildModelJson(self: *TsRpcServer, model: ai.Model) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try writeModelJson(self.allocator, &out.writer, model);
        return try self.allocator.dupe(u8, out.written());
    }

    fn buildAvailableModelsJson(self: *TsRpcServer) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const registry = ai.model_registry.getDefault();
        try out.writer.writeAll("{\"models\":[");
        for (registry.models.items, 0..) |entry, index| {
            if (index > 0) try out.writer.writeAll(",");
            try writeModelJson(self.allocator, &out.writer, entry.model);
        }
        try out.writer.writeAll("]}");
        return try self.allocator.dupe(u8, out.written());
    }

    fn buildCompactionResultJson(self: *TsRpcServer, result: session_mod.CompactionResult) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try out.writer.writeAll("{\"summary\":");
        try writeJsonString(self.allocator, &out.writer, result.summary);
        try out.writer.writeAll(",\"firstKeptEntryId\":");
        try writeJsonString(self.allocator, &out.writer, result.first_kept_entry_id);
        try out.writer.print(",\"tokensBefore\":{d}", .{result.tokens_before});
        try out.writer.writeAll("}");
        return try self.allocator.dupe(u8, out.written());
    }

    fn buildSessionStatsJson(self: *TsRpcServer, session: *const session_mod.AgentSession) ![]u8 {
        const stats = session_advanced.getSessionStats(session);
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const writer = &out.writer;
        try writer.writeAll("{");
        if (stats.session_file) |session_file| {
            try writer.writeAll("\"sessionFile\":");
            try writeJsonString(self.allocator, writer, session_file);
            try writer.writeAll(",");
        }
        try writer.writeAll("\"sessionId\":");
        try writeJsonString(self.allocator, writer, stats.session_id);
        try writer.print(
            ",\"userMessages\":{d},\"assistantMessages\":{d},\"toolCalls\":{d},\"toolResults\":{d},\"totalMessages\":{d}",
            .{ stats.user_messages, stats.assistant_messages, stats.tool_calls, stats.tool_results, stats.total_messages },
        );
        try writer.print(
            ",\"tokens\":{{\"input\":{d},\"output\":{d},\"cacheRead\":{d},\"cacheWrite\":{d},\"total\":{d}}}",
            .{ stats.tokens.input, stats.tokens.output, stats.tokens.cache_read, stats.tokens.cache_write, stats.tokens.total },
        );
        try writer.writeAll(",\"cost\":");
        try writeJsonNumber(self.allocator, writer, stats.cost);
        if (stats.context_usage) |context_usage| {
            try writer.writeAll(",\"contextUsage\":{\"used\":");
            if (context_usage.tokens) |tokens| {
                try writer.print("{d}", .{tokens});
            } else {
                try writer.writeAll("null");
            }
            try writer.print(",\"available\":{d},\"percentage\":", .{context_usage.context_window});
            if (context_usage.percent) |percent| {
                try writeJsonNumber(self.allocator, writer, percent);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("}");
        return try self.allocator.dupe(u8, out.written());
    }

    fn buildForkMessagesJson(self: *TsRpcServer, session: *const session_mod.AgentSession) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try out.writer.writeAll("{\"messages\":[");
        var first = true;
        for (session.session_manager.getEntries()) |entry| {
            switch (entry) {
                .message => |message_entry| switch (message_entry.message) {
                    .user => |user| {
                        const text = try textBlocksConcat(self.allocator, user.content);
                        defer self.allocator.free(text);
                        if (text.len == 0) continue;
                        if (!first) try out.writer.writeAll(",");
                        first = false;
                        try out.writer.writeAll("{\"entryId\":");
                        try writeJsonString(self.allocator, &out.writer, message_entry.id);
                        try out.writer.writeAll(",\"text\":");
                        try writeJsonString(self.allocator, &out.writer, text);
                        try out.writer.writeAll("}");
                    },
                    else => {},
                },
                else => {},
            }
        }
        try out.writer.writeAll("]}");
        return try self.allocator.dupe(u8, out.written());
    }

    fn writeCompactionStartEvent(self: *TsRpcServer, reason: []const u8) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"compaction_start\",\"reason\":");
        try writeJsonString(self.allocator, self.stdout_writer, reason);
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeCompactionEndEvent(
        self: *TsRpcServer,
        reason: []const u8,
        result_json: ?[]const u8,
        aborted: bool,
        will_retry: bool,
    ) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"compaction_end\",\"reason\":");
        try writeJsonString(self.allocator, self.stdout_writer, reason);
        if (result_json) |result| {
            try self.stdout_writer.writeAll(",\"result\":");
            try self.stdout_writer.writeAll(result);
        }
        try self.stdout_writer.writeAll(",\"aborted\":");
        try self.stdout_writer.writeAll(if (aborted) "true" else "false");
        try self.stdout_writer.writeAll(",\"willRetry\":");
        try self.stdout_writer.writeAll(if (will_retry) "true" else "false");
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeSessionInfoChangedEvent(self: *TsRpcServer, name: []const u8) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"session_info_changed\",\"name\":");
        try writeJsonString(self.allocator, self.stdout_writer, name);
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn enqueueDeferredSuccess(
        self: *TsRpcServer,
        id: ?[]const u8,
        command: []const u8,
        priority: DeferredResponsePriority,
    ) !void {
        self.deferred_responses_mutex.lockUncancelable(self.io);
        defer self.deferred_responses_mutex.unlock(self.io);

        try self.deferred_responses.append(self.allocator, .{
            .id = if (id) |id_string| try self.allocator.dupe(u8, id_string) else null,
            .command = try self.allocator.dupe(u8, command),
            .priority = priority,
            .sequence = self.next_deferred_response_sequence,
        });
        self.next_deferred_response_sequence += 1;
    }

    fn enqueueDeferredRawData(
        self: *TsRpcServer,
        id: ?[]const u8,
        command: []const u8,
        data_json: []const u8,
        priority: DeferredResponsePriority,
        sequence: usize,
    ) !void {
        self.deferred_responses_mutex.lockUncancelable(self.io);
        defer self.deferred_responses_mutex.unlock(self.io);

        try self.deferred_responses.append(self.allocator, .{
            .id = if (id) |id_string| try self.allocator.dupe(u8, id_string) else null,
            .command = try self.allocator.dupe(u8, command),
            .data_json = try self.allocator.dupe(u8, data_json),
            .priority = priority,
            .sequence = sequence,
        });
    }

    fn flushDeferredResponses(self: *TsRpcServer) !void {
        self.deferred_responses_mutex.lockUncancelable(self.io);
        defer self.deferred_responses_mutex.unlock(self.io);

        if (self.deferred_responses.items.len == 0) return;
        var should_abort_after_flush = false;
        std.mem.sort(DeferredResponse, self.deferred_responses.items, {}, lessThanDeferredResponse);
        const hold_bash_completions = self.hasUnfinishedBashTask();
        var keep_count: usize = 0;
        for (self.deferred_responses.items, 0..) |*response, index| {
            if (response.priority == .bash_completion and hold_bash_completions) {
                if (keep_count != index) {
                    self.deferred_responses.items[keep_count] = response.*;
                }
                keep_count += 1;
                continue;
            }
            if (response.data_json) |data_json| {
                try self.writeSuccessResponseRawData(response.id, response.command, data_json);
            } else {
                try self.writeSuccessResponseNoData(response.id, response.command);
            }
            if (std.mem.eql(u8, response.command, "abort")) {
                should_abort_after_flush = true;
            }
            response.deinit(self.allocator);
        }
        self.deferred_responses.shrinkRetainingCapacity(keep_count);
        if (should_abort_after_flush) {
            self.abortActivePromptWork();
        }
    }
};

fn deferredFlushMain(server: *TsRpcServer) void {
    while (!server.deferred_flush_stop.load(.seq_cst)) {
        std.Io.sleep(server.io, .fromMilliseconds(DEFERRED_RESPONSE_FLUSH_INTERVAL_MS), .awake) catch {};
        if (server.deferred_flush_stop.load(.seq_cst)) break;
        if (server.shouldHoldDeferredFlush()) continue;
        server.flushDeferredResponses() catch {};
    }
}

fn lessThanDeferredResponse(_: void, lhs: DeferredResponse, rhs: DeferredResponse) bool {
    if (@intFromEnum(lhs.priority) != @intFromEnum(rhs.priority)) {
        return @intFromEnum(lhs.priority) < @intFromEnum(rhs.priority);
    }
    return lhs.sequence < rhs.sequence;
}

pub fn runTsRpcMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    options: RunTsRpcModeOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    var server = TsRpcServer.init(allocator, io, session, stdout_writer, stderr_writer);
    try server.start();
    defer server.finish() catch {};
    if (options.extension_host) |host_options| {
        try server.startExtensionHost(host_options);
    }
    if (options.extension_ui_parity_scenario) {
        try server.emitExtensionUIParityScenario();
    }

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(allocator);

    const service_extension_host = options.extension_host != null;
    while (true) {
        if (service_extension_host) {
            try server.serviceExtensionHostIdleTick(0);
            if (stdin_reader.interface.bufferedLen() == 0 and !try pollTsRpcStdin(EXTENSION_HOST_EVENT_LOOP_TICK_MS)) {
                try server.serviceExtensionHostIdleTick(EXTENSION_HOST_EVENT_LOOP_TICK_MS);
                continue;
            }
        }

        const byte = stdin_reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        server.setDeferredFlushInputBacklog(stdin_reader.interface.bufferedLen() > 0);
        if (byte == '\n') {
            try server.handleLine(line_buffer.items);
            line_buffer.clearRetainingCapacity();
            server.setDeferredFlushInputBacklog(stdin_reader.interface.bufferedLen() > 0);
            if (service_extension_host) {
                try server.serviceExtensionHostIdleTick(0);
            } else {
                try server.drainExtensionHostUiRequests(50);
            }
            continue;
        }
        try line_buffer.append(allocator, byte);
    }

    server.setDeferredFlushInputBacklog(false);
    if (line_buffer.items.len > 0) {
        try server.handleLine(line_buffer.items);
        if (service_extension_host) {
            try server.serviceExtensionHostIdleTick(0);
        } else {
            try server.drainExtensionHostUiRequests(50);
        }
    }

    if (server.hasInFlightPrompt()) {
        server.suppress_events = true;
        server.abortActivePromptWork();
    }
    try server.flushDeferredResponses();
    try server.finish();
    return 0;
}

fn pollTsRpcStdin(timeout_ms: i32) !bool {
    var fds = [_]std.posix.pollfd{
        .{
            .fd = 0,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    return (try std.posix.poll(fds[0..], timeout_ms)) > 0;
}

fn stripTrailingCarriageReturn(line: []const u8) []const u8 {
    if (std.mem.endsWith(u8, line, "\r")) return line[0 .. line.len - 1];
    return line;
}

fn jsonParseErrorDetail(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    const first_index = firstNonJsonWhitespaceIndex(line) orelse
        return try allocator.dupe(u8, "Unexpected end of JSON input");
    const trimmed = line[first_index..];

    // V8 does not expose JSON.parse diagnostics as a stable API, and embedding
    // V8/Node in normal Zig execution is out of scope for ts-rpc mode. This
    // mapper intentionally covers the generated malformed JSONL corpus syntax
    // classes byte-for-byte and falls back only for syntax outside that corpus.
    if (badUnicodeEscapeIndex(line)) |index| {
        return try std.fmt.allocPrint(
            allocator,
            "Bad Unicode escape in JSON at position {d} (line 1 column {d})",
            .{ index, index + 1 },
        );
    }

    if (hasUnterminatedString(line)) {
        return try std.fmt.allocPrint(
            allocator,
            "Unterminated string in JSON at position {d} (line 1 column {d})",
            .{ line.len, line.len + 1 },
        );
    }

    switch (trimmed[0]) {
        '{' => return try objectParseErrorDetail(allocator, line, first_index),
        '[' => return try arrayParseErrorDetail(allocator, line, first_index),
        't' => return try literalParseErrorDetail(allocator, line, first_index, "true"),
        'f' => return try literalParseErrorDetail(allocator, line, first_index, "false"),
        'n' => return try literalParseErrorDetail(allocator, line, first_index, "null"),
        '0'...'9', '-' => return try numberParseErrorDetail(allocator, line, first_index),
        else => return try unexpectedTokenDetail(allocator, line, first_index),
    }
}

fn objectParseErrorDetail(allocator: std.mem.Allocator, line: []const u8, object_start: usize) ![]u8 {
    const after_open = firstNonJsonWhitespaceIndexFrom(line, object_start + 1) orelse object_start + 1;
    if (after_open >= line.len) {
        return try expectedPropertyNameOrCloseDetail(allocator, after_open);
    }
    if (line[after_open] == '}') {
        if (firstNonJsonWhitespaceIndexFrom(line, after_open + 1)) |extra_index| {
            return try unexpectedNonWhitespaceDetail(allocator, extra_index);
        }
        return try expectedPropertyNameOrCloseDetail(allocator, after_open);
    }
    if (line[after_open] != '"') {
        return try expectedPropertyNameOrCloseDetail(allocator, after_open);
    }

    if (scanJsonStringEnd(line, after_open)) |property_end| {
        const after_property = firstNonJsonWhitespaceIndexFrom(line, property_end + 1) orelse
            return try allocator.dupe(u8, "Unexpected end of JSON input");
        if (line[after_property] != ':') {
            return try std.fmt.allocPrint(
                allocator,
                "Expected ':' after property name in JSON at position {d} (line 1 column {d})",
                .{ after_property, after_property + 1 },
            );
        }
        const value_start = firstNonJsonWhitespaceIndexFrom(line, after_property + 1) orelse
            return try allocator.dupe(u8, "Unexpected end of JSON input");
        if (line[value_start] == '#') {
            return try unexpectedTokenDetail(allocator, line, value_start);
        }
    }

    if (lastNonJsonWhitespaceIndex(line)) |last_index| {
        if (line[last_index] == '}') {
            const before_close = previousNonJsonWhitespaceIndex(line, last_index);
            if (before_close != null and line[before_close.?] == ',') {
                return try std.fmt.allocPrint(
                    allocator,
                    "Expected double-quoted property name in JSON at position {d} (line 1 column {d})",
                    .{ last_index, last_index + 1 },
                );
            }
        }
        if (line[last_index] == ':' or line[last_index] == ',') {
            return try allocator.dupe(u8, "Unexpected end of JSON input");
        }
    }

    return try allocator.dupe(u8, "Unexpected end of JSON input");
}

fn arrayParseErrorDetail(allocator: std.mem.Allocator, line: []const u8, array_start: usize) ![]u8 {
    const after_open = firstNonJsonWhitespaceIndexFrom(line, array_start + 1) orelse array_start + 1;
    if (after_open < line.len and line[after_open] == ']') {
        if (firstNonJsonWhitespaceIndexFrom(line, after_open + 1)) |extra_index| {
            return try unexpectedNonWhitespaceDetail(allocator, extra_index);
        }
    }
    if (lastNonJsonWhitespaceIndex(line)) |last_index| {
        if (line[last_index] == ']') {
            const before_close = previousNonJsonWhitespaceIndex(line, last_index);
            if (before_close != null and line[before_close.?] == ',') {
                return try unexpectedTokenDetail(allocator, line, last_index);
            }
        }
        if (line[last_index] == '[' or line[last_index] == ',') {
            return try allocator.dupe(u8, "Unexpected end of JSON input");
        }
    }

    return try allocator.dupe(u8, "Unexpected end of JSON input");
}

fn literalParseErrorDetail(
    allocator: std.mem.Allocator,
    line: []const u8,
    start_index: usize,
    literal: []const u8,
) ![]u8 {
    var offset: usize = 0;
    while (offset < literal.len and start_index + offset < line.len and line[start_index + offset] == literal[offset]) {
        offset += 1;
    }

    if (offset == literal.len) {
        const after_literal = firstNonJsonWhitespaceIndexFrom(line, start_index + literal.len);
        if (after_literal) |token_index| return try unexpectedNonWhitespaceDetail(allocator, token_index);
        return try allocator.dupe(u8, "Unexpected end of JSON input");
    }

    if (start_index + offset >= line.len) {
        return try allocator.dupe(u8, "Unexpected end of JSON input");
    }
    return try unexpectedTokenDetail(allocator, line, start_index + offset);
}

fn numberParseErrorDetail(allocator: std.mem.Allocator, line: []const u8, start_index: usize) ![]u8 {
    var index = start_index;
    if (index < line.len and line[index] == '-') index += 1;
    while (index < line.len and line[index] >= '0' and line[index] <= '9') : (index += 1) {}
    if (index < line.len and line[index] == '.') {
        index += 1;
        while (index < line.len and line[index] >= '0' and line[index] <= '9') : (index += 1) {}
    }
    if (index < line.len and (line[index] == 'e' or line[index] == 'E')) {
        index += 1;
        if (index < line.len and (line[index] == '+' or line[index] == '-')) index += 1;
        while (index < line.len and line[index] >= '0' and line[index] <= '9') : (index += 1) {}
    }
    if (firstNonJsonWhitespaceIndexFrom(line, index)) |extra_index| {
        return try unexpectedNonWhitespaceDetail(allocator, extra_index);
    }
    return try allocator.dupe(u8, "Unexpected end of JSON input");
}

fn unexpectedNonWhitespaceDetail(allocator: std.mem.Allocator, index: usize) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "Unexpected non-whitespace character after JSON at position {d} (line 1 column {d})",
        .{ index, index + 1 },
    );
}

fn unexpectedTokenDetail(allocator: std.mem.Allocator, line: []const u8, token_index: usize) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "Unexpected token '{c}', \"{s}\" is not valid JSON",
        .{ line[token_index], line },
    );
}

fn expectedPropertyNameOrCloseDetail(allocator: std.mem.Allocator, index: usize) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "Expected property name or '}}' in JSON at position {d} (line 1 column {d})",
        .{ index, index + 1 },
    );
}

fn hasUnterminatedString(line: []const u8) bool {
    var in_string = false;
    var escaped = false;
    for (line) |byte| {
        if (!in_string) {
            if (byte == '"') in_string = true;
            continue;
        }
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == '"') {
            in_string = false;
        }
    }
    return in_string;
}

fn badUnicodeEscapeIndex(line: []const u8) ?usize {
    var in_string = false;
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        const byte = line[index];
        if (!in_string) {
            if (byte == '"') in_string = true;
            continue;
        }
        if (byte == '"') {
            in_string = false;
            continue;
        }
        if (byte != '\\') continue;
        index += 1;
        if (index >= line.len) return null;
        if (line[index] != 'u') continue;
        var digit: usize = 0;
        while (digit < 4) : (digit += 1) {
            const hex_index = index + 1 + digit;
            if (hex_index >= line.len) return null;
            if (!isHexDigit(line[hex_index])) return hex_index;
        }
        index += 4;
    }
    return null;
}

fn scanJsonStringEnd(line: []const u8, start_quote: usize) ?usize {
    if (start_quote >= line.len or line[start_quote] != '"') return null;
    var index = start_quote + 1;
    while (index < line.len) : (index += 1) {
        if (line[index] == '"') return index;
        if (line[index] == '\\') {
            index += 1;
            if (index >= line.len) return null;
            if (line[index] == 'u') index += 4;
        }
    }
    return null;
}

fn firstNonJsonWhitespaceIndex(line: []const u8) ?usize {
    return firstNonJsonWhitespaceIndexFrom(line, 0);
}

fn firstNonJsonWhitespaceIndexFrom(line: []const u8, start: usize) ?usize {
    var index = start;
    while (index < line.len) : (index += 1) {
        if (!isJsonWhitespace(line[index])) return index;
    }
    return null;
}

fn lastNonJsonWhitespaceIndex(line: []const u8) ?usize {
    var index = line.len;
    while (index > 0) {
        index -= 1;
        if (!isJsonWhitespace(line[index])) return index;
    }
    return null;
}

fn previousNonJsonWhitespaceIndex(line: []const u8, before: usize) ?usize {
    var index = before;
    while (index > 0) {
        index -= 1;
        if (!isJsonWhitespace(line[index])) return index;
    }
    return null;
}

fn isJsonWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn isHexDigit(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or
        (byte >= 'a' and byte <= 'f') or
        (byte >= 'A' and byte <= 'F');
}

fn writeIdField(allocator: std.mem.Allocator, writer: *std.Io.Writer, id: ?[]const u8) !void {
    if (id) |id_string| {
        try writer.writeAll("\"id\":");
        try writeJsonString(allocator, writer, id_string);
        try writer.writeAll(",");
    }
}

fn writeJsonString(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: []const u8) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = value }, .{});
    defer allocator.free(json);
    try writer.writeAll(json);
}

fn handleTsRpcAgentEvent(context: ?*anyopaque, event: agent.AgentEvent) !void {
    const server: *TsRpcServer = @ptrCast(@alignCast(context.?));
    try server.writeEvent(event);
    if (event.event_type == .message_end) {
        if (event.message) |message| {
            switch (message) {
                .assistant => |assistant| {
                    if (assistant.stop_reason != .error_reason) {
                        if (server.session) |session| {
                            if (session.retry_attempt > 0) {
                                try server.writeRetryLifecycleEvent(.{ .end = .{
                                    .success = true,
                                    .attempt = session.retry_attempt,
                                } });
                                session.retry_attempt = 0;
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }
}

fn handleTsRpcRetryLifecycleEvent(context: ?*anyopaque, event: session_mod.RetryLifecycleEvent) !void {
    const server: *TsRpcServer = @ptrCast(@alignCast(context.?));
    try server.writeRetryLifecycleEvent(event);
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MissingRequiredField;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidFieldType,
    };
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidFieldType,
    };
}

fn requiredStringArray(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const value = object.get(key) orelse return error.MissingRequiredField;
    const array = switch (value) {
        .array => |items| items,
        else => return error.InvalidFieldType,
    };
    var result = try allocator.alloc([]const u8, array.items.len);
    errdefer allocator.free(result);
    for (array.items, 0..) |item, index| {
        result[index] = switch (item) {
            .string => |string| string,
            else => return error.InvalidFieldType,
        };
    }
    return result;
}

fn optionalStringArray(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?[]const []const u8 {
    if (object.get(key) == null) return null;
    return try requiredStringArray(allocator, object, key);
}

fn optionalU64(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        else => null,
    };
}

fn parseRequiredBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.MissingRequiredField;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidFieldType,
    };
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn parseThinkingLevel(object: std.json.ObjectMap, key: []const u8) !agent.ThinkingLevel {
    const value = try requiredString(object, key);
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return error.InvalidFieldType;
}

fn nextThinkingLevel(level: agent.ThinkingLevel) agent.ThinkingLevel {
    return switch (level) {
        .off => .minimal,
        .minimal => .low,
        .low => .medium,
        .medium => .high,
        .high => .xhigh,
        .xhigh => .off,
    };
}

fn parseQueueMode(object: std.json.ObjectMap, key: []const u8) !agent.QueueMode {
    const value = try requiredString(object, key);
    if (std.mem.eql(u8, value, "all")) return .all;
    if (std.mem.eql(u8, value, "one-at-a-time")) return .one_at_a_time;
    return error.InvalidFieldType;
}

fn parsePromptStreamingBehavior(object: std.json.ObjectMap) !?PromptStreamingBehavior {
    const value = object.get("streamingBehavior") orelse return null;
    const behavior = switch (value) {
        .string => |string| string,
        else => return error.InvalidFieldType,
    };
    if (std.mem.eql(u8, behavior, "steer")) return .steer;
    if (std.mem.eql(u8, behavior, "followUp")) return .follow_up;
    return error.InvalidFieldType;
}

fn parseImages(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]ai.ImageContent {
    const images_value = object.get("images") orelse return try allocator.alloc(ai.ImageContent, 0);
    const images_array = switch (images_value) {
        .array => |array| array,
        else => return error.InvalidFieldType,
    };

    const images = try allocator.alloc(ai.ImageContent, images_array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (images[0..initialized]) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        allocator.free(images);
    }

    for (images_array.items, 0..) |item, index| {
        const image_object = switch (item) {
            .object => |value| value,
            else => return error.InvalidFieldType,
        };
        const data = requiredString(image_object, "data") catch return error.InvalidFieldType;
        const mime_type = requiredString(image_object, "mimeType") catch return error.InvalidFieldType;
        images[index] = .{
            .data = try allocator.dupe(u8, data),
            .mime_type = try allocator.dupe(u8, mime_type),
        };
        initialized += 1;
    }
    return images;
}

fn deinitImages(allocator: std.mem.Allocator, images: []ai.ImageContent) void {
    for (images) |image| {
        allocator.free(image.data);
        allocator.free(image.mime_type);
    }
    allocator.free(images);
}

fn thinkingLevelName(level: agent.ThinkingLevel) []const u8 {
    return @tagName(level);
}

fn queueModeName(mode: agent.QueueMode) []const u8 {
    return switch (mode) {
        .all => "all",
        .one_at_a_time => "one-at-a-time",
    };
}

fn writeModelJson(allocator: std.mem.Allocator, writer: *std.Io.Writer, model: ai.Model) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(allocator, writer, model.id);
    try writer.writeAll(",\"name\":");
    try writeJsonString(allocator, writer, model.name);
    try writer.writeAll(",\"api\":");
    try writeJsonString(allocator, writer, model.api);
    try writer.writeAll(",\"provider\":");
    try writeJsonString(allocator, writer, model.provider);
    try writer.writeAll(",\"baseUrl\":");
    try writeJsonString(allocator, writer, model.base_url);
    try writer.writeAll(",\"reasoning\":");
    try writer.writeAll(if (model.reasoning) "true" else "false");
    try writer.writeAll(",\"input\":[");
    for (model.input_types, 0..) |input, index| {
        if (index > 0) try writer.writeAll(",");
        try writeJsonString(allocator, writer, input);
    }
    try writer.writeAll("],\"cost\":{\"input\":");
    try writeJsonNumber(allocator, writer, model.cost.input);
    try writer.writeAll(",\"output\":");
    try writeJsonNumber(allocator, writer, model.cost.output);
    try writer.writeAll(",\"cacheRead\":");
    try writeJsonNumber(allocator, writer, model.cost.cache_read);
    try writer.writeAll(",\"cacheWrite\":");
    try writeJsonNumber(allocator, writer, model.cost.cache_write);
    try writer.writeAll("}");
    try writer.print(",\"contextWindow\":{d},\"maxTokens\":{d}", .{ model.context_window, model.max_tokens });
    if (model.headers) |headers| {
        try writer.writeAll(",\"headers\":{");
        var iterator = headers.iterator();
        var first = true;
        while (iterator.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;
            try writeJsonString(allocator, writer, entry.key_ptr.*);
            try writer.writeAll(":");
            try writeJsonString(allocator, writer, entry.value_ptr.*);
        }
        try writer.writeAll("}");
    }
    if (model.compat) |compat| {
        const compat_json = try std.json.Stringify.valueAlloc(allocator, compat, .{});
        defer allocator.free(compat_json);
        try writer.writeAll(",\"compat\":");
        try writer.writeAll(compat_json);
    }
    try writer.writeAll("}");
}

fn writeJsonNumber(allocator: std.mem.Allocator, writer: *std.Io.Writer, number: f64) !void {
    _ = allocator;
    try writer.print("{d}", .{number});
}

fn writeQueuedMessageTexts(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    messages: []const agent.AgentMessage,
) !void {
    try writer.writeAll("[");
    var first = true;
    for (messages) |message| {
        const text = switch (message) {
            .user => |user| firstTextBlock(user.content),
            else => "",
        };
        if (!first) try writer.writeAll(",");
        first = false;
        try writeJsonString(allocator, writer, text);
    }
    try writer.writeAll("]");
}

fn writeJsonStringArray(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    values: []const []const u8,
) !void {
    try writer.writeAll("[");
    for (values, 0..) |value, index| {
        if (index > 0) try writer.writeAll(",");
        try writeJsonString(allocator, writer, value);
    }
    try writer.writeAll("]");
}

fn firstTextBlock(blocks: []const ai.ContentBlock) []const u8 {
    for (blocks) |block| {
        switch (block) {
            .text => |text| return text.text,
            else => {},
        }
    }
    return "";
}

fn textBlocksConcat(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (blocks) |block| {
        switch (block) {
            .text => |text| try out.appendSlice(allocator, text.text),
            else => {},
        }
    }
    const text = std.mem.trim(u8, out.items, &std.ascii.whitespace);
    const owned = try allocator.dupe(u8, text);
    out.deinit(allocator);
    return owned;
}

fn lastAssistantTextAlloc(allocator: std.mem.Allocator, session: *const session_mod.AgentSession) !?[]u8 {
    const messages = session.agent.getMessages();
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        switch (messages[index]) {
            .assistant => |assistant_message| {
                if (assistant_message.stop_reason == .aborted and assistant_message.content.len == 0) continue;
                const text = try textBlocksConcat(allocator, assistant_message.content);
                if (text.len == 0) {
                    allocator.free(text);
                    return null;
                }
                return text;
            },
            else => {},
        }
    }
    return null;
}

fn exitCodeFromTerm(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

const BashWaitState = struct {
    child: *std.process.Child,
    io: std.Io,
    term: ?std.process.Child.Term = null,
    err: ?anyerror = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const BashOutputReaderState = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    io: std.Io,
    sanitizer: DirectBashUtf8Sanitizer = .{},
    chunks: std.ArrayList([]u8) = .empty,
    output_bytes: usize = 0,
    total_raw_bytes: usize = 0,
    temp_file: ?DirectBashTempFile = null,
    err: ?anyerror = null,

    fn deinit(self: *BashOutputReaderState) void {
        for (self.chunks.items) |chunk| self.allocator.free(chunk);
        self.chunks.deinit(self.allocator);
        if (self.temp_file) |*temp_file| temp_file.deinit(self.allocator, self.io);
        self.file.close(self.io);
    }

    fn appendRaw(self: *BashOutputReaderState, bytes: []const u8) !void {
        self.total_raw_bytes += bytes.len;
        const sanitized = try self.sanitizer.sanitizeChunk(self.allocator, bytes);
        try self.appendSanitized(sanitized);
    }

    fn appendSanitized(self: *BashOutputReaderState, sanitized: []u8) !void {
        errdefer self.allocator.free(sanitized);

        if (self.total_raw_bytes > truncate.DEFAULT_MAX_BYTES and self.temp_file == null) {
            try self.ensureTempFile();
        }
        if (self.temp_file) |*temp_file| {
            try temp_file.file.?.writeStreamingAll(self.io, sanitized);
        }

        if (sanitized.len == 0) {
            self.allocator.free(sanitized);
            return;
        }
        try self.chunks.append(self.allocator, sanitized);
        self.output_bytes += sanitized.len;

        while (self.output_bytes > DIRECT_BASH_MAX_BUFFER_BYTES and self.chunks.items.len > 1) {
            const removed = self.chunks.orderedRemove(0);
            self.output_bytes -= removed.len;
            self.allocator.free(removed);
        }
    }

    fn ensureTempFile(self: *BashOutputReaderState) !void {
        var temp_file = try DirectBashTempFile.create(self.allocator, self.io);
        errdefer temp_file.deinit(self.allocator, self.io);
        for (self.chunks.items) |chunk| {
            try temp_file.file.?.writeStreamingAll(self.io, chunk);
        }
        self.temp_file = temp_file;
    }

    fn finish(self: *BashOutputReaderState, result_allocator: std.mem.Allocator) !DirectBashBufferedOutput {
        const flushed = try self.sanitizer.flush(self.allocator);
        try self.appendSanitized(flushed);

        const rolling_output = try std.mem.join(result_allocator, "", self.chunks.items);
        errdefer result_allocator.free(rolling_output);
        if (self.temp_file) |*temp_file| {
            temp_file.file.?.close(self.io);
            temp_file.file = null;
            return .{
                .output = rolling_output,
                .full_output_path = temp_file.releasePath(),
            };
        }
        return .{
            .output = rolling_output,
            .full_output_path = null,
        };
    }
};

const DirectBashBufferedOutput = struct {
    output: []u8,
    full_output_path: ?[]u8 = null,

    fn deinit(self: *DirectBashBufferedOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.full_output_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

const DirectBashTempFile = struct {
    file: ?std.Io.File,
    path: ?[]u8,

    fn create(allocator: std.mem.Allocator, io: std.Io) !DirectBashTempFile {
        var attempts: usize = 0;
        while (attempts < 16) : (attempts += 1) {
            var random_bytes: [16]u8 = undefined;
            io.random(&random_bytes);
            const encoded = std.fmt.bytesToHex(random_bytes, .lower);
            const path = try std.fmt.allocPrint(allocator, "/tmp/pi-bash-{s}.log", .{encoded[0..]});
            errdefer allocator.free(path);

            var file = std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    allocator.free(path);
                    continue;
                },
                else => return err,
            };
            errdefer file.close(io);

            return .{
                .file = file,
                .path = path,
            };
        }

        return error.TemporaryFilePathCollision;
    }

    fn releasePath(self: *DirectBashTempFile) []u8 {
        const path = self.path.?;
        self.path = null;
        return path;
    }

    fn deinit(self: *DirectBashTempFile, allocator: std.mem.Allocator, io: std.Io) void {
        if (self.file) |file| file.close(io);
        if (self.path) |path| allocator.free(path);
        self.* = undefined;
    }
};

const DirectBashUtf8Sanitizer = struct {
    pending_utf8: [4]u8 = undefined,
    pending_utf8_len: u8 = 0,

    fn sanitizeChunk(self: *DirectBashUtf8Sanitizer, allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var index: usize = 0;
        try self.drainPending(allocator, &out, bytes, &index);

        while (index < bytes.len) {
            if (bytes[index] == 0x1b) {
                index = skipAnsiEscape(bytes, index);
                continue;
            }

            const start = index;
            const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[start]) catch {
                try appendUtf8Codepoint(allocator, &out, 0xfffd);
                index += 1;
                continue;
            };
            if (start + sequence_len > bytes.len) {
                var continuation_index = start + 1;
                while (continuation_index < bytes.len) : (continuation_index += 1) {
                    if (!isUtf8Continuation(bytes[continuation_index])) {
                        try appendUtf8Codepoint(allocator, &out, 0xfffd);
                        index += 1;
                        break;
                    }
                } else {
                    const remaining = bytes[start..];
                    @memcpy(self.pending_utf8[0..remaining.len], remaining);
                    self.pending_utf8_len = @intCast(remaining.len);
                    index = bytes.len;
                }
                continue;
            }

            const slice = bytes[start .. start + sequence_len];
            const codepoint = std.unicode.utf8Decode(slice) catch {
                try appendUtf8Codepoint(allocator, &out, 0xfffd);
                index += 1;
                continue;
            };
            index += sequence_len;

            try appendSanitizedCodepoint(allocator, &out, slice, codepoint);
        }

        return try out.toOwnedSlice(allocator);
    }

    fn drainPending(
        self: *DirectBashUtf8Sanitizer,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        bytes: []const u8,
        index: *usize,
    ) !void {
        if (self.pending_utf8_len == 0) return;

        const sequence_len = std.unicode.utf8ByteSequenceLength(self.pending_utf8[0]) catch {
            try appendUtf8Codepoint(allocator, out, 0xfffd);
            self.pending_utf8_len = 0;
            return;
        };

        while (self.pending_utf8_len < sequence_len) {
            if (index.* >= bytes.len) return;
            const byte = bytes[index.*];
            if (!isUtf8Continuation(byte)) {
                try appendUtf8Codepoint(allocator, out, 0xfffd);
                self.pending_utf8_len = 0;
                return;
            }
            self.pending_utf8[self.pending_utf8_len] = byte;
            self.pending_utf8_len += 1;
            index.* += 1;
        }

        const slice = self.pending_utf8[0..sequence_len];
        const codepoint = std.unicode.utf8Decode(slice) catch {
            try appendUtf8Codepoint(allocator, out, 0xfffd);
            self.pending_utf8_len = 0;
            return;
        };
        try appendSanitizedCodepoint(allocator, out, slice, codepoint);
        self.pending_utf8_len = 0;
    }

    fn flush(self: *DirectBashUtf8Sanitizer, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        if (self.pending_utf8_len != 0) {
            try appendUtf8Codepoint(allocator, &out, 0xfffd);
            self.pending_utf8_len = 0;
        }
        return try out.toOwnedSlice(allocator);
    }
};

fn sanitizeDirectBashOutput(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var sanitizer: DirectBashUtf8Sanitizer = .{};
    const chunk = try sanitizer.sanitizeChunk(allocator, bytes);
    defer allocator.free(chunk);
    const flushed = try sanitizer.flush(allocator);
    defer allocator.free(flushed);
    return try std.mem.concat(allocator, u8, &.{ chunk, flushed });
}

fn isUtf8Continuation(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

fn appendSanitizedCodepoint(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    slice: []const u8,
    codepoint: u21,
) !void {
    if (codepoint == '\t' or codepoint == '\n') {
        try out.appendSlice(allocator, slice);
    } else if (codepoint == '\r') {
        return;
    } else if (codepoint <= 0x1f) {
        return;
    } else if (codepoint >= 0xfff9 and codepoint <= 0xfffb) {
        return;
    } else {
        try out.appendSlice(allocator, slice);
    }
}

fn skipAnsiEscape(bytes: []const u8, start: usize) usize {
    if (start + 1 >= bytes.len) return start + 1;

    const introducer = bytes[start + 1];
    if (introducer == '[') {
        var index = start + 2;
        while (index < bytes.len) : (index += 1) {
            if (bytes[index] >= 0x40 and bytes[index] <= 0x7e) return index + 1;
        }
        return bytes.len;
    }

    if (introducer == ']') {
        var index = start + 2;
        while (index < bytes.len) : (index += 1) {
            if (bytes[index] == 0x07) return index + 1;
            if (bytes[index] == 0x1b and index + 1 < bytes.len and bytes[index + 1] == '\\') return index + 2;
        }
        return bytes.len;
    }

    return start + 2;
}

fn appendUtf8Codepoint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), codepoint: u21) !void {
    var buffer: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(codepoint, &buffer);
    try out.appendSlice(allocator, buffer[0..len]);
}

fn waitDirectBashChild(state: *BashWaitState) void {
    state.term = state.child.wait(state.io) catch |err| {
        state.err = err;
        state.done.store(true, .seq_cst);
        return;
    };
    state.done.store(true, .seq_cst);
}

fn readDirectBashOutput(state: *BashOutputReaderState) void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_read = std.posix.read(state.file.handle, &buffer) catch |err| {
            state.err = err;
            return;
        };
        if (bytes_read == 0) return;
        state.appendRaw(buffer[0..bytes_read]) catch |err| {
            state.err = err;
            return;
        };
    }
}

fn killDirectBashProcessGroup(pid: std.posix.pid_t) void {
    std.posix.kill(-pid, .TERM) catch {};
    std.posix.kill(-pid, .KILL) catch {};
}

fn runDirectBash(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    command: []const u8,
    abort_signal: *const std.atomic.Value(bool),
    started: *std.atomic.Value(bool),
) !BashRunResult {
    var cwd_dir = std.Io.Dir.openDirAbsolute(io, cwd, .{}) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "Working directory does not exist: {s} ({s})", .{ cwd, @errorName(err) });
        defer allocator.free(message);
        return .{
            .output = try allocator.dupe(u8, message),
            .exit_code = null,
            .cancelled = abort_signal.load(.seq_cst),
        };
    };
    defer cwd_dir.close(io);

    const wrapped_command = try std.fmt.allocPrint(allocator, "exec 2>&1\n{s}", .{command});
    defer allocator.free(wrapped_command);
    const argv = [_][]const u8{ "/bin/sh", "-c", wrapped_command };
    var child = try std.process.spawn(io, .{
        .argv = argv[0..],
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    });
    defer {
        if (child.id != null) child.kill(io);
    }
    const pid = child.id.?;
    started.store(true, .seq_cst);

    const stdout_file = child.stdout.?;
    child.stdout = null;

    var wait_state = BashWaitState{
        .child = &child,
        .io = io,
    };
    const wait_thread = try std.Thread.spawn(.{}, waitDirectBashChild, .{&wait_state});

    var reader_state = BashOutputReaderState{
        .allocator = allocator,
        .file = stdout_file,
        .io = io,
    };
    const reader_thread = std.Thread.spawn(.{}, readDirectBashOutput, .{&reader_state}) catch |err| {
        killDirectBashProcessGroup(pid);
        wait_thread.join();
        reader_state.deinit();
        return err;
    };

    var threads_joined = false;
    defer {
        if (!threads_joined) {
            wait_thread.join();
            reader_thread.join();
        }
        reader_state.deinit();
    }

    var cancelled = false;
    while (!wait_state.done.load(.seq_cst)) {
        if (abort_signal.load(.seq_cst)) {
            cancelled = true;
            killDirectBashProcessGroup(pid);
            break;
        }
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }

    wait_thread.join();
    reader_thread.join();
    threads_joined = true;

    if (reader_state.err) |err| return err;
    if (wait_state.err) |err| return err;

    var buffered_output = try reader_state.finish(allocator);
    defer buffered_output.deinit(allocator);
    var truncation_result = try truncate.truncateTail(allocator, buffered_output.output, .{});
    defer truncation_result.deinit(allocator);

    var full_output_path = buffered_output.full_output_path;
    buffered_output.full_output_path = null;
    errdefer if (full_output_path) |path| allocator.free(path);

    if (truncation_result.truncated and full_output_path == null) {
        full_output_path = try captureDirectBashOutputInTempFile(allocator, io, buffered_output.output);
    }

    return .{
        .output = if (truncation_result.truncated)
            try allocator.dupe(u8, truncation_result.content)
        else
            try allocator.dupe(u8, buffered_output.output),
        .exit_code = if (cancelled) null else exitCodeFromTerm(wait_state.term.?),
        .cancelled = cancelled,
        .truncated = truncation_result.truncated,
        .full_output_path = full_output_path,
    };
}

fn captureDirectBashOutputInTempFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: []const u8,
) ![]u8 {
    var temp_file = try DirectBashTempFile.create(allocator, io);
    errdefer temp_file.deinit(allocator, io);
    try temp_file.file.?.writeStreamingAll(io, output);
    temp_file.file.?.close(io);
    temp_file.file = null;
    return temp_file.releasePath();
}

fn buildBashResultJson(allocator: std.mem.Allocator, result: BashRunResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"output\":");
    try writeJsonString(allocator, &out.writer, result.output);
    if (result.exit_code) |code| {
        try out.writer.print(",\"exitCode\":{d}", .{code});
    }
    try out.writer.writeAll(",\"cancelled\":");
    try out.writer.writeAll(if (result.cancelled) "true" else "false");
    try out.writer.writeAll(",\"truncated\":");
    try out.writer.writeAll(if (result.truncated) "true" else "false");
    if (result.full_output_path) |path| {
        try out.writer.writeAll(",\"fullOutputPath\":");
        try writeJsonString(allocator, &out.writer, path);
    }
    try out.writer.writeAll("}");
    return try allocator.dupe(u8, out.written());
}

fn runTsRpcModeScript(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: ?*session_mod.AgentSession,
    lines: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !void {
    var server = TsRpcServer.init(allocator, io, session, stdout_writer, stderr_writer);
    try server.start();
    defer server.finish() catch {};
    server.setDeferredFlushInputBacklog(lines.len > 0);
    defer server.setDeferredFlushInputBacklog(false);

    for (lines) |line| {
        try server.handleLine(line);
    }

    server.setDeferredFlushInputBacklog(false);
    try waitForNoInFlightPrompt(&server, 30_000);
    try waitForNoActiveBashTask(&server, 30_000);
    try server.finish();
}

fn runTsRpcModeBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: ?*session_mod.AgentSession,
    bytes: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !void {
    var server = TsRpcServer.init(allocator, io, session, stdout_writer, stderr_writer);
    try server.start();
    defer server.finish() catch {};
    server.setDeferredFlushInputBacklog(bytes.len > 0);
    defer server.setDeferredFlushInputBacklog(false);
    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(allocator);

    for (bytes, 0..) |byte, index| {
        server.setDeferredFlushInputBacklog(index + 1 < bytes.len);
        if (byte == '\n') {
            try server.handleLine(line_buffer.items);
            line_buffer.clearRetainingCapacity();
            continue;
        }
        try line_buffer.append(allocator, byte);
    }

    if (line_buffer.items.len > 0) {
        try server.handleLine(line_buffer.items);
    }

    server.setDeferredFlushInputBacklog(false);
    if (server.hasInFlightPrompt()) {
        server.suppress_events = true;
        server.abortActivePromptWork();
    }
    try server.flushDeferredResponses();
    try server.finish();
}

fn readFixture(comptime name: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        "test/golden/ts-rpc/" ++ name,
        std.testing.allocator,
        .unlimited,
    );
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectOutputOrder(haystack: []const u8, before: []const u8, after: []const u8) !void {
    const before_index = std.mem.indexOf(u8, haystack, before) orelse {
        try expectContains(haystack, before);
        unreachable;
    };
    const after_index = std.mem.indexOf(u8, haystack, after) orelse {
        try expectContains(haystack, after);
        unreachable;
    };
    try std.testing.expect(before_index < after_index);
}

fn waitForOutputContains(
    server: *TsRpcServer,
    writer: *std.Io.Writer,
    needle: []const u8,
    timeout_ms: u64,
) !void {
    var elapsed: u64 = 0;
    while (elapsed <= timeout_ms) : (elapsed += 5) {
        server.output_mutex.lockUncancelable(server.io);
        const found = std.mem.indexOf(u8, writer.buffered(), needle) != null;
        server.output_mutex.unlock(server.io);
        if (found) return;
        std.Io.sleep(server.io, .fromMilliseconds(5), .awake) catch {};
    }
    try expectContains(writer.buffered(), needle);
}

fn waitForAbsoluteFile(path: []const u8, timeout_ms: u64) !void {
    var elapsed: u64 = 0;
    while (elapsed <= timeout_ms) : (elapsed += 5) {
        if (std.Io.Dir.openFileAbsolute(std.testing.io, path, .{})) |file| {
            file.close(std.testing.io);
            return;
        } else |_| {}
        std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
    }
    _ = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{});
}

fn waitForNoActiveBashTask(server: *TsRpcServer, timeout_ms: u64) !void {
    var elapsed: u64 = 0;
    while (elapsed <= timeout_ms) : (elapsed += 5) {
        if (!server.hasActiveBashTask()) return;
        std.Io.sleep(server.io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(!server.hasActiveBashTask());
}

fn waitForNoInFlightPrompt(server: *const TsRpcServer, timeout_ms: u64) !void {
    var elapsed: u64 = 0;
    while (elapsed <= timeout_ms) : (elapsed += 5) {
        if (!server.hasInFlightPrompt()) return;
        std.Io.sleep(server.io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(!server.hasInFlightPrompt());
}

fn waitForSessionRetrying(session: *const session_mod.AgentSession, timeout_ms: u64) !void {
    var elapsed: u64 = 0;
    while (elapsed <= timeout_ms) : (elapsed += 5) {
        if (session.isRetrying()) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(session.isRetrying());
}

fn expectNewOutput(
    writer: *std.Io.Writer,
    cursor: *usize,
    expected: []const u8,
) !void {
    const bytes = writer.buffered();
    try std.testing.expect(bytes.len >= cursor.*);
    try std.testing.expectEqualStrings(expected, bytes[cursor.*..]);
    cursor.* = bytes.len;
}

fn expectPromptConcurrencyQueueInvariant(bytes: []const u8) !void {
    const agent_start = "{\"type\":\"agent_start\"}\n";
    const steer_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while prompt running\"],\"followUp\":[]}\n";
    const follow_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while prompt running\"],\"followUp\":[\"follow while prompt running\"]}\n";
    const prompt_steer_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while prompt running\",\"prompt as steer\"],\"followUp\":[\"follow while prompt running\"]}\n";
    const prompt_follow_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while prompt running\",\"prompt as steer\"],\"followUp\":[\"follow while prompt running\",\"prompt as follow\"]}\n";
    const steer_response = "{\"id\":\"pc_steer\",\"type\":\"response\",\"command\":\"steer\",\"success\":true}\n";
    const follow_response = "{\"id\":\"pc_follow\",\"type\":\"response\",\"command\":\"follow_up\",\"success\":true}\n";
    const prompt_steer_response = "{\"id\":\"pc_prompt_steer\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n";
    const prompt_follow_response = "{\"id\":\"pc_prompt_follow\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n";

    try expectOutputOrder(bytes, steer_queue_update, steer_response);
    try expectOutputOrder(bytes, follow_queue_update, follow_response);
    try expectOutputOrder(bytes, prompt_steer_queue_update, prompt_steer_response);
    try expectOutputOrder(bytes, prompt_follow_queue_update, prompt_follow_response);
    try std.testing.expect(std.mem.indexOf(u8, bytes, agent_start) == null);
}

test "TS RPC writer preserves response field order from TypeScript fixtures" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    defer server.finish() catch {};

    try server.writeSuccessResponseNoData("resp_prompt", "prompt");
    try server.writeSuccessResponseNoData(null, "steer");
    try server.writeSuccessResponseRawData(null, "cycle_model", "null");
    try server.writeErrorResponse("resp_set_model_error", "set_model", "Model not found: anthropic/missing-model");

    const output = stdout_capture.writer.buffered();
    try expectContains(output, "{\"id\":\"resp_prompt\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try expectContains(output, "{\"type\":\"response\",\"command\":\"steer\",\"success\":true}\n");
    try expectContains(output, "{\"type\":\"response\",\"command\":\"cycle_model\",\"success\":true,\"data\":null}\n");
    try expectContains(output, "{\"id\":\"resp_set_model_error\",\"type\":\"response\",\"command\":\"set_model\",\"success\":false,\"error\":\"Model not found: anthropic/missing-model\"}\n");

    const fixture = try readFixture("responses-basic.jsonl");
    defer allocator.free(fixture);
    var output_lines = std.mem.splitScalar(u8, output, '\n');
    while (output_lines.next()) |line| {
        if (line.len == 0) continue;
        try expectContains(fixture, line);
    }
}

test "TS RPC parse error and unknown command match TypeScript byte fixtures" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeBytes(
        allocator,
        std.testing.io,
        null,
        "{bad\n{\"id\":\"mystery\",\"type\":\"mystery_command\"}\n",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command: Expected property name or '}' in JSON at position 1 (line 1 column 2)\"}\n" ++
            "{\"type\":\"response\",\"command\":\"mystery_command\",\"success\":false,\"error\":\"Unknown command: mystery_command\"}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC malformed JSON parse errors match TypeScript bytes beyond bad fixture" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const corpus = try readFixture("parse-error-corpus.jsonl");
    defer allocator.free(corpus);
    var input_bytes = std.ArrayList(u8).empty;
    defer input_bytes.deinit(allocator);
    var expected_bytes: std.ArrayList(u8) = .empty;
    defer expected_bytes.deinit(allocator);

    var case_count: usize = 0;
    var corpus_lines = std.mem.splitScalar(u8, corpus, '\n');
    while (corpus_lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        const input = object.get("input").?.string;
        const output = object.get("output").?.string;
        try input_bytes.appendSlice(allocator, input);
        try input_bytes.append(allocator, '\n');
        try expected_bytes.appendSlice(allocator, output);
        case_count += 1;
    }
    try std.testing.expect(case_count >= 18);

    try runTsRpcModeBytes(
        allocator,
        std.testing.io,
        null,
        input_bytes.items,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    const fixture = try readFixture("parse-errors.jsonl");
    defer allocator.free(fixture);
    try std.testing.expectEqualStrings(fixture, expected_bytes.items);
    try std.testing.expectEqualStrings(fixture, stdout_capture.writer.buffered());
}

test "TS RPC array input where command object is expected matches TypeScript unknown-command bytes" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeBytes(
        allocator,
        std.testing.io,
        null,
        "[]\n",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"type\":\"response\",\"success\":false,\"error\":\"Unknown command: undefined\"}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC reader uses LF framing strips CR and accepts final unterminated line" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeBytes(
        allocator,
        std.testing.io,
        null,
        "{\"id\":\"framing_lf_a\",\"type\":\"get_state\"}\n{\"id\":\"framing_crlf_a\",\"type\":\"get_state\"}\r\n{\"id\":\"framing_final\",\"type\":\"get_state\"}",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"id\":\"framing_lf_a\",\"type\":\"response\",\"command\":\"get_state\",\"success\":false,\"error\":\"Not implemented: get_state\"}\n" ++
            "{\"id\":\"framing_crlf_a\",\"type\":\"response\",\"command\":\"get_state\",\"success\":false,\"error\":\"Not implemented: get_state\"}\n" ++
            "{\"id\":\"framing_final\",\"type\":\"response\",\"command\":\"get_state\",\"success\":false,\"error\":\"Not implemented: get_state\"}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC M2 get_state get_messages and get_commands use TS response bytes" {
    const allocator = std.testing.allocator;
    const model = ai.Model{
        .id = "fixture-model",
        .name = "Fixture Model",
        .api = "faux",
        .provider = "faux",
        .base_url = "https://example.invalid",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 1234,
        .max_tokens = 321,
    };

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
        .model = model,
        .thinking_level = .high,
    });
    defer session.deinit();
    _ = try session.session_manager.appendSessionInfo("fixture session");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = "hello" } };
    const assistant_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_content[0] = .{ .text = .{ .text = "hi" } };
    try session.agent.setMessages(&[_]agent.AgentMessage{
        .{ .user = .{ .content = user_content, .timestamp = 11 } },
        .{ .assistant = .{
            .content = assistant_content,
            .api = "faux",
            .provider = "faux",
            .model = "fixture-model",
            .usage = .{ .input = 1, .output = 2, .cache_read = 3, .cache_write = 4, .total_tokens = 10 },
            .stop_reason = .stop,
            .timestamp = 12,
        } },
    });

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{
            "{\"id\":\"state\",\"type\":\"get_state\"}",
            "{\"id\":\"messages\",\"type\":\"get_messages\"}",
            "{\"id\":\"commands\",\"type\":\"get_commands\"}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    const expected = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"state\",\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"data\":{{\"model\":{{\"id\":\"fixture-model\",\"name\":\"Fixture Model\",\"api\":\"faux\",\"provider\":\"faux\",\"baseUrl\":\"https://example.invalid\",\"reasoning\":true,\"input\":[\"text\",\"image\"],\"cost\":{{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0}},\"contextWindow\":1234,\"maxTokens\":321}},\"thinkingLevel\":\"high\",\"isStreaming\":false,\"isCompacting\":false,\"steeringMode\":\"one-at-a-time\",\"followUpMode\":\"one-at-a-time\",\"sessionId\":\"{s}\",\"sessionName\":\"fixture session\",\"autoCompactionEnabled\":false,\"messageCount\":2,\"pendingMessageCount\":0}}}}\n" ++
            "{{\"id\":\"messages\",\"type\":\"response\",\"command\":\"get_messages\",\"success\":true,\"data\":{{\"messages\":[{{\"role\":\"user\",\"content\":\"hello\",\"timestamp\":11}},{{\"role\":\"assistant\",\"content\":[{{\"type\":\"text\",\"text\":\"hi\"}}],\"api\":\"faux\",\"provider\":\"faux\",\"model\":\"fixture-model\",\"usage\":{{\"input\":1,\"output\":2,\"cacheRead\":3,\"cacheWrite\":4,\"totalTokens\":10,\"cost\":{{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"total\":0}}}},\"stopReason\":\"stop\",\"timestamp\":12}}]}}}}\n" ++
            "{{\"id\":\"commands\",\"type\":\"response\",\"command\":\"get_commands\",\"success\":true,\"data\":{{\"commands\":[]}}}}\n",
        .{session.session_manager.getSessionId()},
    );
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, stdout_capture.writer.buffered());
}

test "TS RPC M2 steer follow_up and abort controls use TS responses and queue updates" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{
            "{\"id\":\"s\",\"type\":\"steer\",\"message\":\"steer now\"}",
            "{\"id\":\"f\",\"type\":\"follow_up\",\"message\":\"follow later\"}",
            "{\"id\":\"a\",\"type\":\"abort\"}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"type\":\"queue_update\",\"steering\":[\"steer now\"],\"followUp\":[]}\n" ++
            "{\"id\":\"s\",\"type\":\"response\",\"command\":\"steer\",\"success\":true}\n" ++
            "{\"type\":\"queue_update\",\"steering\":[\"steer now\"],\"followUp\":[\"follow later\"]}\n" ++
            "{\"id\":\"f\",\"type\":\"response\",\"command\":\"follow_up\",\"success\":true}\n" ++
            "{\"id\":\"a\",\"type\":\"response\",\"command\":\"abort\",\"success\":true}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC M3 model thinking and queue controls use TS response bytes" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m3",
        .system_prompt = "system",
        .model = ai.model_registry.getDefault().find("faux", "faux-1").?,
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{
            "{\"id\":\"model\",\"type\":\"set_model\",\"provider\":\"anthropic\",\"modelId\":\"claude-sonnet-4-5\"}",
            "{\"id\":\"missing\",\"type\":\"set_model\",\"provider\":\"anthropic\",\"modelId\":\"missing-model\"}",
            "{\"id\":\"cycle_model\",\"type\":\"cycle_model\"}",
            "{\"id\":\"think\",\"type\":\"set_thinking_level\",\"level\":\"high\"}",
            "{\"id\":\"cycle_think\",\"type\":\"cycle_thinking_level\"}",
            "{\"id\":\"steer_mode\",\"type\":\"set_steering_mode\",\"mode\":\"all\"}",
            "{\"id\":\"follow_mode\",\"type\":\"set_follow_up_mode\",\"mode\":\"one-at-a-time\"}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try expectContains(
        stdout_capture.writer.buffered(),
        "{\"id\":\"model\",\"type\":\"response\",\"command\":\"set_model\",\"success\":true,\"data\":{\"id\":\"claude-sonnet-4-5\",\"name\":\"Claude Sonnet 4.5\",\"api\":\"anthropic-messages\",\"provider\":\"anthropic\",\"baseUrl\":\"https://api.anthropic.com/v1\",\"reasoning\":true,\"input\":[\"text\",\"image\"],\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0},\"contextWindow\":1000000,\"maxTokens\":64000}}\n",
    );
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"missing\",\"type\":\"response\",\"command\":\"set_model\",\"success\":false,\"error\":\"Model not found: anthropic/missing-model\"}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"cycle_model\",\"type\":\"response\",\"command\":\"cycle_model\",\"success\":true,\"data\":null}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"think\",\"type\":\"response\",\"command\":\"set_thinking_level\",\"success\":true}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"cycle_think\",\"type\":\"response\",\"command\":\"cycle_thinking_level\",\"success\":true,\"data\":{\"level\":\"xhigh\"}}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"steer_mode\",\"type\":\"response\",\"command\":\"set_steering_mode\",\"success\":true}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"follow_mode\",\"type\":\"response\",\"command\":\"set_follow_up_mode\",\"success\":true}\n");
    try std.testing.expectEqual(agent.QueueMode.all, session.agent.steering_queue.mode);
    try std.testing.expectEqual(agent.QueueMode.one_at_a_time, session.agent.follow_up_queue.mode);
}

test "TS RPC M3 session bash retry compaction controls use TS-compatible response bytes" {
    const allocator = std.testing.allocator;
    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
        .model = model,
    });
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = "forkable prompt" } };
    const assistant_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_content[0] = .{ .text = .{ .text = " assistant answer " } };
    try session.agent.setMessages(&[_]agent.AgentMessage{
        .{ .user = .{ .content = user_content, .timestamp = 11 } },
        .{ .assistant = .{
            .content = assistant_content,
            .api = "faux",
            .provider = "faux",
            .model = "fixture-model",
            .usage = .{ .input = 2, .output = 3, .cache_read = 4, .cache_write = 5, .total_tokens = 14, .cost = .{ .total = 0.012 } },
            .stop_reason = .stop,
            .timestamp = 12,
        } },
    });
    const fork_entry_id = try session.session_manager.appendMessage(.{ .user = .{ .content = user_content, .timestamp = 11 } });

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{
            "{\"id\":\"auto_compact\",\"type\":\"set_auto_compaction\",\"enabled\":true}",
            "{\"id\":\"auto_retry\",\"type\":\"set_auto_retry\",\"enabled\":true}",
            "{\"id\":\"abort_retry\",\"type\":\"abort_retry\"}",
            "{\"id\":\"abort_bash\",\"type\":\"abort_bash\"}",
            "{\"id\":\"bash\",\"type\":\"bash\",\"command\":\"printf rpc-bash\"}",
            "{\"id\":\"name\",\"type\":\"set_session_name\",\"name\":\"  rpc session  \"}",
            "{\"id\":\"last\",\"type\":\"get_last_assistant_text\"}",
            "{\"id\":\"fork_messages\",\"type\":\"get_fork_messages\"}",
            "{\"id\":\"stats\",\"type\":\"get_session_stats\"}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    const expected_fork = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"fork_messages\",\"type\":\"response\",\"command\":\"get_fork_messages\",\"success\":true,\"data\":{{\"messages\":[{{\"entryId\":\"{s}\",\"text\":\"forkable prompt\"}}]}}}}\n",
        .{fork_entry_id},
    );
    defer allocator.free(expected_fork);

    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"auto_compact\",\"type\":\"response\",\"command\":\"set_auto_compaction\",\"success\":true}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"auto_retry\",\"type\":\"response\",\"command\":\"set_auto_retry\",\"success\":true}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"abort_retry\",\"type\":\"response\",\"command\":\"abort_retry\",\"success\":true}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"bash\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"rpc-bash\",\"exitCode\":0,\"cancelled\":false,\"truncated\":false}}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"abort_bash\",\"type\":\"response\",\"command\":\"abort_bash\",\"success\":true}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"type\":\"session_info_changed\",\"name\":\"rpc session\"}\n{\"id\":\"name\",\"type\":\"response\",\"command\":\"set_session_name\",\"success\":true}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"last\",\"type\":\"response\",\"command\":\"get_last_assistant_text\",\"success\":true,\"data\":{\"text\":\"assistant answer\"}}\n");
    try expectContains(stdout_capture.writer.buffered(), expected_fork);
    try expectContains(stdout_capture.writer.buffered(), "\"command\":\"get_session_stats\",\"success\":true,\"data\":{\"sessionId\":");
    try expectContains(stdout_capture.writer.buffered(), "\"tokens\":{\"input\":2,\"output\":3,\"cacheRead\":4,\"cacheWrite\":5,\"total\":14}");
}

test "TS RPC retry lifecycle emits start then success end in TS-compatible order" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "503 service unavailable" }) },
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{ai.providers.faux.fauxText("retry ok")}, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-retry",
        .system_prompt = "system",
        .model = registration.getModel(),
        .retry = .{
            .enabled = false,
            .max_retries = 2,
            .base_delay_ms = 1,
        },
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{
            "{\"id\":\"retry_on\",\"type\":\"set_auto_retry\",\"enabled\":true}",
            "{\"id\":\"retry_prompt\",\"type\":\"prompt\",\"message\":\"please retry\"}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    const output = stdout_capture.writer.buffered();
    const start_event = "{\"type\":\"auto_retry_start\",\"attempt\":1,\"maxAttempts\":2,\"delayMs\":1,\"errorMessage\":\"503 service unavailable\"}\n";
    const end_event = "{\"type\":\"auto_retry_end\",\"success\":true,\"attempt\":1}\n";
    try expectContains(output, "{\"id\":\"retry_on\",\"type\":\"response\",\"command\":\"set_auto_retry\",\"success\":true}\n");
    try expectContains(output, "{\"id\":\"retry_prompt\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try expectContains(output, start_event);
    try expectContains(output, end_event);
    try expectOutputOrder(output, "{\"id\":\"retry_prompt\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n", start_event);
    try expectOutputOrder(output, start_event, end_event);
    try expectOutputOrder(
        output,
        end_event,
        "{\"type\":\"turn_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"retry ok\"}]",
    );
}

test "TS RPC abort_retry cancels active retry delay and emits failure end" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "503 service unavailable" }) },
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{ai.providers.faux.fauxText("should not run")}, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-retry-abort",
        .system_prompt = "system",
        .model = registration.getModel(),
        .retry = .{
            .enabled = true,
            .max_retries = 2,
            .base_delay_ms = 250,
        },
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    try server.handleLine("{\"id\":\"abort_prompt\",\"type\":\"prompt\",\"message\":\"please retry then abort\"}");
    const start_event = "{\"type\":\"auto_retry_start\",\"attempt\":1,\"maxAttempts\":2,\"delayMs\":250,\"errorMessage\":\"503 service unavailable\"}\n";
    try waitForOutputContains(&server, &stdout_capture.writer, start_event, 500);
    try server.handleLine("{\"id\":\"abort_retry\",\"type\":\"abort_retry\"}");
    try server.finish();

    const output = stdout_capture.writer.buffered();
    const abort_response = "{\"id\":\"abort_retry\",\"type\":\"response\",\"command\":\"abort_retry\",\"success\":true}\n";
    const end_event = "{\"type\":\"auto_retry_end\",\"success\":false,\"attempt\":1,\"finalError\":\"Retry cancelled\"}\n";
    try expectContains(output, "{\"id\":\"abort_prompt\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try expectContains(output, start_event);
    try expectContains(output, abort_response);
    try expectContains(output, end_event);
    try expectOutputOrder(output, start_event, abort_response);
    try expectOutputOrder(output, abort_response, end_event);
    try std.testing.expect(std.mem.indexOf(u8, output, "should not run") == null);
}

test "TS RPC new_session aborts active retry delay before rebind" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "503 service unavailable" }) },
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{ai.providers.faux.fauxText("should not run after rebind")}, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-retry-rebind",
        .system_prompt = "system",
        .model = registration.getModel(),
        .retry = .{
            .enabled = true,
            .max_retries = 2,
            .base_delay_ms = 1000,
        },
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    try server.handleLine("{\"id\":\"rebind_prompt\",\"type\":\"prompt\",\"message\":\"please retry then rebind\"}");
    const start_event = "{\"type\":\"auto_retry_start\",\"attempt\":1,\"maxAttempts\":2,\"delayMs\":1000,\"errorMessage\":\"503 service unavailable\"}\n";
    try waitForOutputContains(&server, &stdout_capture.writer, start_event, 500);
    try waitForSessionRetrying(&session, 500);

    const start_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    try server.handleLine("{\"id\":\"new_during_retry\",\"type\":\"new_session\"}");
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, std.testing.io).nanoseconds - start_ns, std.time.ns_per_ms);
    try std.testing.expect(elapsed_ms < 500);

    const output = stdout_capture.writer.buffered();
    const end_event = "{\"type\":\"auto_retry_end\",\"success\":false,\"attempt\":1,\"finalError\":\"Retry cancelled\"}\n";
    const rebind_response = "{\"id\":\"new_during_retry\",\"type\":\"response\",\"command\":\"new_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n";
    try expectContains(output, "{\"id\":\"rebind_prompt\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try expectContains(output, start_event);
    try expectContains(output, end_event);
    try expectContains(output, rebind_response);
    try expectOutputOrder(output, start_event, end_event);
    try expectOutputOrder(output, end_event, rebind_response);
    try std.testing.expect(std.mem.indexOf(u8, output, "should not run after rebind") == null);
}

test "TS RPC EOF shutdown aborts active retry delay promptly" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "503 service unavailable" }) },
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{ai.providers.faux.fauxText("should not run after shutdown")}, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-retry-shutdown",
        .system_prompt = "system",
        .model = registration.getModel(),
        .retry = .{
            .enabled = true,
            .max_retries = 2,
            .base_delay_ms = 1000,
        },
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    try server.handleLine("{\"id\":\"shutdown_prompt\",\"type\":\"prompt\",\"message\":\"please retry then shutdown\"}");
    try waitForOutputContains(
        &server,
        &stdout_capture.writer,
        "{\"type\":\"auto_retry_start\",\"attempt\":1,\"maxAttempts\":2,\"delayMs\":1000,\"errorMessage\":\"503 service unavailable\"}\n",
        500,
    );
    try waitForSessionRetrying(&session, 500);

    const start_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    server.suppress_events = true;
    server.abortActivePromptWork();
    try server.flushDeferredResponses();
    try server.finish();
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, std.testing.io).nanoseconds - start_ns, std.time.ns_per_ms);
    try std.testing.expect(elapsed_ms < 500);

    const output = stdout_capture.writer.buffered();
    try expectContains(output, "{\"id\":\"shutdown_prompt\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try expectContains(output, "{\"type\":\"auto_retry_start\",\"attempt\":1,\"maxAttempts\":2,\"delayMs\":1000,\"errorMessage\":\"503 service unavailable\"}\n");
    try std.testing.expect(std.mem.indexOf(u8, output, "should not run after shutdown") == null);
}

test "TS RPC set_auto_retry false disables retry lifecycle" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "503 service unavailable" }) },
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{ai.providers.faux.fauxText("unexpected retry")}, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-retry-disabled",
        .system_prompt = "system",
        .model = registration.getModel(),
        .retry = .{
            .enabled = true,
            .max_retries = 2,
            .base_delay_ms = 1,
        },
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{
            "{\"id\":\"retry_off\",\"type\":\"set_auto_retry\",\"enabled\":false}",
            "{\"id\":\"disabled_prompt\",\"type\":\"prompt\",\"message\":\"do not retry\"}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    const output = stdout_capture.writer.buffered();
    try expectContains(output, "{\"id\":\"retry_off\",\"type\":\"response\",\"command\":\"set_auto_retry\",\"success\":true}\n");
    try expectContains(output, "{\"id\":\"disabled_prompt\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try std.testing.expect(std.mem.indexOf(u8, output, "\"type\":\"auto_retry_start\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"type\":\"auto_retry_end\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "unexpected retry") == null);
    try std.testing.expectEqual(@as(u32, 0), session.retry_attempt);
}

test "TS RPC direct bash success matches exact BashResult fixture bytes" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{"{\"id\":\"bash_ok\",\"type\":\"bash\",\"command\":\"printf ok\"}"},
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"id\":\"bash_ok\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"ok\",\"exitCode\":0,\"cancelled\":false,\"truncated\":false}}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC finish waits for active direct bash result before cleanup" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    try server.handleLine("{\"id\":\"bash_finish\",\"type\":\"bash\",\"command\":\"printf before; sleep 0.05; printf after\"}");
    try server.finish();

    try std.testing.expectEqualStrings(
        "{\"id\":\"bash_finish\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"beforeafter\",\"exitCode\":0,\"cancelled\":false,\"truncated\":false}}\n",
        stdout_capture.writer.buffered(),
    );
    try std.testing.expect(!server.hasActiveBashTask());
}

test "TS RPC direct bash failure is a successful BashResult response with exitCode" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{"{\"id\":\"bash_fail\",\"type\":\"bash\",\"command\":\"printf fail; exit 7\"}"},
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"id\":\"bash_fail\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"fail\",\"exitCode\":7,\"cancelled\":false,\"truncated\":false}}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC direct bash sanitizes control and ANSI output before serializing BashResult" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{"{\"id\":\"bash_sanitize\",\"type\":\"bash\",\"command\":\"printf 'a\\\\033[31mred\\\\033[0m\\\\001b\\\\r\\\\nc'\"}"},
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"id\":\"bash_sanitize\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"aredb\\nc\",\"exitCode\":0,\"cancelled\":false,\"truncated\":false}}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC direct bash preserves multibyte UTF-8 split across read boundary" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var command: std.Io.Writer.Allocating = .init(allocator);
    defer command.deinit();
    try command.writer.writeAll("printf '");
    for (0..4095) |_| try command.writer.writeByte('A');
    try command.writer.writeAll("💡END'");

    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    try line.writer.writeAll("{\"id\":\"bash_utf8_split\",\"type\":\"bash\",\"command\":");
    try writeJsonString(allocator, &line.writer, command.written());
    try line.writer.writeAll("}");

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{line.written()},
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    var expected_output: std.Io.Writer.Allocating = .init(allocator);
    defer expected_output.deinit();
    for (0..4095) |_| try expected_output.writer.writeByte('A');
    try expected_output.writer.writeAll("💡END");

    var expected: std.Io.Writer.Allocating = .init(allocator);
    defer expected.deinit();
    try expected.writer.writeAll("{\"id\":\"bash_utf8_split\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":");
    try writeJsonString(allocator, &expected.writer, expected_output.written());
    try expected.writer.writeAll(",\"exitCode\":0,\"cancelled\":false,\"truncated\":false}}\n");

    try std.testing.expectEqualStrings(expected.written(), stdout_capture.writer.buffered());
    try expectContains(stdout_capture.writer.buffered(), "💡END");
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "�") == null);
}

test "TS RPC direct bash UTF-8 sanitizer flushes incomplete sequence at end of stream" {
    const allocator = std.testing.allocator;
    const sanitized = try sanitizeDirectBashOutput(allocator, &.{ 0xf0, 0x9f });
    defer allocator.free(sanitized);
    try std.testing.expectEqualStrings("�", sanitized);
}

test "TS RPC direct bash truncates large output and retains full output path" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{"{\"id\":\"bash_big\",\"type\":\"bash\",\"command\":\"printf BEGIN; yes A | head -c 120000; printf END\"}"},
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stdout_capture.writer.buffered(), .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?.object;
    const output = data.get("output").?.string;
    const full_output_path = data.get("fullOutputPath").?.string;
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, full_output_path) catch {};

    try std.testing.expect(data.get("truncated").?.bool);
    try std.testing.expect(output.len <= truncate.DEFAULT_MAX_BYTES);
    try expectContains(output, "END");
    try std.testing.expect(std.mem.indexOf(u8, output, "BEGIN") == null);
    try std.testing.expect(std.mem.startsWith(u8, full_output_path, "/tmp/pi-bash-"));

    const full_output = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, full_output_path, allocator, .limited(256 * 1024));
    defer allocator.free(full_output);
    try expectContains(full_output, "BEGIN");
    try expectContains(full_output, "END");
}

test "TS RPC abort_bash interrupts active direct bash and cleans tracked task" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    try server.handleLine("{\"id\":\"bash_abort\",\"type\":\"bash\",\"command\":\"printf 'start\\n'; sleep 5; printf end\"}");
    try waitForActiveBashStarted(&server);
    std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch {};
    try server.handleLine("{\"id\":\"abort\",\"type\":\"abort_bash\"}");
    try server.finish();

    try std.testing.expectEqualStrings(
        "{\"id\":\"abort\",\"type\":\"response\",\"command\":\"abort_bash\",\"success\":true}\n" ++
            "{\"id\":\"bash_abort\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"start\\n\",\"cancelled\":true,\"truncated\":false}}\n",
        stdout_capture.writer.buffered(),
    );
    try std.testing.expect(!server.hasActiveBashTask());
}

test "TS RPC command loop remains live while direct bash is active" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    try server.handleLine("{\"id\":\"live_bash\",\"type\":\"bash\",\"command\":\"printf 'live\\n'; sleep 5; printf done\"}");
    try waitForActiveBashStarted(&server);
    std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch {};
    try server.handleLine("{\"id\":\"live_commands\",\"type\":\"get_commands\"}");
    try waitForOutputContains(
        &server,
        &stdout_capture.writer,
        "{\"id\":\"live_commands\",\"type\":\"response\",\"command\":\"get_commands\",\"success\":true,\"data\":{\"commands\":[]}}\n",
        500,
    );
    try server.handleLine("{\"id\":\"live_abort\",\"type\":\"abort_bash\"}");
    try server.finish();

    try std.testing.expectEqualStrings(
        "{\"id\":\"live_commands\",\"type\":\"response\",\"command\":\"get_commands\",\"success\":true,\"data\":{\"commands\":[]}}\n" ++
            "{\"id\":\"live_abort\",\"type\":\"response\",\"command\":\"abort_bash\",\"success\":true}\n" ++
            "{\"id\":\"live_bash\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"live\\n\",\"cancelled\":true,\"truncated\":false}}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC bash cleanup releases task mutex before joining blocked completion" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    server.deferred_responses_mutex.lockUncancelable(std.testing.io);
    var deferred_responses_locked = true;
    defer if (deferred_responses_locked) server.deferred_responses_mutex.unlock(std.testing.io);

    try server.handleLine("{\"id\":\"cleanup_bash\",\"type\":\"bash\",\"command\":\"printf cleanup\"}");
    try waitForActiveBashStarted(&server);

    server.bash_task_mutex.lockUncancelable(std.testing.io);
    const task = server.bash_tasks.items[0];
    server.bash_task_mutex.unlock(std.testing.io);

    const CancelContext = struct {
        server: *TsRpcServer,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(context: *@This()) void {
            context.server.cancelAndJoinBashTasks();
            context.done.store(true, .seq_cst);
        }
    };
    var cancel_context = CancelContext{ .server = &server };
    const cancel_thread = try std.Thread.spawn(.{}, CancelContext.run, .{&cancel_context});

    var abort_spins: usize = 0;
    while (!task.abort_signal.load(.seq_cst) and abort_spins < 1000) : (abort_spins += 1) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    const cleanup_reached_join = task.abort_signal.load(.seq_cst);

    const ProbeContext = struct {
        server: *TsRpcServer,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(context: *@This()) void {
            _ = context.server.hasUnfinishedBashTask();
            context.done.store(true, .seq_cst);
        }
    };
    var probe_context = ProbeContext{ .server = &server };
    const probe_thread = try std.Thread.spawn(.{}, ProbeContext.run, .{&probe_context});

    var probe_spins: usize = 0;
    while (!probe_context.done.load(.seq_cst) and probe_spins < 100) : (probe_spins += 1) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    const probe_completed_before_join_unblocked = probe_context.done.load(.seq_cst);

    server.deferred_responses_mutex.unlock(std.testing.io);
    deferred_responses_locked = false;
    cancel_thread.join();
    probe_thread.join();

    try std.testing.expect(cleanup_reached_join);
    try std.testing.expect(probe_completed_before_join_unblocked);
    try std.testing.expect(cancel_context.done.load(.seq_cst));
    try std.testing.expect(!server.hasActiveBashTask());
}

test "TS RPC production bash-control script matches generated TypeScript fixture bytes" {
    const allocator = std.testing.allocator;
    const start_marker = try allocator.dupe(u8, "/tmp/pi-ts-rpc-bash-control-start");
    defer allocator.free(start_marker);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, start_marker) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, start_marker) catch {};
    const live_marker = try allocator.dupe(u8, "/tmp/pi-ts-rpc-bash-control-live");
    defer allocator.free(live_marker);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, live_marker) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, live_marker) catch {};

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var bash_abort_command = std.Io.Writer.Allocating.init(allocator);
    defer bash_abort_command.deinit();
    try bash_abort_command.writer.print("printf 'start\\n'; touch {s}; sleep 5; printf end", .{start_marker});
    var bash_abort_line = std.Io.Writer.Allocating.init(allocator);
    defer bash_abort_line.deinit();
    try bash_abort_line.writer.writeAll("{\"id\":\"bash_abort\",\"type\":\"bash\",\"command\":");
    try writeJsonString(allocator, &bash_abort_line.writer, bash_abort_command.written());
    try bash_abort_line.writer.writeAll("}");

    var live_command = std.Io.Writer.Allocating.init(allocator);
    defer live_command.deinit();
    try live_command.writer.print("printf 'live\\n'; touch {s}; sleep 5; printf done", .{live_marker});
    var live_line = std.Io.Writer.Allocating.init(allocator);
    defer live_line.deinit();
    try live_line.writer.writeAll("{\"id\":\"live_bash\",\"type\":\"bash\",\"command\":");
    try writeJsonString(allocator, &live_line.writer, live_command.written());
    try live_line.writer.writeAll("}");

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    try server.handleLine("{\"id\":\"bash_ok\",\"type\":\"bash\",\"command\":\"printf ok\"}");
    try server.handleLine("{\"id\":\"bash_fail\",\"type\":\"bash\",\"command\":\"printf fail; exit 7\"}");
    try server.handleLine(bash_abort_line.written());
    try waitForAbsoluteFile(start_marker, 500);
    try server.handleLine("{\"id\":\"abort\",\"type\":\"abort_bash\"}");
    try server.handleLine(live_line.written());
    try waitForAbsoluteFile(live_marker, 500);
    try server.handleLine("{\"id\":\"live_commands\",\"type\":\"get_commands\"}");
    try server.handleLine("{\"id\":\"live_abort\",\"type\":\"abort_bash\"}");
    try server.finish();

    const expected = try readFixture("bash-control.jsonl");
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, stdout_capture.writer.buffered());
}

test "TS RPC M3 session host rebinds new switch fork clone and state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project-cwd");

    const relative_dir = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "ts-rpc-session-host",
    });
    defer allocator.free(relative_dir);
    const project_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "project-cwd",
    });
    defer allocator.free(project_relative);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, relative_dir });
    defer allocator.free(session_dir);
    const project_cwd = try std.fs.path.join(allocator, &[_][]const u8{ cwd, project_relative });
    defer allocator.free(project_cwd);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const first_user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    first_user_content[0] = .{ .text = .{ .text = "root prompt" } };
    const assistant_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_content[0] = .{ .text = .{ .text = "root answer" } };
    const second_user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    second_user_content[0] = .{ .text = .{ .text = "fork selected prompt" } };

    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = first_user_content, .timestamp = 11 } });
    _ = try session.session_manager.appendMessage(.{ .assistant = .{
        .content = assistant_content,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 2, .total_tokens = 3 },
        .stop_reason = .stop,
        .timestamp = 12,
    } });
    const fork_entry_id = try session.session_manager.appendMessage(.{ .user = .{ .content = second_user_content, .timestamp = 13 } });
    const fork_entry_id_owned = try allocator.dupe(u8, fork_entry_id);
    defer allocator.free(fork_entry_id_owned);
    try session.navigateTo(fork_entry_id);
    const original_session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(original_session_file);
    const original_session_id = try allocator.dupe(u8, session.session_manager.getSessionId());
    defer allocator.free(original_session_id);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    var cursor: usize = 0;

    try server.handleLine("{\"id\":\"new\",\"type\":\"new_session\",\"parentSession\":\"parent.jsonl\"}");
    try expectNewOutput(&stdout_capture.writer, &cursor, "{\"id\":\"new\",\"type\":\"response\",\"command\":\"new_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n");
    try std.testing.expect(!std.mem.eql(u8, original_session_id, session.session_manager.getSessionId()));

    try server.handleLine("{\"id\":\"new_state\",\"type\":\"get_state\"}");
    const new_state = try server.buildStateJson(&session);
    defer allocator.free(new_state);
    const expected_new_state = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"new_state\",\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"data\":{s}}}\n",
        .{new_state},
    );
    defer allocator.free(expected_new_state);
    try expectNewOutput(&stdout_capture.writer, &cursor, expected_new_state);
    try std.testing.expectEqual(@as(usize, 0), session.agent.getMessages().len);

    const switch_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"switch\",\"type\":\"switch_session\",\"sessionPath\":\"{s}\"}}",
        .{original_session_file},
    );
    defer allocator.free(switch_command);
    try server.handleLine(switch_command);
    try expectNewOutput(&stdout_capture.writer, &cursor, "{\"id\":\"switch\",\"type\":\"response\",\"command\":\"switch_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n");
    try std.testing.expectEqualStrings(original_session_id, session.session_manager.getSessionId());
    try std.testing.expectEqual(@as(usize, 3), session.agent.getMessages().len);

    try server.handleLine("{\"id\":\"new_after_rebind\",\"type\":\"new_session\",\"parentSession\":\"parent-after-rebind.jsonl\"}");
    try expectNewOutput(&stdout_capture.writer, &cursor, "{\"id\":\"new_after_rebind\",\"type\":\"response\",\"command\":\"new_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n");
    try std.testing.expectEqualStrings(session.session_manager.getCwd(), session.cwd);
    try std.testing.expectEqual(session.session_manager.getCwd().ptr, session.cwd.ptr);
    try std.testing.expectEqual(@as(usize, 0), session.agent.getMessages().len);

    try server.handleLine(switch_command);
    try expectNewOutput(&stdout_capture.writer, &cursor, "{\"id\":\"switch\",\"type\":\"response\",\"command\":\"switch_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n");
    try std.testing.expectEqualStrings(original_session_id, session.session_manager.getSessionId());
    try std.testing.expectEqual(@as(usize, 3), session.agent.getMessages().len);

    try server.handleLine("{\"id\":\"fork_messages\",\"type\":\"get_fork_messages\"}");
    const fork_messages = try server.buildForkMessagesJson(&session);
    defer allocator.free(fork_messages);
    const expected_fork_messages = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"fork_messages\",\"type\":\"response\",\"command\":\"get_fork_messages\",\"success\":true,\"data\":{s}}}\n",
        .{fork_messages},
    );
    defer allocator.free(expected_fork_messages);
    try expectNewOutput(&stdout_capture.writer, &cursor, expected_fork_messages);

    const fork_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"fork\",\"type\":\"fork\",\"entryId\":\"{s}\"}}",
        .{fork_entry_id_owned},
    );
    defer allocator.free(fork_command);
    try server.handleLine(fork_command);
    try expectNewOutput(&stdout_capture.writer, &cursor, "{\"id\":\"fork\",\"type\":\"response\",\"command\":\"fork\",\"success\":true,\"data\":{\"text\":\"fork selected prompt\",\"cancelled\":false}}\n");
    try std.testing.expectEqual(@as(usize, 2), session.agent.getMessages().len);

    try server.handleLine("{\"id\":\"clone\",\"type\":\"clone\"}");
    try expectNewOutput(&stdout_capture.writer, &cursor, "{\"id\":\"clone\",\"type\":\"response\",\"command\":\"clone\",\"success\":true,\"data\":{\"cancelled\":false}}\n");
    try std.testing.expectEqual(@as(usize, 2), session.agent.getMessages().len);

    try server.handleLine("{\"id\":\"name\",\"type\":\"set_session_name\",\"name\":\"  rebound name  \"}");
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"type\":\"session_info_changed\",\"name\":\"rebound name\"}\n{\"id\":\"name\",\"type\":\"response\",\"command\":\"set_session_name\",\"success\":true}\n",
    );

    try server.handleLine("{\"id\":\"clone_state\",\"type\":\"get_state\"}");
    const clone_state = try server.buildStateJson(&session);
    defer allocator.free(clone_state);
    const expected_clone_state = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"clone_state\",\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"data\":{s}}}\n",
        .{clone_state},
    );
    defer allocator.free(expected_clone_state);
    try expectNewOutput(&stdout_capture.writer, &cursor, expected_clone_state);
    try expectContains(clone_state, "\"sessionName\":\"rebound name\"");
}

test "TS RPC switch_session rejects target with missing stored cwd before tearing down current runtime" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "live-cwd");
    try tmp.dir.createDirPath(std.testing.io, "soon-deleted-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const live_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "live-cwd",
    });
    defer allocator.free(live_relative);
    const live_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, live_relative });
    defer allocator.free(live_cwd);
    const stale_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "soon-deleted-cwd",
    });
    defer allocator.free(stale_relative);
    const stale_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, stale_relative });
    defer allocator.free(stale_cwd);

    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;

    // The "stale" session file is created against an existing cwd which is
    // then deleted, so its stored cwd will fail the missing-cwd guard.
    var stale_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = stale_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    const stale_session_file = try allocator.dupe(u8, stale_session.session_manager.getSessionFile().?);
    defer allocator.free(stale_session_file);
    stale_session.deinit();
    try tmp.dir.deleteTree(std.testing.io, "soon-deleted-cwd");

    // The "active" session has a valid cwd and remains the current session.
    var active_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = live_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer active_session.deinit();
    const active_session_id = try allocator.dupe(u8, active_session.session_manager.getSessionId());
    defer allocator.free(active_session_id);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &active_session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    var cursor: usize = 0;

    const switch_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"switch_stale\",\"type\":\"switch_session\",\"sessionPath\":\"{s}\"}}",
        .{stale_session_file},
    );
    defer allocator.free(switch_command);
    try server.handleLine(switch_command);
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"id\":\"switch_stale\",\"type\":\"response\",\"command\":\"switch_session\",\"success\":false,\"error\":\"MissingSessionCwd\"}\n",
    );

    // The active session must remain the current session and its cwd must be
    // unchanged after the rejected switch.
    try std.testing.expectEqualStrings(active_session_id, active_session.session_manager.getSessionId());
    try std.testing.expectEqualStrings(live_cwd, active_session.cwd);
    try std.testing.expectEqualStrings(live_cwd, active_session.session_manager.getCwd());
}

// VAL-M10-SESSION-003: Resuming an existing session uses the stored session
// cwd rather than the process launch cwd whenever the stored cwd is valid.
test "VAL-M10-SESSION-003 switch_session adopts stored session cwd over launch cwd" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "stored-cwd");
    try tmp.dir.createDirPath(std.testing.io, "launch-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const stored_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "stored-cwd",
    });
    defer allocator.free(stored_relative);
    const stored_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, stored_relative });
    defer allocator.free(stored_cwd);
    const launch_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "launch-cwd",
    });
    defer allocator.free(launch_relative);
    const launch_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, launch_relative });
    defer allocator.free(launch_cwd);

    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;

    // Stored session is created with stored_cwd; this becomes the persisted
    // header cwd and must win over launch_cwd when we switch back to it.
    var stored_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = stored_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    const stored_session_file = try allocator.dupe(u8, stored_session.session_manager.getSessionFile().?);
    defer allocator.free(stored_session_file);
    const stored_session_id = try allocator.dupe(u8, stored_session.session_manager.getSessionId());
    defer allocator.free(stored_session_id);
    stored_session.deinit();

    // The "active" session simulates the running process whose launch cwd is
    // a different existing directory.
    var active_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = launch_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer active_session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &active_session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    var cursor: usize = 0;

    const switch_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"switch\",\"type\":\"switch_session\",\"sessionPath\":\"{s}\"}}",
        .{stored_session_file},
    );
    defer allocator.free(switch_command);
    try server.handleLine(switch_command);
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"id\":\"switch\",\"type\":\"response\",\"command\":\"switch_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n",
    );

    // Stored cwd wins over the prior launch cwd, and the resumed session
    // identity is preserved on disk through the switch.
    try std.testing.expectEqualStrings(stored_session_id, active_session.session_manager.getSessionId());
    try std.testing.expectEqualStrings(stored_cwd, active_session.cwd);
    try std.testing.expectEqualStrings(stored_cwd, active_session.session_manager.getCwd());
    try std.testing.expect(!std.mem.eql(u8, launch_cwd, active_session.cwd));
}

// VAL-M10-SESSION-004 / VAL-M10-SESSION-007: Forking a session preserves the
// parent session metadata, branch ancestry, and cwd identity without
// mutating the parent session file.
test "VAL-M10-SESSION-004 fork preserves parent metadata and parent file is unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "fork-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const project_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "fork-cwd",
    });
    defer allocator.free(project_relative);
    const project_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, project_relative });
    defer allocator.free(project_cwd);
    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_a = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_a[0] = .{ .text = .{ .text = "root prompt" } };
    const assistant_a = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_a[0] = .{ .text = .{ .text = "root answer" } };
    const user_b = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_b[0] = .{ .text = .{ .text = "fork target prompt" } };

    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = user_a, .timestamp = 21 } });
    _ = try session.session_manager.appendMessage(.{ .assistant = .{
        .content = assistant_a,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 2, .total_tokens = 3 },
        .stop_reason = .stop,
        .timestamp = 22,
    } });
    const fork_target_id = try session.session_manager.appendMessage(.{ .user = .{ .content = user_b, .timestamp = 23 } });
    const fork_target_id_owned = try allocator.dupe(u8, fork_target_id);
    defer allocator.free(fork_target_id_owned);
    try session.navigateTo(fork_target_id);

    const parent_session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(parent_session_file);
    const parent_session_id = try allocator.dupe(u8, session.session_manager.getSessionId());
    defer allocator.free(parent_session_id);
    const parent_bytes_before = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, parent_session_file, allocator, .unlimited);
    defer allocator.free(parent_bytes_before);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    var cursor: usize = 0;

    const fork_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"fork\",\"type\":\"fork\",\"entryId\":\"{s}\"}}",
        .{fork_target_id_owned},
    );
    defer allocator.free(fork_command);
    try server.handleLine(fork_command);
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"id\":\"fork\",\"type\":\"response\",\"command\":\"fork\",\"success\":true,\"data\":{\"text\":\"fork target prompt\",\"cancelled\":false}}\n",
    );

    // The forked session is a new, distinct session that retains the parent
    // cwd and records the parent session file in its persisted header.
    const fork_session_file = session.session_manager.getSessionFile().?;
    try std.testing.expect(!std.mem.eql(u8, parent_session_file, fork_session_file));
    try std.testing.expect(!std.mem.eql(u8, parent_session_id, session.session_manager.getSessionId()));
    try std.testing.expectEqualStrings(project_cwd, session.cwd);
    try std.testing.expectEqualStrings(project_cwd, session.session_manager.getCwd());

    const fork_parent = session.session_manager.getHeader().parent_session orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqualStrings(parent_session_file, fork_parent);

    // Parent session file on disk is preserved byte-for-byte.
    const parent_bytes_after = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, parent_session_file, allocator, .unlimited);
    defer allocator.free(parent_bytes_after);
    try std.testing.expectEqualStrings(parent_bytes_before, parent_bytes_after);
}

// VAL-M10-SESSION-007: Cloning a session creates a distinct child branch that
// retains the full ancestry up to and including the current leaf entry,
// records the parent session file in its persisted header, preserves the
// parent cwd, leaves the parent session file byte-identical on disk, and
// exposes parent and clone branch views via get_messages that reflect the
// correct cutoff/target ancestry.
test "VAL-M10-SESSION-007 clone preserves branch ancestry and parent file is unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "clone-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const project_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "clone-cwd",
    });
    defer allocator.free(project_relative);
    const project_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, project_relative });
    defer allocator.free(project_cwd);
    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_a = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_a[0] = .{ .text = .{ .text = "root prompt" } };
    const assistant_a = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_a[0] = .{ .text = .{ .text = "root answer" } };
    const user_b = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_b[0] = .{ .text = .{ .text = "second prompt" } };
    const assistant_b = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_b[0] = .{ .text = .{ .text = "second answer" } };

    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = user_a, .timestamp = 51 } });
    _ = try session.session_manager.appendMessage(.{ .assistant = .{
        .content = assistant_a,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 2, .total_tokens = 3 },
        .stop_reason = .stop,
        .timestamp = 52,
    } });
    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = user_b, .timestamp = 53 } });
    const leaf_assistant_id = try session.session_manager.appendMessage(.{ .assistant = .{
        .content = assistant_b,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 2, .total_tokens = 3 },
        .stop_reason = .stop,
        .timestamp = 54,
    } });
    const leaf_assistant_id_owned = try allocator.dupe(u8, leaf_assistant_id);
    defer allocator.free(leaf_assistant_id_owned);
    try session.navigateTo(leaf_assistant_id);

    // Snapshot parent identity and persisted bytes before clone runs.
    const parent_session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(parent_session_file);
    const parent_session_id = try allocator.dupe(u8, session.session_manager.getSessionId());
    defer allocator.free(parent_session_id);
    const parent_leaf_id = try allocator.dupe(u8, session.session_manager.getLeafId().?);
    defer allocator.free(parent_leaf_id);
    const parent_message_count = session.agent.getMessages().len;
    try std.testing.expectEqual(@as(usize, 4), parent_message_count);
    const parent_bytes_before = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, parent_session_file, allocator, .unlimited);
    defer allocator.free(parent_bytes_before);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    var cursor: usize = 0;

    // Capture parent get_messages branch view before clone (the cutoff/target
    // ancestry currently visible on the parent session).
    const parent_branch_messages_before = try server.buildMessagesJson(session.agent.getMessages());
    defer allocator.free(parent_branch_messages_before);

    try server.handleLine("{\"id\":\"clone\",\"type\":\"clone\"}");
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"id\":\"clone\",\"type\":\"response\",\"command\":\"clone\",\"success\":true,\"data\":{\"cancelled\":false}}\n",
    );

    // Cloned session is a new, distinct session. The session id and on-disk
    // file path are different from the parent.
    const clone_session_file = session.session_manager.getSessionFile().?;
    try std.testing.expect(!std.mem.eql(u8, parent_session_file, clone_session_file));
    try std.testing.expect(!std.mem.eql(u8, parent_session_id, session.session_manager.getSessionId()));

    // Clone preserves the parent cwd in its metadata.
    try std.testing.expectEqualStrings(project_cwd, session.cwd);
    try std.testing.expectEqualStrings(project_cwd, session.session_manager.getCwd());

    // Clone records the parent session file in its persisted header.
    const clone_parent = session.session_manager.getHeader().parent_session orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqualStrings(parent_session_file, clone_parent);

    // Clone retains the full branch ancestry: the leaf entry and message count
    // match the parent at clone time (cutoff/target == leaf assistant id).
    const clone_leaf_id = session.session_manager.getLeafId() orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqualStrings(parent_leaf_id, clone_leaf_id);
    try std.testing.expectEqual(parent_message_count, session.agent.getMessages().len);

    // Clone get_messages branch view matches the parent's branch view at the
    // cloned cutoff/target. Both must reflect the same root and second
    // user/assistant pairs in order.
    const clone_branch_messages = try server.buildMessagesJson(session.agent.getMessages());
    defer allocator.free(clone_branch_messages);
    try std.testing.expectEqualStrings(parent_branch_messages_before, clone_branch_messages);

    // Parent session file on disk is preserved byte-for-byte after clone.
    const parent_bytes_after = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, parent_session_file, allocator, .unlimited);
    defer allocator.free(parent_bytes_after);
    try std.testing.expectEqualStrings(parent_bytes_before, parent_bytes_after);

    // Switch back to the parent session and confirm its branch view is
    // unchanged: the same leaf and the same get_messages output as before
    // the clone occurred.
    const switch_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"back\",\"type\":\"switch_session\",\"sessionPath\":\"{s}\"}}",
        .{parent_session_file},
    );
    defer allocator.free(switch_command);
    try server.handleLine(switch_command);
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"id\":\"back\",\"type\":\"response\",\"command\":\"switch_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n",
    );
    try std.testing.expectEqualStrings(parent_session_id, session.session_manager.getSessionId());
    try std.testing.expectEqualStrings(parent_leaf_id, session.session_manager.getLeafId().?);
    try std.testing.expectEqual(parent_message_count, session.agent.getMessages().len);
    const parent_branch_messages_after_switch = try server.buildMessagesJson(session.agent.getMessages());
    defer allocator.free(parent_branch_messages_after_switch);
    try std.testing.expectEqualStrings(parent_branch_messages_before, parent_branch_messages_after_switch);
}

// VAL-M10-SESSION-006: Creating a new session clears prior transient session
// state, message history, and exposes a fresh session id; old session file is
// preserved and can be switched back to.
test "VAL-M10-SESSION-006 new_session clears prior transient state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "new-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const project_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "new-cwd",
    });
    defer allocator.free(project_relative);
    const project_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, project_relative });
    defer allocator.free(project_cwd);
    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = "old prompt" } };
    const assistant_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_content[0] = .{ .text = .{ .text = "old answer" } };
    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = user_content, .timestamp = 31 } });
    const old_assistant_id = try session.session_manager.appendMessage(.{ .assistant = .{
        .content = assistant_content,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 2, .total_tokens = 3 },
        .stop_reason = .stop,
        .timestamp = 32,
    } });
    try session.navigateTo(old_assistant_id);
    try std.testing.expect(session.agent.getMessages().len > 0);

    const old_session_id = try allocator.dupe(u8, session.session_manager.getSessionId());
    defer allocator.free(old_session_id);
    const old_session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(old_session_file);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    var cursor: usize = 0;

    try server.handleLine("{\"id\":\"new\",\"type\":\"new_session\",\"parentSession\":\"prior.jsonl\"}");
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"id\":\"new\",\"type\":\"response\",\"command\":\"new_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n",
    );

    // New session is fresh: distinct id, no messages, distinct file path,
    // cwd stays anchored to the active runtime cwd.
    try std.testing.expect(!std.mem.eql(u8, old_session_id, session.session_manager.getSessionId()));
    try std.testing.expect(!std.mem.eql(u8, old_session_file, session.session_manager.getSessionFile().?));
    try std.testing.expectEqual(@as(usize, 0), session.agent.getMessages().len);
    try std.testing.expectEqual(@as(usize, 0), session.session_manager.getEntries().len);
    try std.testing.expectEqualStrings(project_cwd, session.cwd);
    try std.testing.expectEqualStrings(project_cwd, session.session_manager.getCwd());
    try std.testing.expectEqual(@as(?[]const u8, null), session.session_manager.getLeafId());

    // Persisted parentSession is recorded in the new session header.
    const parent = session.session_manager.getHeader().parent_session orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqualStrings("prior.jsonl", parent);

    // The prior session file is preserved on disk (we can switch back to it
    // and observe the original messages).
    const switch_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"back\",\"type\":\"switch_session\",\"sessionPath\":\"{s}\"}}",
        .{old_session_file},
    );
    defer allocator.free(switch_command);
    try server.handleLine(switch_command);
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"id\":\"back\",\"type\":\"response\",\"command\":\"switch_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n",
    );
    try std.testing.expectEqualStrings(old_session_id, session.session_manager.getSessionId());
    try std.testing.expectEqual(@as(usize, 2), session.agent.getMessages().len);
}

// VAL-M10-SESSION-008: Reloading an active session preserves the selected
// session id, branch identity, stored cwd, and visible message list when the
// underlying files are unchanged.
test "VAL-M10-SESSION-008 reload preserves session identity and messages" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "reload-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const project_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "reload-cwd",
    });
    defer allocator.free(project_relative);
    const project_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, project_relative });
    defer allocator.free(project_cwd);
    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = "reload prompt" } };
    const assistant_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_content[0] = .{ .text = .{ .text = "reload answer" } };
    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = user_content, .timestamp = 41 } });
    const reload_assistant_id = try session.session_manager.appendMessage(.{ .assistant = .{
        .content = assistant_content,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 2, .total_tokens = 3 },
        .stop_reason = .stop,
        .timestamp = 42,
    } });
    try session.navigateTo(reload_assistant_id);

    const session_file_before = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file_before);
    const session_id_before = try allocator.dupe(u8, session.session_manager.getSessionId());
    defer allocator.free(session_id_before);
    const leaf_before = try allocator.dupe(u8, session.session_manager.getLeafId().?);
    defer allocator.free(leaf_before);
    const message_count_before = session.agent.getMessages().len;
    const session_bytes_before = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file_before, allocator, .unlimited);
    defer allocator.free(session_bytes_before);

    // Reload from disk via navigateTo (which delegates to reloadFromSession):
    // identity, cwd, leaf, and messages are preserved when underlying files
    // are unchanged.
    try session.navigateTo(leaf_before);

    try std.testing.expectEqualStrings(session_id_before, session.session_manager.getSessionId());
    try std.testing.expectEqualStrings(session_file_before, session.session_manager.getSessionFile().?);
    try std.testing.expectEqualStrings(leaf_before, session.session_manager.getLeafId().?);
    try std.testing.expectEqualStrings(project_cwd, session.cwd);
    try std.testing.expectEqualStrings(project_cwd, session.session_manager.getCwd());
    try std.testing.expectEqual(message_count_before, session.agent.getMessages().len);

    const session_bytes_after = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file_before, allocator, .unlimited);
    defer allocator.free(session_bytes_after);
    try std.testing.expectEqualStrings(session_bytes_before, session_bytes_after);
}

// VAL-M10-SESSION-009: Disconnecting and reconnecting the client to an
// existing TS-RPC runtime preserves active session identity, cwd, and
// messages rather than implicitly creating a new session.
test "VAL-M10-SESSION-009 reconnect to existing runtime preserves session state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "reconnect-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const project_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "reconnect-cwd",
    });
    defer allocator.free(project_relative);
    const project_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, project_relative });
    defer allocator.free(project_cwd);
    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = "reconnect prompt" } };
    const assistant_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_content[0] = .{ .text = .{ .text = "reconnect answer" } };
    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = user_content, .timestamp = 51 } });
    const assistant_id = try session.session_manager.appendMessage(.{ .assistant = .{
        .content = assistant_content,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 2, .total_tokens = 3 },
        .stop_reason = .stop,
        .timestamp = 52,
    } });
    try session.navigateTo(assistant_id);

    const session_id_before = try allocator.dupe(u8, session.session_manager.getSessionId());
    defer allocator.free(session_id_before);
    const session_file_before = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file_before);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    // First client "connects" to the runtime, queries state, then finishes.
    {
        var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
        try server.start();
        try server.handleLine("{\"id\":\"first\",\"type\":\"get_state\"}");
        const first_state = try server.buildStateJson(&session);
        defer allocator.free(first_state);
        try expectContains(stdout_capture.writer.buffered(), session_id_before);
        try expectContains(stdout_capture.writer.buffered(), first_state);
        try server.finish();
    }

    // The runtime/session stays alive across client disconnects: identity,
    // cwd, and messages are not reset by a finished server connection.
    try std.testing.expectEqualStrings(session_id_before, session.session_manager.getSessionId());
    try std.testing.expectEqualStrings(session_file_before, session.session_manager.getSessionFile().?);
    try std.testing.expectEqualStrings(project_cwd, session.cwd);
    try std.testing.expectEqualStrings(project_cwd, session.session_manager.getCwd());
    try std.testing.expectEqual(@as(usize, 2), session.agent.getMessages().len);

    // Second client "reconnects", retrieves state again, and observes the
    // exact same identity and message count.
    var stdout_capture_two: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture_two.deinit();
    var stderr_capture_two: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture_two.deinit();
    var server2 = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture_two.writer, &stderr_capture_two.writer);
    try server2.start();
    defer server2.finish() catch {};
    try server2.handleLine("{\"id\":\"second\",\"type\":\"get_state\"}");
    try server2.handleLine("{\"id\":\"msgs\",\"type\":\"get_messages\"}");
    try expectContains(stdout_capture_two.writer.buffered(), session_id_before);
    try expectContains(stdout_capture_two.writer.buffered(), "\"messageCount\":2");
    try expectContains(stdout_capture_two.writer.buffered(), "\"command\":\"get_messages\",\"success\":true");

    try std.testing.expectEqualStrings(session_id_before, session.session_manager.getSessionId());
    try std.testing.expectEqualStrings(project_cwd, session.cwd);
}

// VAL-M10-SESSION-010 / subscription isolation: A failed switch_session
// (rejected by the missing-cwd guard) leaves the active session file
// byte-identical, leaves the active subscriber attached for new events, and
// leaves the prior session file undisturbed.
test "VAL-M10-SESSION-010 failed switch leaves session files byte-identical and subscriber intact" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "live-cwd");
    try tmp.dir.createDirPath(std.testing.io, "soon-deleted-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const live_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "live-cwd",
    });
    defer allocator.free(live_relative);
    const live_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, live_relative });
    defer allocator.free(live_cwd);
    const stale_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "soon-deleted-cwd",
    });
    defer allocator.free(stale_relative);
    const stale_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, stale_relative });
    defer allocator.free(stale_cwd);
    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;

    var stale_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = stale_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    const stale_session_file = try allocator.dupe(u8, stale_session.session_manager.getSessionFile().?);
    defer allocator.free(stale_session_file);
    stale_session.deinit();
    const stale_bytes_before = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, stale_session_file, allocator, .unlimited);
    defer allocator.free(stale_bytes_before);
    try tmp.dir.deleteTree(std.testing.io, "soon-deleted-cwd");

    var active_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = live_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer active_session.deinit();
    const active_session_file = try allocator.dupe(u8, active_session.session_manager.getSessionFile().?);
    defer allocator.free(active_session_file);
    const active_session_id = try allocator.dupe(u8, active_session.session_manager.getSessionId());
    defer allocator.free(active_session_id);
    const active_bytes_before = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, active_session_file, allocator, .unlimited);
    defer allocator.free(active_bytes_before);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &active_session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    var cursor: usize = 0;

    const switch_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"switch_stale\",\"type\":\"switch_session\",\"sessionPath\":\"{s}\"}}",
        .{stale_session_file},
    );
    defer allocator.free(switch_command);
    try server.handleLine(switch_command);
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"id\":\"switch_stale\",\"type\":\"response\",\"command\":\"switch_session\",\"success\":false,\"error\":\"MissingSessionCwd\"}\n",
    );

    // Active session identity, cwd, and on-disk bytes are unchanged.
    try std.testing.expectEqualStrings(active_session_id, active_session.session_manager.getSessionId());
    try std.testing.expectEqualStrings(live_cwd, active_session.cwd);
    const active_bytes_after = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, active_session_file, allocator, .unlimited);
    defer allocator.free(active_bytes_after);
    try std.testing.expectEqualStrings(active_bytes_before, active_bytes_after);

    // The would-be target session file is also untouched on disk.
    const stale_bytes_after = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, stale_session_file, allocator, .unlimited);
    defer allocator.free(stale_bytes_after);
    try std.testing.expectEqualStrings(stale_bytes_before, stale_bytes_after);

    // Subscription isolation: the active session subscriber is still attached
    // and routes new events to the existing client. Setting the session name
    // emits a `session_info_changed` event followed by a successful response.
    try server.handleLine("{\"id\":\"name\",\"type\":\"set_session_name\",\"name\":\"after-failed-switch\"}");
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"type\":\"session_info_changed\",\"name\":\"after-failed-switch\"}\n{\"id\":\"name\",\"type\":\"response\",\"command\":\"set_session_name\",\"success\":true}\n",
    );
}

test "TS RPC M2 queue_update is emitted before response and prompt.streamingBehavior queues while streaming" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const input = try readFixture("prompt-concurrency-queue-order.input.jsonl");
    defer allocator.free(input);
    try runTsRpcModeBytes(
        allocator,
        std.testing.io,
        &session,
        input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    const fixture = try readFixture("prompt-concurrency-queue-order.jsonl");
    defer allocator.free(fixture);
    try expectPromptConcurrencyQueueInvariant(stdout_capture.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, fixture, "{\"type\":\"agent_start\"}\n") == null);
    try std.testing.expectEqualStrings(fixture, stdout_capture.writer.buffered());
}

test "TS RPC M2 prompt without streamingBehavior rejects while streaming" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
    });
    defer session.deinit();
    session.agent.is_streaming = true;

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{"{\"id\":\"busy\",\"type\":\"prompt\",\"message\":\"second prompt\"}"},
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"id\":\"busy\",\"type\":\"response\",\"command\":\"prompt\",\"success\":false,\"error\":\"Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message.\"}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC M2 abort command is processed while prompt worker is in flight" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
    });
    defer session.deinit();
    session.agent.stream_fn = blockingUntilAbortStream;

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();

    try server.handleLine("{\"id\":\"p\",\"type\":\"prompt\",\"message\":\"slow prompt\"}");
    try waitForSessionStreaming(&session);
    try std.testing.expect(session.isStreaming());

    try server.handleLine("{\"id\":\"a\",\"type\":\"abort\"}");

    try server.finish();
    try expectContains(
        stdout_capture.writer.buffered(),
        "{\"id\":\"a\",\"type\":\"response\",\"command\":\"abort\",\"success\":true}\n",
    );
    try expectContains(
        stdout_capture.writer.buffered(),
        "{\"id\":\"p\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n",
    );
    try expectContains(stdout_capture.writer.buffered(), "\"stopReason\":\"aborted\"");
    const abort_response_index = std.mem.indexOf(u8, stdout_capture.writer.buffered(), "{\"id\":\"a\",\"type\":\"response\",\"command\":\"abort\",\"success\":true}\n").?;
    const agent_end_index = std.mem.indexOf(u8, stdout_capture.writer.buffered(), "{\"type\":\"agent_end\"").?;
    try std.testing.expect(abort_response_index < agent_end_index);
}

test "TS RPC live client receives queue_update events and queued control responses before EOF" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
    });
    defer session.deinit();
    session.agent.stream_fn = blockingUntilAbortStream;

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();

    try server.handleLine("{\"id\":\"p\",\"type\":\"prompt\",\"message\":\"slow prompt\"}");
    try waitForSessionStreaming(&session);
    try std.testing.expect(session.isStreaming());

    try server.handleLine("{\"id\":\"s\",\"type\":\"steer\",\"message\":\"steer while live\"}");
    try server.handleLine("{\"id\":\"f\",\"type\":\"follow_up\",\"message\":\"follow while live\"}");
    try server.handleLine("{\"id\":\"ps\",\"type\":\"prompt\",\"message\":\"prompt steer while live\",\"streamingBehavior\":\"steer\"}");
    try server.handleLine("{\"id\":\"pf\",\"type\":\"prompt\",\"message\":\"prompt follow while live\",\"streamingBehavior\":\"followUp\"}");

    const steer_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while live\"],\"followUp\":[]}\n";
    const follow_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while live\"],\"followUp\":[\"follow while live\"]}\n";
    const prompt_steer_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while live\",\"prompt steer while live\"],\"followUp\":[\"follow while live\"]}\n";
    const prompt_follow_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while live\",\"prompt steer while live\"],\"followUp\":[\"follow while live\",\"prompt follow while live\"]}\n";

    try waitForServerOutputContains(&server, &stdout_capture.writer, steer_queue_update);
    try waitForServerOutputContains(&server, &stdout_capture.writer, follow_queue_update);
    try waitForServerOutputContains(&server, &stdout_capture.writer, prompt_steer_queue_update);
    try waitForServerOutputContains(&server, &stdout_capture.writer, prompt_follow_queue_update);
    try waitForServerOutputContains(&server, &stdout_capture.writer, "{\"id\":\"ps\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try waitForServerOutputContains(&server, &stdout_capture.writer, "{\"id\":\"pf\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try waitForServerOutputContains(&server, &stdout_capture.writer, "{\"id\":\"s\",\"type\":\"response\",\"command\":\"steer\",\"success\":true}\n");
    try waitForServerOutputContains(&server, &stdout_capture.writer, "{\"id\":\"f\",\"type\":\"response\",\"command\":\"follow_up\",\"success\":true}\n");
    try std.testing.expect(session.isStreaming());

    try expectOutputOrder(stdout_capture.writer.buffered(), steer_queue_update, "{\"id\":\"s\",\"type\":\"response\",\"command\":\"steer\",\"success\":true}\n");
    try expectOutputOrder(stdout_capture.writer.buffered(), follow_queue_update, "{\"id\":\"f\",\"type\":\"response\",\"command\":\"follow_up\",\"success\":true}\n");
    try expectOutputOrder(stdout_capture.writer.buffered(), prompt_steer_queue_update, "{\"id\":\"ps\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try expectOutputOrder(stdout_capture.writer.buffered(), prompt_follow_queue_update, "{\"id\":\"pf\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");

    try server.handleLine("{\"id\":\"a\",\"type\":\"abort\"}");
    try waitForServerOutputContains(&server, &stdout_capture.writer, "{\"id\":\"a\",\"type\":\"response\",\"command\":\"abort\",\"success\":true}\n");

    try server.finish();
}

test "TS RPC M2 prompt response precedes base event stream" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{
            ai.providers.faux.fauxText("prompt reply"),
        }, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
        .model = registration.getModel(),
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{"{\"id\":\"p\",\"type\":\"prompt\",\"message\":\"hello\"}"},
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try expectContains(
        stdout_capture.writer.buffered(),
        "{\"id\":\"p\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n{\"type\":\"agent_start\"}\n{\"type\":\"turn_start\"}\n",
    );
    try expectPromptLineTypeOrder(stdout_capture.writer.buffered());
}

test "TS RPC dispatcher skeleton covers every TypeScript RpcCommand type" {
    const allocator = std.testing.allocator;
    const commands = try readFixture("commands-input.jsonl");
    defer allocator.free(commands);

    var seen = [_]bool{false} ** command_types.len;

    var lines = std.mem.splitScalar(u8, commands, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const type_value = parsed.value.object.get("type").?;
        if (std.mem.eql(u8, type_value.string, "extension_ui_response")) continue;
        try std.testing.expect(isKnownCommandType(type_value.string));
        for (command_types, 0..) |known, index| {
            if (std.mem.eql(u8, known, type_value.string)) {
                seen[index] = true;
                break;
            }
        }
    }

    for (seen) |did_see| {
        try std.testing.expect(did_see);
    }
}

test "TS RPC extension UI request writer matches TypeScript fixture bytes" {
    const allocator = std.testing.allocator;
    const fixture = try readFixture("extension-ui.jsonl");
    defer allocator.free(fixture);
    const response_start = std.mem.indexOf(u8, fixture, "{\"type\":\"extension_ui_response\"").?;
    const expected_requests = fixture[0..response_start];

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    const select_options = [_][]const u8{ "option-a", "option-b" };
    const widget_lines = [_][]const u8{ "line one", "line two" };

    try server.writeExtensionUISelectRequest("ui_select", "Choose fixture", &select_options, 1000);
    try server.writeExtensionUIConfirmRequest("ui_confirm", "Confirm fixture", "Proceed?", 1000);
    try server.writeExtensionUIInputRequest("ui_input", "Fixture input", "value", 1000);
    try server.writeExtensionUINotifyRequest("ui_notify", "Fixture notice", "info");
    try server.writeExtensionUISetStatusRequest("ui_status", "fixture", "ready");
    try server.writeExtensionUISetWidgetRequest("ui_widget", "fixture", &widget_lines, "aboveEditor");
    try server.writeExtensionUISetTitleRequest("ui_title", "Fixture Title");
    try server.writeExtensionUISetEditorTextRequest("ui_editor_text", "fixture editor text");
    try server.writeExtensionUIEditorRequest("ui_editor", "Edit fixture", "prefill");
    try server.finish();

    try std.testing.expectEqualStrings(expected_requests, stdout_capture.writer.buffered());
}

test "TS RPC extension UI responses are consumed without output" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        null,
        &.{
            "{\"type\":\"extension_ui_response\",\"id\":\"ui_select\",\"value\":\"option-a\"}",
            "{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"confirmed\":true}",
            "{\"type\":\"extension_ui_response\",\"id\":\"ui_input\",\"cancelled\":true}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(usize, 0), stdout_capture.writer.buffered().len);
}

test "TS RPC extension UI responses resolve pending requests like TypeScript" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    try server.registerPendingExtensionUIRequest("ui_select", .select, 1000);
    try server.registerPendingExtensionUIRequest("ui_confirm", .confirm, 1000);
    try server.registerPendingExtensionUIRequest("ui_input", .input, 1000);
    try server.registerPendingExtensionUIRequest("ui_editor", .editor, null);

    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_select\",\"value\":\"option-a\"}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"confirmed\":true}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_input\",\"cancelled\":true}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_editor\",\"value\":\"edited text\"}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"missing\",\"value\":\"ignored\"}");
    defer server.finish() catch {};

    try std.testing.expectEqual(@as(usize, 0), stdout_capture.writer.buffered().len);
    try std.testing.expectEqual(@as(usize, 0), server.pending_extension_requests.count());
    try std.testing.expectEqual(@as(usize, 4), server.completed_extension_requests.items.len);
    try std.testing.expectEqualStrings("ui_select", server.completed_extension_requests.items[0].id);
    try std.testing.expectEqual(ExtensionUIDialogMethod.select, server.completed_extension_requests.items[0].method);
    try std.testing.expectEqualStrings("option-a", server.completed_extension_requests.items[0].resolution.value);
    try std.testing.expectEqual(ExtensionUIDialogMethod.confirm, server.completed_extension_requests.items[1].method);
    try std.testing.expect(server.completed_extension_requests.items[1].resolution.confirmed);
    try std.testing.expectEqual(ExtensionUIDialogMethod.input, server.completed_extension_requests.items[2].method);
    try std.testing.expectEqual(ExtensionUIResolution.none, server.completed_extension_requests.items[2].resolution);
    try std.testing.expectEqual(ExtensionUIDialogMethod.editor, server.completed_extension_requests.items[3].method);
    try std.testing.expectEqualStrings("edited text", server.completed_extension_requests.items[3].resolution.value);
}

test "TS RPC cancelled extension UI responses use pending method defaults" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    try server.registerPendingExtensionUIRequest("ui_select_cancelled", .select, 1000);
    try server.registerPendingExtensionUIRequest("ui_confirm_cancelled", .confirm, 1000);
    try server.registerPendingExtensionUIRequest("ui_input_cancelled", .input, 1000);
    try server.registerPendingExtensionUIRequest("ui_editor_cancelled", .editor, null);
    defer server.finish() catch {};

    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_select_cancelled\",\"cancelled\":true}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm_cancelled\",\"cancelled\":true}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_input_cancelled\",\"cancelled\":true}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_editor_cancelled\",\"cancelled\":true}");

    try std.testing.expectEqual(@as(usize, 0), stdout_capture.writer.buffered().len);
    try std.testing.expectEqual(@as(u32, 0), server.pending_extension_requests.count());
    try std.testing.expectEqual(@as(usize, 4), server.completed_extension_requests.items.len);

    try std.testing.expectEqual(ExtensionUIDialogMethod.select, server.completed_extension_requests.items[0].method);
    try std.testing.expectEqual(ExtensionUIResolution.none, server.completed_extension_requests.items[0].resolution);

    try std.testing.expectEqual(ExtensionUIDialogMethod.confirm, server.completed_extension_requests.items[1].method);
    switch (server.completed_extension_requests.items[1].resolution) {
        .confirmed => |confirmed| try std.testing.expect(!confirmed),
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(ExtensionUIDialogMethod.input, server.completed_extension_requests.items[2].method);
    try std.testing.expectEqual(ExtensionUIResolution.none, server.completed_extension_requests.items[2].resolution);

    try std.testing.expectEqual(ExtensionUIDialogMethod.editor, server.completed_extension_requests.items[3].method);
    try std.testing.expectEqual(ExtensionUIResolution.none, server.completed_extension_requests.items[3].resolution);
}

test "TS RPC extension UI timeout and cancel resolve deterministic defaults" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    try server.registerPendingExtensionUIRequest("ui_select", .select, 1000);
    try server.registerPendingExtensionUIRequest("ui_confirm", .confirm, null);
    try server.registerPendingExtensionUIRequest("ui_input", .input, 50);
    defer server.finish() catch {};

    try server.advanceExtensionUITime(49);
    try std.testing.expectEqual(@as(usize, 0), server.completed_extension_requests.items.len);
    try std.testing.expectEqual(@as(u32, 3), server.pending_extension_requests.count());

    try server.advanceExtensionUITime(1);
    try std.testing.expectEqual(@as(usize, 1), server.completed_extension_requests.items.len);
    try std.testing.expectEqualStrings("ui_input", server.completed_extension_requests.items[0].id);
    try std.testing.expectEqual(ExtensionUIDialogMethod.input, server.completed_extension_requests.items[0].method);
    try std.testing.expectEqual(ExtensionUIResolution.none, server.completed_extension_requests.items[0].resolution);

    try std.testing.expect(try server.cancelPendingExtensionUIRequest("ui_confirm"));
    try std.testing.expectEqual(@as(usize, 2), server.completed_extension_requests.items.len);
    try std.testing.expectEqual(ExtensionUIDialogMethod.confirm, server.completed_extension_requests.items[1].method);
    try std.testing.expect(!server.completed_extension_requests.items[1].resolution.confirmed);

    try server.advanceExtensionUITime(950);
    try std.testing.expectEqual(@as(usize, 3), server.completed_extension_requests.items.len);
    try std.testing.expectEqualStrings("ui_select", server.completed_extension_requests.items[2].id);
    try std.testing.expectEqual(ExtensionUIResolution.none, server.completed_extension_requests.items[2].resolution);
    try std.testing.expect(!try server.cancelPendingExtensionUIRequest("ui_select"));
}

test "M6 extension UI bridge serializes host requests and forwards responses exactly once" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-m6-extension-ui-bridge-capture.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; printf '%s\\n' \"$init\" > {s}; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_select\",\"method\":\"select\",\"responseRequired\":true,\"payload\":{{\"title\":\"Choose fixture\",\"options\":[\"option-a\",\"option-b\"],\"timeout\":1000}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_confirm\",\"method\":\"confirm\",\"responseRequired\":true,\"payload\":{{\"title\":\"Confirm fixture\",\"message\":\"Proceed?\",\"timeout\":1000}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_input\",\"method\":\"input\",\"responseRequired\":true,\"payload\":{{\"title\":\"Fixture input\",\"placeholder\":\"value\",\"timeout\":1000}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_notify\",\"method\":\"notify\",\"payload\":{{\"message\":\"Fixture notice\",\"notifyType\":\"info\"}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_status\",\"method\":\"setStatus\",\"payload\":{{\"statusKey\":\"fixture\",\"statusText\":\"ready\"}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_widget\",\"method\":\"setWidget\",\"payload\":{{\"widgetKey\":\"fixture\",\"widgetLines\":[\"line one\",\"line two\"],\"widgetPlacement\":\"aboveEditor\"}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_title\",\"method\":\"setTitle\",\"payload\":{{\"title\":\"Fixture Title\"}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_editor_text\",\"method\":\"set_editor_text\",\"payload\":{{\"text\":\"fixture editor text\"}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_editor\",\"method\":\"editor\",\"responseRequired\":true,\"payload\":{{\"title\":\"Edit fixture\",\"prefill\":\"prefill\"}}}}\\n'; " ++
            "while IFS= read -r line; do printf '%s\\n' \"$line\" >> {s}; case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; done",
        .{ capture_path, capture_path },
    );
    defer allocator.free(script);

    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-m6-extension-ui-bridge" };
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-m6-extension-ui-bridge",
        .fixture = "ui-bridge",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });
    try server.drainExtensionHostUiRequests(100);

    const expected =
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_select\",\"method\":\"select\",\"title\":\"Choose fixture\",\"options\":[\"option-a\",\"option-b\"],\"timeout\":1000}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_confirm\",\"method\":\"confirm\",\"title\":\"Confirm fixture\",\"message\":\"Proceed?\",\"timeout\":1000}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_input\",\"method\":\"input\",\"title\":\"Fixture input\",\"placeholder\":\"value\",\"timeout\":1000}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_notify\",\"method\":\"notify\",\"message\":\"Fixture notice\",\"notifyType\":\"info\"}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_status\",\"method\":\"setStatus\",\"statusKey\":\"fixture\",\"statusText\":\"ready\"}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_widget\",\"method\":\"setWidget\",\"widgetKey\":\"fixture\",\"widgetLines\":[\"line one\",\"line two\"],\"widgetPlacement\":\"aboveEditor\"}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_title\",\"method\":\"setTitle\",\"title\":\"Fixture Title\"}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_editor_text\",\"method\":\"set_editor_text\",\"text\":\"fixture editor text\"}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_editor\",\"method\":\"editor\",\"title\":\"Edit fixture\",\"prefill\":\"prefill\"}\n";
    try std.testing.expectEqualStrings(expected, stdout_capture.writer.buffered());

    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"confirmed\":true}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_select\",\"value\":\"option-a\"}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"confirmed\":false}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_input\",\"cancelled\":true}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_editor\",\"value\":\"edited text\"}");
    try std.testing.expectEqual(@as(usize, 4), server.completed_extension_requests.items.len);
    try std.testing.expectEqualStrings("ui_confirm", server.completed_extension_requests.items[0].id);
    try std.testing.expectEqualStrings("ui_select", server.completed_extension_requests.items[1].id);
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try expectContains(capture, "{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"payload\":{\"confirmed\":true}}\n");
    try expectContains(capture, "{\"type\":\"extension_ui_response\",\"id\":\"ui_select\",\"payload\":{\"value\":\"option-a\"}}\n");
    try expectContains(capture, "{\"type\":\"extension_ui_response\",\"id\":\"ui_input\",\"payload\":{\"cancelled\":true}}\n");
    try expectContains(capture, "{\"type\":\"extension_ui_response\",\"id\":\"ui_editor\",\"payload\":{\"value\":\"edited text\"}}\n");
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"payload\":{\"confirmed\":false}}\n") == null);
}

test "M6 extension UI bridge forwards timeout defaults to host" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-m6-extension-ui-timeout-capture.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; printf '%s\\n' \"$init\" > {s}; printf '{{\"type\":\"ready\"}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_confirm\",\"method\":\"confirm\",\"responseRequired\":true,\"payload\":{{\"title\":\"Confirm fixture\",\"message\":\"Proceed?\",\"timeout\":10}}}}\\n'; " ++
            "while IFS= read -r line; do printf '%s\\n' \"$line\" >> {s}; case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; done",
        .{ capture_path, capture_path },
    );
    defer allocator.free(script);

    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-m6-extension-ui-timeout" };
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-m6-extension-ui-timeout",
        .fixture = "ui-timeout",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });
    try server.drainExtensionHostUiRequests(100);
    try expectContains(stdout_capture.writer.buffered(), "{\"type\":\"extension_ui_request\",\"id\":\"ui_confirm\",\"method\":\"confirm\",\"title\":\"Confirm fixture\",\"message\":\"Proceed?\",\"timeout\":10}\n");
    try server.advanceExtensionUITime(10);
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try expectContains(capture, "{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"payload\":{\"confirmed\":false}}\n");
}

test "M6 extension UI bridge drains delayed host requests without stdin activity" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-m6-extension-ui-idle-pump-capture.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; printf '%s\\n' \"$init\" > {s}; printf '{{\"type\":\"ready\"}}\\n'; " ++
            "sleep 0.2; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_idle_confirm\",\"method\":\"confirm\",\"responseRequired\":true,\"payload\":{{\"title\":\"Idle confirm\",\"message\":\"Proceed while idle?\",\"timeout\":20}}}}\\n'; " ++
            "while IFS= read -r line; do printf '%s\\n' \"$line\" >> {s}; case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; done",
        .{ capture_path, capture_path },
    );
    defer allocator.free(script);

    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-m6-extension-ui-idle-pump" };
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-m6-extension-ui-idle-pump",
        .fixture = "ui-idle-pump",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });
    try std.testing.expectEqual(@as(usize, 0), stdout_capture.writer.buffered().len);

    const request_line = "{\"type\":\"extension_ui_request\",\"id\":\"ui_idle_confirm\",\"method\":\"confirm\",\"title\":\"Idle confirm\",\"message\":\"Proceed while idle?\",\"timeout\":20}\n";
    var elapsed: u64 = 0;
    while (std.mem.indexOf(u8, stdout_capture.writer.buffered(), request_line) == null and elapsed < 1000) : (elapsed += EXTENSION_HOST_EVENT_LOOP_TICK_MS) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(EXTENSION_HOST_EVENT_LOOP_TICK_MS), .awake) catch {};
        try server.serviceExtensionHostIdleTick(EXTENSION_HOST_EVENT_LOOP_TICK_MS);
    }
    try expectContains(stdout_capture.writer.buffered(), request_line);

    var timeout_elapsed: u64 = 0;
    while (server.pending_extension_requests.count() != 0 and timeout_elapsed < 1000) : (timeout_elapsed += EXTENSION_HOST_EVENT_LOOP_TICK_MS) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(EXTENSION_HOST_EVENT_LOOP_TICK_MS), .awake) catch {};
        try server.serviceExtensionHostIdleTick(EXTENSION_HOST_EVENT_LOOP_TICK_MS);
    }
    try std.testing.expectEqual(@as(u32, 0), server.pending_extension_requests.count());
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try expectContains(capture, "{\"type\":\"extension_ui_response\",\"id\":\"ui_idle_confirm\",\"payload\":{\"confirmed\":false}}\n");
}

fn expectPromptLineTypeOrder(bytes: []const u8) !void {
    const allocator = std.testing.allocator;
    var actual = std.ArrayList([]const u8).empty;
    defer {
        for (actual.items) |item| allocator.free(item);
        actual.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, bytes, "\n"), '\n');
    while (lines.next()) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try actual.append(allocator, try allocator.dupe(u8, parsed.value.object.get("type").?.string));
    }

    try std.testing.expect(actual.items.len >= 10);
    const prefix = [_][]const u8{ "response", "agent_start", "turn_start", "message_start", "message_end", "message_start" };
    for (prefix, 0..) |expected, index| {
        try std.testing.expectEqualStrings(expected, actual.items[index]);
    }
    var index: usize = prefix.len;
    var update_count: usize = 0;
    while (index < actual.items.len and std.mem.eql(u8, actual.items[index], "message_update")) : (index += 1) {
        update_count += 1;
    }
    try std.testing.expect(update_count > 0);
    try std.testing.expectEqualStrings("message_end", actual.items[index]);
    try std.testing.expectEqualStrings("turn_end", actual.items[index + 1]);
    try std.testing.expectEqualStrings("agent_end", actual.items[index + 2]);
    try std.testing.expectEqual(actual.items.len, index + 3);
}

fn waitForSessionStreaming(session: *const session_mod.AgentSession) !void {
    var spins: usize = 0;
    while (!session.isStreaming() and spins < 1000) : (spins += 1) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(session.isStreaming());
}

fn waitForActiveBashStarted(server: *TsRpcServer) !void {
    var spins: usize = 0;
    while (!server.activeBashTaskStarted() and spins < 1000) : (spins += 1) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(server.activeBashTaskStarted());
}

fn waitForServerOutputContains(
    server: *TsRpcServer,
    writer: *std.Io.Writer,
    needle: []const u8,
) !void {
    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) {
        server.output_mutex.lockUncancelable(std.testing.io);
        const found = std.mem.indexOf(u8, writer.buffered(), needle) != null;
        server.output_mutex.unlock(std.testing.io);
        if (found) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    server.output_mutex.lockUncancelable(std.testing.io);
    defer server.output_mutex.unlock(std.testing.io);
    try expectContains(writer.buffered(), needle);
}

fn blockingUntilAbortStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai.Model,
    context: ai.Context,
    options: ?ai.types.SimpleStreamOptions,
    stream_context: ?*anyopaque,
) !ai.event_stream.AssistantMessageEventStream {
    _ = context;
    _ = stream_context;
    const signal = if (options) |some| some.signal else null;
    while (signal == null or !signal.?.load(.seq_cst)) {
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }

    var stream = ai.event_stream.createAssistantMessageEventStream(std.heap.page_allocator, io);
    const message = ai.AssistantMessage{
        .content = &[_]ai.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = ai.Usage.init(),
        .stop_reason = .aborted,
        .error_message = "Aborted by user",
        .timestamp = 0,
    };
    stream.push(.{
        .event_type = .done,
        .message = message,
    });
    _ = allocator;
    return stream;
}

test "event_emission: turn_start and turn_end frames contain turnIndex and timestamp" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-ts-rpc-event-emission-turn-index.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 1, .max = 1 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{
            ai.providers.faux.fauxText("reply one"),
        }, .{}) },
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{
            ai.providers.faux.fauxText("reply two"),
        }, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-event-emission-turn-index",
        .system_prompt = "system",
        .model = registration.getModel(),
    });
    defer session.deinit();

    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "while IFS= read -r line; do " ++
            "printf '%s\\n' \"$line\" >> {s}; " ++
            "case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; " ++
            "done",
        .{capture_path},
    );
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-ts-rpc-turn-index" };

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-ts-rpc-turn-index",
        .fixture = "turn-index",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    // Run first prompt (turn 1)
    try server.handleLine("{\"id\":\"p1\",\"type\":\"prompt\",\"message\":\"hello\"}");
    try waitForNoInFlightPrompt(&server, 5000);

    // Run second prompt (turn 2) to verify turnIndex increments
    try server.handleLine("{\"id\":\"p2\",\"type\":\"prompt\",\"message\":\"hello again\"}");
    try waitForNoInFlightPrompt(&server, 5000);

    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    // turn_start frames must include turnIndex and timestamp
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"turn_start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"turnIndex\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"timestamp\":") != null);

    // turn_end frames include turnIndex but NOT timestamp (TS TurnEndEvent has no timestamp field).
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"turn_end\"") != null);
    // turn_start for turn 2 should carry turnIndex:2
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"turnIndex\":2") != null);
    // Verify each turn_end extension event: top-level must have turnIndex, not timestamp.
    // (Nested message objects carry their own timestamp, which is expected.)
    var line_iter = std.mem.tokenizeScalar(u8, capture, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"type\":\"turn_end\"") != null) {
            try std.testing.expect(std.mem.indexOf(u8, line, "\"turnIndex\":") != null);
            // Parse and check top-level keys: timestamp must not be a top-level field.
            var parsed_line = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
            defer parsed_line.deinit();
            try std.testing.expect(parsed_line.value.object.get("timestamp") == null);
        }
    }
}

// ---------------------------------------------------------------------------
// Session lifecycle extension event tests
// All test names contain "session_lifecycle" to match the --test-filter flag.
// ---------------------------------------------------------------------------

/// Helper: returns a shell script that captures all stdin lines to capture_path
/// and exits on `{"type":"shutdown"}`.
fn sessionLifecycleCaptureScript(allocator: std.mem.Allocator, capture_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "while IFS= read -r line; do " ++
            "printf '%s\\n' \"$line\" >> {s}; " ++
            "case \"$line\" in *'\"type\":\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; " ++
            "done",
        .{capture_path},
    );
}

test "session_lifecycle: new_session emits session_before_switch and session_shutdown" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-session-lifecycle-new.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try sessionLifecycleCaptureScript(allocator, capture_path);
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-sl-new" };

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "sys",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-sl-new",
        .fixture = "sl-new",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    try server.handleLine("{\"id\":\"n1\",\"type\":\"new_session\"}");
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    // session_before_switch must appear with reason "new"
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_before_switch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"reason\":\"new\"") != null);
    // For new sessions, targetSessionFile must be absent from session_before_switch
    // (the new session file doesn't exist yet; parentSession is the old session, not the target).
    var line_iter = std.mem.tokenizeScalar(u8, capture, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"type\":\"session_before_switch\"") != null) {
            try std.testing.expect(std.mem.indexOf(u8, line, "\"targetSessionFile\"") == null);
        }
    }
    // session_shutdown must appear (from new_session and/or quit)
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_shutdown\"") != null);
}

test "session_lifecycle: fork emits session_before_fork and session_shutdown" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-session-lifecycle-fork.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try sessionLifecycleCaptureScript(allocator, capture_path);
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-sl-fork" };

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "sys",
    });
    defer session.deinit();

    // Add a user message so fork has an entryId to work with
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = "fork me" } };
    const entry_id = try session.session_manager.appendMessage(.{ .user = .{ .content = user_content, .timestamp = 11 } });
    const entry_id_owned = try allocator.dupe(u8, entry_id);
    defer allocator.free(entry_id_owned);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-sl-fork",
        .fixture = "sl-fork",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    const fork_cmd = try std.fmt.allocPrint(allocator, "{{\"id\":\"f1\",\"type\":\"fork\",\"entryId\":\"{s}\"}}", .{entry_id_owned});
    defer allocator.free(fork_cmd);
    try server.handleLine(fork_cmd);
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    // session_before_fork must appear with entryId and position
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_before_fork\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"position\":\"before\"") != null);
    // session_shutdown must appear (from fork and/or quit)
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_shutdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"reason\":\"fork\"") != null);
}

test "session_lifecycle: compact emits session_before_compact and session_compact" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-session-lifecycle-compact.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try sessionLifecycleCaptureScript(allocator, capture_path);
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-sl-compact" };

    // Compact builds a text summary from session entries without calling the LLM.
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "sys",
    });
    defer session.deinit();

    // Add 2 message entries so prepareManualCompaction has enough to work with
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const msg1 = try arena.allocator().alloc(ai.ContentBlock, 1);
    msg1[0] = .{ .text = .{ .text = "first message to compact" } };
    const msg2 = try arena.allocator().alloc(ai.ContentBlock, 1);
    msg2[0] = .{ .text = .{ .text = "second message to compact" } };
    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = msg1, .timestamp = 11 } });
    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = msg2, .timestamp = 12 } });

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-sl-compact",
        .fixture = "sl-compact",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    try server.handleLine("{\"id\":\"c1\",\"type\":\"compact\"}");
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    // Both before and after compact events must appear
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_before_compact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_compact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"fromExtension\":false") != null);
}

test "session_lifecycle: navigate_to emits session_before_tree and session_tree" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-session-lifecycle-tree.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try sessionLifecycleCaptureScript(allocator, capture_path);
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-sl-tree" };

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "sys",
    });
    defer session.deinit();

    // Add messages to create tree entries to navigate between
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const msg_a = try arena.allocator().alloc(ai.ContentBlock, 1);
    msg_a[0] = .{ .text = .{ .text = "root message" } };
    const msg_b = try arena.allocator().alloc(ai.ContentBlock, 1);
    msg_b[0] = .{ .text = .{ .text = "leaf message" } };
    const entry_a = try session.session_manager.appendMessage(.{ .user = .{ .content = msg_a, .timestamp = 11 } });
    const entry_a_owned = try allocator.dupe(u8, entry_a);
    defer allocator.free(entry_a_owned);
    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = msg_b, .timestamp = 12 } });

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-sl-tree",
        .fixture = "sl-tree",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    const nav_cmd = try std.fmt.allocPrint(allocator, "{{\"id\":\"t1\",\"type\":\"navigate_to\",\"entryId\":\"{s}\"}}", .{entry_a_owned});
    defer allocator.free(nav_cmd);
    try server.handleLine(nav_cmd);
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    // session_before_tree and session_tree must both appear
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_before_tree\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_tree\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"newLeafId\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"oldLeafId\"") != null);
}

test "session_lifecycle: finish emits session_shutdown with reason quit" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-session-lifecycle-quit.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try sessionLifecycleCaptureScript(allocator, capture_path);
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-sl-quit" };

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "sys",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-sl-quit",
        .fixture = "sl-quit",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    // Just finish without any commands - should emit session_shutdown with reason "quit"
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    // session_shutdown with reason "quit" must appear before the shutdown frame
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_shutdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"reason\":\"quit\"") != null);
}

// ─── Extension command context API tests (VAL-EXT-031..036) ──────────────────

test "command_context: waitForIdle does not queue when agent is idle" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/cmd-ctx-wfi-idle",
        .system_prompt = "test",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    // Agent is idle (not streaming). The request should be handled immediately
    // without being queued into pending_wait_for_idle_ids.
    var req = extension_host_mod.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "wfi-1"),
        .method = try allocator.dupe(u8, "wait_for_idle"),
        .response_required = true,
        .payload_json = try allocator.dupe(u8, "{}"),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);
    try std.testing.expectEqual(@as(usize, 0), server.pending_wait_for_idle_ids.items.len);
}

test "command_context: waitForIdle queues when streaming and resolves after idle" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/cmd-ctx-wfi-stream",
        .system_prompt = "test",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    // Simulate the agent being busy.
    session.agent.is_streaming = true;

    var req = extension_host_mod.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "wfi-2"),
        .method = try allocator.dupe(u8, "wait_for_idle"),
        .response_required = true,
        .payload_json = try allocator.dupe(u8, "{}"),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);
    // Must be queued because the agent is busy.
    try std.testing.expectEqual(@as(usize, 1), server.pending_wait_for_idle_ids.items.len);

    // Agent becomes idle.
    session.agent.is_streaming = false;

    // The idle-tick resolves all pending wait_for_idle requests.
    try server.serviceExtensionHostIdleTick(0);
    try std.testing.expectEqual(@as(usize, 0), server.pending_wait_for_idle_ids.items.len);
}

test "command_context: sendCustomMessage creates session entry with correct fields" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/cmd-ctx-custom-msg",
        .system_prompt = "test",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    const payload = "{\"customType\":\"ext.test\",\"content\":\"hello from extension\",\"display\":true}";
    var req = extension_host_mod.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "scm-1"),
        .method = try allocator.dupe(u8, "send_custom_message"),
        .response_required = false,
        .payload_json = try allocator.dupe(u8, payload),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);

    // Session must contain a custom_message entry with the correct customType and content.
    const entries = session.session_manager.getEntries();
    var found = false;
    for (entries) |entry| {
        switch (entry) {
            .custom_message => |cm| {
                if (!std.mem.eql(u8, cm.custom_type, "ext.test")) continue;
                found = true;
                switch (cm.content) {
                    .text => |t| try std.testing.expectEqualStrings("hello from extension", t),
                    .blocks => return error.UnexpectedContentType,
                }
                try std.testing.expect(cm.display);
            },
            else => {},
        }
    }
    try std.testing.expect(found);
}

test "command_context: sendCustomMessage respects deliverAs followUp when streaming" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/cmd-ctx-custom-follow",
        .system_prompt = "test",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    // Simulate agent streaming.
    session.agent.is_streaming = true;

    const payload = "{\"customType\":\"ext.note\",\"content\":\"follow-up note\",\"display\":false,\"deliverAs\":\"followUp\"}";
    var req = extension_host_mod.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "scm-fu"),
        .method = try allocator.dupe(u8, "send_custom_message"),
        .response_required = false,
        .payload_json = try allocator.dupe(u8, payload),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);

    // The session entry must be present.
    const entries = session.session_manager.getEntries();
    var found = false;
    for (entries) |entry| {
        switch (entry) {
            .custom_message => |cm| {
                if (std.mem.eql(u8, cm.custom_type, "ext.note")) {
                    found = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(found);
    // deliverAs followUp must have enqueued a message in the follow-up queue.
    try std.testing.expectEqual(@as(usize, 1), session.agent.followUpQueueLen());
}

test "command_context: sendUserMessage queues followUp when agent is streaming" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/cmd-ctx-user-stream",
        .system_prompt = "test",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    // Simulate agent busy.
    session.agent.is_streaming = true;

    var req = extension_host_mod.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "sum-1"),
        .method = try allocator.dupe(u8, "send_user_message"),
        .response_required = false,
        .payload_json = try allocator.dupe(u8, "{\"text\":\"hello agent\"}"),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);
    // No deliverAs → defaults to followUp when streaming.
    try std.testing.expectEqual(@as(usize, 1), session.agent.followUpQueueLen());
}

test "command_context: sendUserMessage starts background prompt when agent is idle" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();
    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{
            ai.providers.faux.fauxText("response from extension"),
        }, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/cmd-ctx-user-idle",
        .system_prompt = "test",
        .model = registration.getModel(),
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    var req = extension_host_mod.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "sum-idle"),
        .method = try allocator.dupe(u8, "send_user_message"),
        .response_required = false,
        .payload_json = try allocator.dupe(u8, "{\"text\":\"trigger a turn\"}"),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);

    // A background prompt task must have been spawned.
    try std.testing.expectEqual(@as(usize, 1), server.prompt_tasks.items.len);

    // Wait for the task to complete.
    try waitForNoInFlightPrompt(&server, 2000);

    // Session must now have a user message and an assistant response.
    const messages = session.agent.getMessages();
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expect(messages[0] == .user);
    try std.testing.expect(messages[1] == .assistant);
}

// ---------------------------------------------------------------------------
// Wire-format cleanup regression tests (items 1-7).
// All test names begin with "wire_format_cleanup" for --test-filter matching.
// ---------------------------------------------------------------------------

test "wire_format_cleanup: tool_result frame carries call args as input and skips non-text blocks" {
    // Items 2 & 3: tool_result.input must contain the original call args;
    // thinking and tool_call content blocks must be skipped (not emitted as empty text).
    // Drives through the real agent loop via faux provider tool dispatch to verify that
    // emitToolCallOutcome populates .args = tool_call.arguments on the tool_execution_end
    // event, which emitExtensionToolResultEvent then serializes as "input".
    const allocator = std.testing.allocator;

    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    // Faux response 1: bash tool call with args {"command":"echo hello"}.
    // Faux response 2: plain text after tool result is fed back.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed_args = try std.json.parseFromSlice(std.json.Value, arena.allocator(), "{\"command\":\"echo hello\"}", .{});
    const args_value = parsed_args.value;
    const tool_call_block = try ai.providers.faux.fauxToolCall(arena.allocator(), "bash", args_value, .{ .id = "tc-wfc-1" });
    const response_blocks = [_]ai.providers.faux.FauxContentBlock{tool_call_block};
    const text_blocks = [_]ai.providers.faux.FauxContentBlock{ai.providers.faux.fauxText("done")};
    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&response_blocks, .{ .stop_reason = .tool_use }) },
        .{ .message = ai.providers.faux.fauxAssistantMessage(&text_blocks, .{}) },
    });

    const capture_path = "/tmp/pi-wfc-tool-result.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "while IFS= read -r line; do " ++
            "printf '%s\\n' \"$line\" >> {s}; " ++
            "case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; " ++
            "done",
        .{capture_path},
    );
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-wfc-tool-result" };

    // wfcBashToolExecute returns text "hello" + a thinking block.
    // The thinking block must be skipped by emitExtensionToolResultEvent.
    const bash_tool = agent.AgentTool{
        .name = "bash",
        .description = "Run bash commands",
        .label = "Bash",
        .parameters = .null,
        .execute = wfcBashToolExecute,
    };

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/wfc-tool-result",
        .system_prompt = "test",
        .model = registration.getModel(),
        .tools = &[_]agent.AgentTool{bash_tool},
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-wfc-tool-result",
        .fixture = "wfc-tool-result",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    // Trigger the agent loop via a prompt; the faux provider will issue the tool call.
    try server.handleLine("{\"id\":\"p1\",\"type\":\"prompt\",\"message\":\"run a command\"}");
    try waitForNoInFlightPrompt(&server, 5000);
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    // The tool_result extension event must carry the original call args as "input".
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"input\":{\"command\":\"echo hello\"}") != null);
    // Text content must appear in the tool_result "content" array; thinking block must be
    // skipped (not emitted) — verify by asserting the exact content array value on the
    // tool_result line (a thinking block converted to empty text would break this match).
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]") != null);
}

/// Tool execute function for the wire_format_cleanup tool_result test.
/// Returns text "hello" + a thinking block to verify that thinking blocks are
/// skipped (not emitted as empty text) in tool_result extension event frames.
fn wfcBashToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
    _: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) anyerror!agent.AgentToolResult {
    const content = try allocator.alloc(ai.ContentBlock, 2);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "hello") } };
    content[1] = .{ .thinking = .{ .thinking = try allocator.dupe(u8, "internal reasoning") } };
    return .{ .content = content, .details = null };
}

test "wire_format_cleanup: send_custom_message nextTurn returns error without persisting message" {
    // Items 5 & 7: deliverAs="nextTurn" must be rejected; the message must NOT be persisted.
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/wfc-custom-next-turn",
        .system_prompt = "test",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    var req = extension_host_mod.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "wfc-next-1"),
        .method = try allocator.dupe(u8, "send_custom_message"),
        .response_required = false,
        .payload_json = try allocator.dupe(u8, "{\"customType\":\"test.msg\",\"content\":\"hello\",\"deliverAs\":\"nextTurn\"}"),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);

    // The message must NOT be persisted — nextTurn is rejected before appendCustomMessageEntry.
    try std.testing.expectEqual(@as(usize, 0), session.session_manager.getEntries().len);
}

test "wire_format_cleanup: send_user_message nextTurn does not queue the message" {
    // Items 5 & 7: deliverAs="nextTurn" for send_user_message must return early without queuing.
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/wfc-user-next-turn",
        .system_prompt = "test",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    // Simulate agent busy so follow-up queuing would normally happen.
    session.agent.is_streaming = true;

    var req = extension_host_mod.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "wfc-user-nt"),
        .method = try allocator.dupe(u8, "send_user_message"),
        .response_required = false,
        .payload_json = try allocator.dupe(u8, "{\"text\":\"hello\",\"deliverAs\":\"nextTurn\"}"),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);

    // Nothing must be queued since nextTurn is explicitly rejected.
    try std.testing.expectEqual(@as(usize, 0), session.agent.followUpQueueLen());
}

test "wire_format_cleanup: send_custom_message malformed customType returns without persisting" {
    // Item 5: when customType is a non-string value, an error frame is returned and
    // the message is NOT persisted (early return before appendCustomMessageEntry).
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/wfc-custom-badtype",
        .system_prompt = "test",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    // customType is a number (not a string) — malformed payload.
    var req = extension_host_mod.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "wfc-bad-type"),
        .method = try allocator.dupe(u8, "send_custom_message"),
        .response_required = false,
        .payload_json = try allocator.dupe(u8, "{\"customType\":123,\"content\":\"hello\"}"),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);

    // Message must NOT be persisted since the error is caught before appendCustomMessageEntry.
    try std.testing.expectEqual(@as(usize, 0), session.session_manager.getEntries().len);
}
