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