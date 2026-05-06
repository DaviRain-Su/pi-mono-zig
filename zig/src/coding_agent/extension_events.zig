const std = @import("std");

/// Extension event types mirroring TypeScript ExtensionAPI.on() events
pub const ExtensionEventType = enum {
    // Resource events
    resources_discover,
    // Session events
    session_start,
    session_before_switch,
    session_before_fork,
    session_before_compact,
    session_compact,
    session_shutdown,
    session_before_tree,
    session_tree,
    // Agent events
    before_agent_start,
    agent_start,
    agent_end,
    turn_start,
    turn_end,
    // Message events
    message_start,
    message_update,
    message_end,
    // Tool events
    tool_execution_start,
    tool_execution_update,
    tool_execution_end,
    tool_call,
    tool_result,
    user_bash,
    // Context/Provider events
    context,
    before_provider_request,
    after_provider_response,
    // Model events
    model_select,
    thinking_level_select,
    // Input events
    input,
};

/// Generic extension event
pub const ExtensionEvent = union(ExtensionEventType) {
    resources_discover: ResourcesDiscoverEvent,
    session_start: SessionStartEvent,
    session_before_switch: SessionBeforeSwitchEvent,
    session_before_fork: SessionBeforeForkEvent,
    session_before_compact: SessionBeforeCompactEvent,
    session_compact: SessionCompactEvent,
    session_shutdown: SessionShutdownEvent,
    session_before_tree: SessionBeforeTreeEvent,
    session_tree: SessionTreeEvent,
    before_agent_start: BeforeAgentStartEvent,
    agent_start: AgentStartEvent,
    agent_end: AgentEndEvent,
    turn_start: TurnStartEvent,
    turn_end: TurnEndEvent,
    message_start: MessageStartEvent,
    message_update: MessageUpdateEvent,
    message_end: MessageEndEvent,
    tool_execution_start: ToolExecutionStartEvent,
    tool_execution_update: ToolExecutionUpdateEvent,
    tool_execution_end: ToolExecutionEndEvent,
    tool_call: ToolCallEvent,
    tool_result: ToolResultEvent,
    user_bash: UserBashEvent,
    context: ContextEvent,
    before_provider_request: BeforeProviderRequestEvent,
    after_provider_response: AfterProviderResponseEvent,
    model_select: ModelSelectEvent,
    thinking_level_select: ThinkingLevelSelectEvent,
    input: InputEvent,
};

// Resource events
pub const ResourcesDiscoverEvent = struct {
    cwd: []const u8,
    reason: []const u8, // "startup" | "reload"
};

// Session events
pub const SessionStartEvent = struct {
    reason: []const u8, // "startup" | "reload" | "new" | "resume" | "fork"
    previous_session_file: ?[]const u8 = null,
};

pub const SessionBeforeSwitchEvent = struct {
    reason: []const u8, // "new" | "resume"
    target_session_file: ?[]const u8 = null,
};

pub const SessionBeforeForkEvent = struct {
    entry_id: []const u8,
    position: []const u8, // "before" | "at"
};

pub const SessionBeforeCompactEvent = struct {
    custom_instructions: ?[]const u8 = null,
};

pub const SessionCompactEvent = struct {
    from_extension: bool = false,
};

pub const SessionShutdownEvent = struct {
    reason: []const u8, // "quit" | "reload" | "new" | "resume" | "fork"
    target_session_file: ?[]const u8 = null,
};

pub const SessionBeforeTreeEvent = struct {
    target_id: []const u8,
};

pub const SessionTreeEvent = struct {
    target_id: []const u8,
};

// Agent events
pub const BeforeAgentStartEvent = struct {
    messages: []const []const u8,
};

pub const AgentStartEvent = struct {};
pub const AgentEndEvent = struct {
    stop_reason: ?[]const u8 = null,
};

pub const TurnStartEvent = struct {
    message: []const u8,
};

pub const TurnEndEvent = struct {
    message: []const u8,
};

// Message events
pub const MessageStartEvent = struct {
    message_id: []const u8,
};

pub const MessageUpdateEvent = struct {
    message_id: []const u8,
    delta: []const u8,
};

pub const MessageEndEvent = struct {
    message_id: []const u8,
    final_message: []const u8,
};

// Tool events
pub const ToolExecutionStartEvent = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    input: []const u8,
};

