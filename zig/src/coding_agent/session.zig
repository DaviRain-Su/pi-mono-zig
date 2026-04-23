const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const session_manager = @import("session_manager.zig");

pub const AgentSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    system_prompt: []const u8,
    agent: agent.Agent,
    session_manager: *session_manager.SessionManager,
    subscriber: agent.AgentSubscriber,
    subscribed: bool,

    pub const CreateOptions = struct {
        cwd: []const u8,
        system_prompt: []const u8 = "",
        model: ?ai.Model = null,
        thinking_level: agent.ThinkingLevel = .off,
        tools: []const agent.AgentTool = &.{},
        session_dir: ?[]const u8 = null,
    };

    pub const OpenOptions = struct {
        session_file: []const u8,
        cwd_override: ?[]const u8 = null,
        system_prompt: []const u8 = "",
        model: ?ai.Model = null,
        thinking_level: agent.ThinkingLevel = .off,
        tools: []const agent.AgentTool = &.{},
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

        var instance = try initWithManager(allocator, io, options.cwd, options.system_prompt, options.model, options.thinking_level, options.tools, manager);
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
            options.thinking_level,
            options.tools,
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

    fn initWithManager(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        system_prompt: []const u8,
        model: ?ai.Model,
        thinking_level: agent.ThinkingLevel,
        tools: []const agent.AgentTool,
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
        .off,
        &.{},
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
