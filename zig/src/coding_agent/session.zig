const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const session_manager = @import("session_manager.zig");

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
    compaction_settings: CompactionSettings,
    retry_settings: RetrySettings,
    retry_attempt: u32,
    overflow_recovery_attempted: bool,
    compaction_active: std.atomic.Value(bool),

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
            manager,
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
            manager,
        );
    }

    pub fn deinit(self: *AgentSession) void {
        if (self.subscribed) {
            _ = self.agent.unsubscribe(self.subscriber);
            self.subscribed = false;
        }
        self.agent.deinit();
        self.session_manager.deinit();
        self.allocator.destroy(self.session_manager);
    }

    pub fn prompt(self: *AgentSession, input: anytype) !void {
        try self.agent.prompt(input);
        try self.runPostPromptMaintenance();
    }

    pub fn promptWithAcceptedCallback(
        self: *AgentSession,
        input: anytype,
        accepted_callback: ?agent.PromptAcceptedCallback,
    ) !void {
        try self.agent.promptWithAcceptedCallback(input, accepted_callback);
        try self.runPostPromptMaintenance();
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
        return try self.runCompaction(custom_instructions);
    }

    pub fn navigateTo(self: *AgentSession, entry_id: ?[]const u8) !void {
        if (entry_id) |id| {
            try self.session_manager.branch(id);
        } else {
            self.session_manager.resetLeaf();
        }
        try self.reloadFromSession();
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
        _ = try self.runCompaction(null);
        try self.agent.continueRun();
        return true;
    }

    fn handleThresholdCompaction(self: *AgentSession, last_assistant: ai.AssistantMessage) !bool {
        _ = last_assistant;
        if (!self.compaction_settings.enabled) return false;
        const context_window = self.agent.getModel().context_window;
        if (context_window == 0) return false;
        if (!shouldAutoCompact(estimateContextTokens(self.agent.getMessages()), context_window, self.compaction_settings)) return false;
        _ = self.runCompaction(null) catch |err| switch (err) {
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
            self.retry_attempt = 0;
            return false;
        }

        _ = removeLastAssistantError(self);
        try sleepMilliseconds(self.io, exponentialBackoffMs(self.retry_settings.base_delay_ms, self.retry_attempt));
        try self.agent.continueRun();
        return true;
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
        manager: *session_manager.SessionManager,
    ) !AgentSession {
        var session_context = try manager.buildSessionContext(allocator);
        defer session_context.deinit(allocator);

        const effective_model = resolveModel(model, session_context.model);
        const effective_thinking_level = if (session_context.thinking_level != .off)
            session_context.thinking_level
        else
            thinking_level;

        var agent_instance = try agent.Agent.init(allocator, .{
            .system_prompt = system_prompt,
            .model = effective_model,
            .api_key = api_key,
            .session_id = manager.getSessionId(),
            .thinking_level = effective_thinking_level,
            .tools = tools,
            .messages = session_context.messages,
            .io = io,
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
            .compaction_settings = compaction_settings,
            .retry_settings = retry_settings,
            .retry_attempt = 0,
            .overflow_recovery_attempted = false,
            .compaction_active = std.atomic.Value(bool).init(false),
        };

        try instance.agent.subscribe(instance.subscriber);
        instance.subscribed = true;
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
};

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

    return containsIgnoreCase(error_message, "overloaded") or
        containsIgnoreCase(error_message, "rate limit") or
        containsIgnoreCase(error_message, "too many requests") or
        containsIgnoreCase(error_message, "service unavailable") or
        containsIgnoreCase(error_message, "server error") or
        containsIgnoreCase(error_message, "internal error") or
        containsIgnoreCase(error_message, "network error") or
        containsIgnoreCase(error_message, "connection error") or
        containsIgnoreCase(error_message, "connection refused") or
        containsIgnoreCase(error_message, "connection lost") or
        containsIgnoreCase(error_message, "socket hang up") or
        containsIgnoreCase(error_message, "fetch failed") or
        containsIgnoreCase(error_message, "timeout") or
        containsIgnoreCase(error_message, "timed out") or
        containsIgnoreCase(error_message, "429") or
        containsIgnoreCase(error_message, "500") or
        containsIgnoreCase(error_message, "502") or
        containsIgnoreCase(error_message, "503") or
        containsIgnoreCase(error_message, "504");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
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
                }
            }
            if (assistant_message.tool_calls) |tool_calls| {
                for (tool_calls) |tool_call| {
                    chars += tool_call.name.len;
                    chars += jsonValueCharCount(tool_call.arguments);
                }
            }
        },
        .tool_result => |tool_result| {
            for (tool_result.content) |block| {
                switch (block) {
                    .text => |text| chars += text.text.len,
                    .image => chars += 4800,
                    .thinking => |thinking| chars += thinking.thinking.len,
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
                if (assistant_message.stop_reason == .error_reason) continue;
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
    errdefer std.testing.allocator.destroy(manager);
    manager.* = try session_manager.SessionManager.inMemory(std.testing.allocator, std.testing.io, "/tmp/project");
    errdefer manager.deinit();

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
        manager,
    );
    defer session.deinit();

    try session.navigateTo(main_id);
    try std.testing.expectEqual(@as(usize, 2), session.agent.getMessages().len);
    try std.testing.expectEqualStrings("main", session.agent.getMessages()[1].assistant.content[0].text.text);

    try session.navigateTo(branch_id);
    try std.testing.expectEqual(@as(usize, 2), session.agent.getMessages().len);
    try std.testing.expectEqualStrings("branch", session.agent.getMessages()[1].assistant.content[0].text.text);
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