pub const ToolExecutionUpdateEvent = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    update: []const u8,
};

pub const ToolExecutionEndEvent = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    result: []const u8,
};

pub const ToolCallEvent = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    input: []const u8,
};

pub const ToolResultEvent = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    result: []const u8,
    content: []const []const u8 = &.{},
    details: ?[]const u8 = null,
    is_error: bool = false,
};

pub const UserBashEvent = struct {
    command: []const u8,
};

// Context/Provider events
pub const ContextEvent = struct {
    messages: []const []const u8,
};

pub const BeforeProviderRequestEvent = struct {
    model: []const u8,
    messages: []const []const u8,
};

pub const AfterProviderResponseEvent = struct {
    model: []const u8,
    response: []const u8,
};

// Model events
pub const ModelSelectEvent = struct {
    model: []const u8,
    previous_model: ?[]const u8 = null,
};

pub const ThinkingLevelSelectEvent = struct {
    level: []const u8,
    previous_level: ?[]const u8 = null,
};

// Input events
pub const InputEvent = struct {
    data: []const u8,
};

/// Event handler function type
pub const EventHandler = *const fn (event: ExtensionEvent) anyerror!void;

pub const ResourcesDiscoverResult = struct {
    skill_paths: []const []const u8 = &.{},
    prompt_paths: []const []const u8 = &.{},
    theme_paths: []const []const u8 = &.{},
};

pub const ResourcePathResult = struct {
    path: []u8,
    extension_path: []u8,

    fn deinit(self: *ResourcePathResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

pub const ResourcesDiscoverCombinedResult = struct {
    skill_paths: []ResourcePathResult,
    prompt_paths: []ResourcePathResult,
    theme_paths: []ResourcePathResult,

    pub fn deinit(self: *ResourcesDiscoverCombinedResult, allocator: std.mem.Allocator) void {
        for (self.skill_paths) |*path| path.deinit(allocator);
        allocator.free(self.skill_paths);
        for (self.prompt_paths) |*path| path.deinit(allocator);
        allocator.free(self.prompt_paths);
        for (self.theme_paths) |*path| path.deinit(allocator);
        allocator.free(self.theme_paths);
        self.* = undefined;
    }
};

pub const InputAction = enum {
    @"continue",
    transform,
    handled,
};

pub const InputEventResult = struct {
    action: InputAction,
    text: ?[]const u8 = null,
};

pub const OwnedInputEventResult = struct {
    action: InputAction,
    text: ?[]u8 = null,

    pub fn deinit(self: *OwnedInputEventResult, allocator: std.mem.Allocator) void {
        if (self.text) |text| allocator.free(text);
        self.* = undefined;
    }
};

pub const ToolResultPatch = struct {
    content: ?[]const []const u8 = null,
    details: ?[]const u8 = null,
    is_error: ?bool = null,
};

pub const ToolResultCombinedResult = struct {
    content: []const []const u8,
    details: ?[]const u8,
    is_error: bool,
};

pub const EventHandlerResult = union(enum) {
    none,
    resources_discover: ResourcesDiscoverResult,
    input: InputEventResult,
    tool_result: ToolResultPatch,
};

pub const ExtensionError = struct {
    extension_path: []u8,
    event: []u8,
    @"error": []u8,

    fn deinit(self: *ExtensionError, allocator: std.mem.Allocator) void {
        allocator.free(self.extension_path);
        allocator.free(self.event);
        allocator.free(self.@"error");
        self.* = undefined;
    }
};

pub const ResultEventHandler = *const fn (event: ExtensionEvent) anyerror!EventHandlerResult;

/// Event bus for extension event handling
pub const EventBus = struct {
    allocator: std.mem.Allocator,
    handlers: std.ArrayList(HandlerEntry),

    const HandlerEntry = struct {
        event_type: ExtensionEventType,
        handler: EventHandler,
        extension_path: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) EventBus {
        return .{
            .allocator = allocator,
            .handlers = std.ArrayList(HandlerEntry).empty,
        };
    }

    pub fn deinit(self: *EventBus) void {
        for (self.handlers.items) |*entry| {
            self.allocator.free(entry.extension_path);
        }
        self.handlers.deinit(self.allocator);
        self.* = undefined;
    }

    /// Subscribe to an event type
    pub fn on(self: *EventBus, event_type: ExtensionEventType, handler: EventHandler, extension_path: []const u8) !void {
        try self.handlers.append(self.allocator, .{
            .event_type = event_type,
            .handler = handler,
            .extension_path = try self.allocator.dupe(u8, extension_path),
        });
    }

    /// Remove all handlers for a given extension path
    pub fn clearExtensionHandlers(self: *EventBus, extension_path: []const u8) void {
        var i: usize = self.handlers.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.handlers.items[i].extension_path, extension_path)) {
                self.allocator.free(self.handlers.items[i].extension_path);
                _ = self.handlers.orderedRemove(i);
            }
        }
    }

    /// Emit an event to all subscribed handlers
    pub fn emit(self: *EventBus, event: ExtensionEvent) !void {
        const event_type = std.meta.activeTag(event);
        for (self.handlers.items) |entry| {
            if (entry.event_type == event_type) {
                try entry.handler(event);
            }
        }
    }

    /// Check if there are any handlers for a given event type
    pub fn hasHandlers(self: *const EventBus, event_type: ExtensionEventType) bool {
        for (self.handlers.items) |entry| {
            if (entry.event_type == event_type) return true;
        }
        return false;
    }
};

/// Result-returning event bus used by low-architecture parity tests and
/// host bridges that need the same observable aggregation contract as the
/// TypeScript extension runner. Handler order is extension registration
/// order, errors are recorded with TypeScript-compatible fields, and
/// successful handlers continue after non-terminal failures.
pub const ResultEventBus = struct {
    allocator: std.mem.Allocator,
    handlers: std.ArrayList(HandlerEntry),
    errors: std.ArrayList(ExtensionError),

    const HandlerEntry = struct {
        event_type: ExtensionEventType,
        handler: ResultEventHandler,
        extension_path: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) ResultEventBus {
        return .{
            .allocator = allocator,
            .handlers = std.ArrayList(HandlerEntry).empty,
            .errors = std.ArrayList(ExtensionError).empty,
        };
    }

    pub fn deinit(self: *ResultEventBus) void {
        for (self.handlers.items) |*entry| {
            self.allocator.free(entry.extension_path);
        }
        self.handlers.deinit(self.allocator);
        for (self.errors.items) |*err| err.deinit(self.allocator);
        self.errors.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn on(self: *ResultEventBus, event_type: ExtensionEventType, handler: ResultEventHandler, extension_path: []const u8) !void {
        try self.handlers.append(self.allocator, .{
            .event_type = event_type,
            .handler = handler,
            .extension_path = try self.allocator.dupe(u8, extension_path),
        });
    }

    pub fn emitResourcesDiscover(self: *ResultEventBus, cwd: []const u8, reason: []const u8) !ResourcesDiscoverCombinedResult {
        var skill_paths = std.ArrayList(ResourcePathResult).empty;
        errdefer deinitResourcePathList(self.allocator, &skill_paths);
        var prompt_paths = std.ArrayList(ResourcePathResult).empty;
        errdefer deinitResourcePathList(self.allocator, &prompt_paths);
        var theme_paths = std.ArrayList(ResourcePathResult).empty;
        errdefer deinitResourcePathList(self.allocator, &theme_paths);

        const event = ExtensionEvent{ .resources_discover = .{ .cwd = cwd, .reason = reason } };
        for (self.handlers.items) |entry| {
            if (entry.event_type != .resources_discover) continue;
            const handler_result = entry.handler(event) catch |err| {
                try self.recordError(entry.extension_path, .resources_discover, err);
                continue;
            };
            switch (handler_result) {
                .resources_discover => |result| {
                    try appendResourcePaths(self.allocator, &skill_paths, result.skill_paths, entry.extension_path);
                    try appendResourcePaths(self.allocator, &prompt_paths, result.prompt_paths, entry.extension_path);
                    try appendResourcePaths(self.allocator, &theme_paths, result.theme_paths, entry.extension_path);
                },
                .none, .input, .tool_result => {},
            }
        }

        return .{
            .skill_paths = try skill_paths.toOwnedSlice(self.allocator),
            .prompt_paths = try prompt_paths.toOwnedSlice(self.allocator),
            .theme_paths = try theme_paths.toOwnedSlice(self.allocator),
        };
    }

    pub fn emitInput(self: *ResultEventBus, data: []const u8) !OwnedInputEventResult {
        var current = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(current);
        var modified = false;

        for (self.handlers.items) |entry| {
            if (entry.event_type != .input) continue;
            const event = ExtensionEvent{ .input = .{ .data = current } };
            const handler_result = entry.handler(event) catch |err| {
                try self.recordError(entry.extension_path, .input, err);
                continue;
            };
            switch (handler_result) {
                .input => |result| switch (result.action) {
                    .handled => {
                        self.allocator.free(current);
                        return .{ .action = .handled };
                    },
                    .transform => {
                        if (result.text) |text| {
                            const next = try self.allocator.dupe(u8, text);
                            self.allocator.free(current);
                            current = next;
                            modified = true;
                        }
                    },
                    .@"continue" => {},
                },
                .none, .resources_discover, .tool_result => {},
            }
        }

        if (modified) {
            return .{ .action = .transform, .text = current };
        }
        self.allocator.free(current);
        return .{ .action = .@"continue" };
    }

    pub fn emitToolResult(self: *ResultEventBus, event: ToolResultEvent) !?ToolResultCombinedResult {
        var current_content = event.content;
        var current_details = event.details;
        var current_is_error = event.is_error;
        var modified = false;

        for (self.handlers.items) |entry| {
            if (entry.event_type != .tool_result) continue;
            const current_event = ExtensionEvent{ .tool_result = .{
                .tool_name = event.tool_name,
                .tool_call_id = event.tool_call_id,
                .result = event.result,
                .content = current_content,
                .details = current_details,
                .is_error = current_is_error,
            } };
            const handler_result = entry.handler(current_event) catch |err| {
                try self.recordError(entry.extension_path, .tool_result, err);
                continue;
            };
            switch (handler_result) {
                .tool_result => |patch| {
                    if (patch.content) |content| {
                        current_content = content;
                        modified = true;
                    }
                    if (patch.details) |details| {
                        current_details = details;
                        modified = true;
                    }
                    if (patch.is_error) |is_error| {
                        current_is_error = is_error;
                        modified = true;
                    }
                },
                .none, .resources_discover, .input => {},
            }
        }

        if (!modified) return null;
        return .{
            .content = current_content,
            .details = current_details,
            .is_error = current_is_error,
        };
    }

    fn recordError(self: *ResultEventBus, extension_path: []const u8, event_type: ExtensionEventType, err: anyerror) !void {
        const path_dup = try self.allocator.dupe(u8, extension_path);
        errdefer self.allocator.free(path_dup);
        const event_name_value = eventName(event_type);
        const event_dup = try self.allocator.dupe(u8, event_name_value);
        errdefer self.allocator.free(event_dup);
        const error_dup = try std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)});
        errdefer self.allocator.free(error_dup);
        try self.errors.append(self.allocator, .{
            .extension_path = path_dup,
            .event = event_dup,
            .@"error" = error_dup,
        });
    }
};

fn appendResourcePaths(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(ResourcePathResult),
    paths: []const []const u8,
    extension_path: []const u8,
) !void {
    for (paths) |path| {
        const path_dup = try allocator.dupe(u8, path);
        errdefer allocator.free(path_dup);
        const extension_path_dup = try allocator.dupe(u8, extension_path);
        errdefer allocator.free(extension_path_dup);
        try out.append(allocator, .{ .path = path_dup, .extension_path = extension_path_dup });
    }
}

fn deinitResourcePathList(allocator: std.mem.Allocator, list: *std.ArrayList(ResourcePathResult)) void {
    for (list.items) |*path| path.deinit(allocator);
    list.deinit(allocator);
}

fn eventName(event_type: ExtensionEventType) []const u8 {
    return switch (event_type) {
        .resources_discover => "resources_discover",
        .session_start => "session_start",
        .session_before_switch => "session_before_switch",
        .session_before_fork => "session_before_fork",
        .session_before_compact => "session_before_compact",
        .session_compact => "session_compact",
        .session_shutdown => "session_shutdown",
        .session_before_tree => "session_before_tree",
        .session_tree => "session_tree",
        .before_agent_start => "before_agent_start",
        .agent_start => "agent_start",
        .agent_end => "agent_end",
        .turn_start => "turn_start",
        .turn_end => "turn_end",
        .message_start => "message_start",
        .message_update => "message_update",
        .message_end => "message_end",
        .tool_execution_start => "tool_execution_start",
        .tool_execution_update => "tool_execution_update",
        .tool_execution_end => "tool_execution_end",
        .tool_call => "tool_call",
        .tool_result => "tool_result",
        .user_bash => "user_bash",
        .context => "context",
        .before_provider_request => "before_provider_request",
        .after_provider_response => "after_provider_response",
        .model_select => "model_select",
        .thinking_level_select => "thinking_level_select",
        .input => "input",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

var test_event_received: bool = false;
var test_event_data: []const u8 = "";

fn testHandler(event: ExtensionEvent) !void {
    switch (event) {
        .session_start => |e| {
            test_event_received = true;
            test_event_data = e.reason;
        },
        else => {},
    }
}

test "EventBus subscribes and emits events" {
    test_event_received = false;
    test_event_data = "";

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    try bus.on(.session_start, testHandler, "/tmp/ext.ts");
    try std.testing.expect(bus.hasHandlers(.session_start));
    try std.testing.expect(!bus.hasHandlers(.agent_start));

    const event = ExtensionEvent{
        .session_start = .{
            .reason = "startup",
        },
    };
    try bus.emit(event);

    try std.testing.expect(test_event_received);
    try std.testing.expectEqualStrings("startup", test_event_data);
}

test "EventBus clears extension handlers" {
    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    try bus.on(.session_start, testHandler, "/tmp/ext.ts");
    try std.testing.expect(bus.hasHandlers(.session_start));

    bus.clearExtensionHandlers("/tmp/ext.ts");
    try std.testing.expect(!bus.hasHandlers(.session_start));
}

var g_count: u32 = 0;

fn countingHandler1(_: ExtensionEvent) !void {
    g_count += 1;
}

fn countingHandler2(_: ExtensionEvent) !void {
    g_count += 1;
}

test "EventBus emits to multiple handlers" {
    g_count = 0;

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    try bus.on(.agent_start, countingHandler1, "/tmp/ext1.ts");
    try bus.on(.agent_start, countingHandler2, "/tmp/ext2.ts");

    const event = ExtensionEvent{ .agent_start = .{} };
    try bus.emit(event);

    try std.testing.expectEqual(@as(u32, 2), g_count);
}

const resource_skills_1 = [_][]const u8{"/skills/one"};
const resource_prompts_1 = [_][]const u8{"/prompts/one"};
const resource_themes_2 = [_][]const u8{"/themes/two"};

fn resourcesHandlerOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("/work", event.resources_discover.cwd);
    try std.testing.expectEqualStrings("startup", event.resources_discover.reason);
    return .{ .resources_discover = .{
        .skill_paths = &resource_skills_1,
        .prompt_paths = &resource_prompts_1,
    } };
}

fn resourcesHandlerFailure(_: ExtensionEvent) !EventHandlerResult {
    return error.ResourcesDiscoverFixtureFailure;
}

fn resourcesHandlerTwo(_: ExtensionEvent) !EventHandlerResult {
    return .{ .resources_discover = .{
        .theme_paths = &resource_themes_2,
    } };
}

test "ResultEventBus resources_discover preserves empty success failure and listener order" {
    const allocator = std.testing.allocator;

    var empty_bus = ResultEventBus.init(allocator);
    defer empty_bus.deinit();
    var empty = try empty_bus.emitResourcesDiscover("/work", "startup");
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.skill_paths.len);
    try std.testing.expectEqual(@as(usize, 0), empty.prompt_paths.len);
    try std.testing.expectEqual(@as(usize, 0), empty.theme_paths.len);

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    try bus.on(.resources_discover, resourcesHandlerOne, "/tmp/resources-one.ts");
    try bus.on(.resources_discover, resourcesHandlerFailure, "/tmp/resources-fail.ts");
    try bus.on(.resources_discover, resourcesHandlerTwo, "/tmp/resources-two.ts");

    var result = try bus.emitResourcesDiscover("/work", "startup");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.skill_paths.len);
    try std.testing.expectEqualStrings("/skills/one", result.skill_paths[0].path);
    try std.testing.expectEqualStrings("/tmp/resources-one.ts", result.skill_paths[0].extension_path);
    try std.testing.expectEqual(@as(usize, 1), result.prompt_paths.len);
    try std.testing.expectEqualStrings("/prompts/one", result.prompt_paths[0].path);
    try std.testing.expectEqual(@as(usize, 1), result.theme_paths.len);
    try std.testing.expectEqualStrings("/themes/two", result.theme_paths[0].path);
    try std.testing.expectEqualStrings("/tmp/resources-two.ts", result.theme_paths[0].extension_path);

    try std.testing.expectEqual(@as(usize, 1), bus.errors.items.len);
    try std.testing.expectEqualStrings("/tmp/resources-fail.ts", bus.errors.items[0].extension_path);
    try std.testing.expectEqualStrings("resources_discover", bus.errors.items[0].event);
    try std.testing.expectEqualStrings("ResourcesDiscoverFixtureFailure", bus.errors.items[0].@"error");
}

fn inputTransformOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("base", event.input.data);
    return .{ .input = .{ .action = .transform, .text = "first" } };
}

fn inputTransformTwo(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("first", event.input.data);
    return .{ .input = .{ .action = .transform, .text = "second" } };
}

fn inputHandled(_: ExtensionEvent) !EventHandlerResult {
    return .{ .input = .{ .action = .handled } };
}

test "ResultEventBus input results chain transforms and handled short-circuits" {
    const allocator = std.testing.allocator;

    var empty_bus = ResultEventBus.init(allocator);
    defer empty_bus.deinit();
    var empty = try empty_bus.emitInput("base");
    defer empty.deinit(allocator);
    try std.testing.expect(empty.action == .@"continue");
    try std.testing.expect(empty.text == null);

    var transform_bus = ResultEventBus.init(allocator);
    defer transform_bus.deinit();
    try transform_bus.on(.input, inputTransformOne, "/tmp/input-one.ts");
    try transform_bus.on(.input, inputTransformTwo, "/tmp/input-two.ts");
    var transformed = try transform_bus.emitInput("base");
    defer transformed.deinit(allocator);
    try std.testing.expect(transformed.action == .transform);
    try std.testing.expectEqualStrings("second", transformed.text.?);

    var handled_bus = ResultEventBus.init(allocator);
    defer handled_bus.deinit();
    try handled_bus.on(.input, inputTransformOne, "/tmp/input-one.ts");
    try handled_bus.on(.input, inputHandled, "/tmp/input-handled.ts");
    try handled_bus.on(.input, inputTransformTwo, "/tmp/input-two.ts");
    var handled = try handled_bus.emitInput("base");
    defer handled.deinit(allocator);
    try std.testing.expect(handled.action == .handled);
    try std.testing.expect(handled.text == null);
}

const base_tool_content = [_][]const u8{"base"};
const patched_tool_content = [_][]const u8{"first"};

fn toolResultPatchContent(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("base", event.tool_result.content[0]);
    return .{ .tool_result = .{
        .content = &patched_tool_content,
        .details = "{\"source\":\"ext1\"}",
    } };
}

fn toolResultPatchError(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("first", event.tool_result.content[0]);
    try std.testing.expectEqualStrings("{\"source\":\"ext1\"}", event.tool_result.details.?);
    return .{ .tool_result = .{ .is_error = true } };
}

test "ResultEventBus tool_result returns undefined empty and chains partial patches" {
    const allocator = std.testing.allocator;

    const event = ToolResultEvent{
        .tool_name = "bash",
        .tool_call_id = "call-1",
        .result = "base",
        .content = &base_tool_content,
        .details = "{\"initial\":true}",
        .is_error = false,
    };

    var empty_bus = ResultEventBus.init(allocator);
    defer empty_bus.deinit();
    const empty = try empty_bus.emitToolResult(event);
    try std.testing.expect(empty == null);

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    try bus.on(.tool_result, toolResultPatchContent, "/tmp/tool-result-one.ts");
    try bus.on(.tool_result, toolResultPatchError, "/tmp/tool-result-two.ts");

    const patched = (try bus.emitToolResult(event)).?;
    try std.testing.expectEqual(@as(usize, 1), patched.content.len);
    try std.testing.expectEqualStrings("first", patched.content[0]);
    try std.testing.expectEqualStrings("{\"source\":\"ext1\"}", patched.details.?);
    try std.testing.expect(patched.is_error);
}
