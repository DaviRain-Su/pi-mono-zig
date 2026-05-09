const std = @import("std");
const agent = @import("agent");
const native_process = @import("native_process.zig");
const capability = @import("capability.zig");

/// VTable for host API operations exposed to native extensions.
/// Each function receives an opaque context pointer (the concrete host API
/// implementation) and performs capability enforcement + real I/O.
pub const HostApiVTable = struct {
    readFile: *const fn (ctx: *anyopaque, path: []const u8) anyerror![]u8,
    writeFile: *const fn (ctx: *anyopaque, path: []const u8, contents: []const u8) anyerror!void,
    spawnProcess: *const fn (ctx: *anyopaque, options: native_process.ProcessOptions) anyerror!native_process.ProcessResult,
    readEnv: *const fn (ctx: *anyopaque, name: []const u8) anyerror![]u8,
    requestNetwork: *const fn (ctx: *anyopaque, url: []const u8) anyerror!void,
    runShell: *const fn (ctx: *anyopaque, command: []const u8) anyerror!void,
    callModel: *const fn (ctx: *anyopaque, model: []const u8, payload_json: []const u8) anyerror!void,
    readSession: *const fn (ctx: *anyopaque, session_id: []const u8) anyerror!void,
    writeSession: *const fn (ctx: *anyopaque, session_id: []const u8, payload_json: []const u8) anyerror!void,
    notifyUi: *const fn (ctx: *anyopaque, payload_json: []const u8) anyerror!void,
    useTool: *const fn (ctx: *anyopaque, name: []const u8, payload_json: []const u8) anyerror!void,
    spawnAgent: *const fn (ctx: *anyopaque, task_json: []const u8) anyerror!void,
    delegateAgent: *const fn (ctx: *anyopaque, task_json: []const u8) anyerror!void,
};

/// Context passed to native extension tool execute functions.
/// Provides access to the allocator, parsed parameters, abort signal,
/// progress callbacks, and the host API for capability-gated operations.
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    params: std.json.Value,
    signal: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?agent.types.AgentToolUpdateCallback,
    host_api_vtable: ?*const HostApiVTable,
    host_api_ctx: ?*anyopaque,

    pub fn isAborted(self: ToolContext) bool {
        if (self.signal) |s| return s.load(.acquire);
        return false;
    }

    /// Read a file from the filesystem. Returns owned memory; caller must free.
    pub fn readFile(self: *ToolContext, path: []const u8) ![]u8 {
        const vtable = self.host_api_vtable orelse return error.NoHostApi;
        const ctx = self.host_api_ctx orelse return error.NoHostApi;
        return vtable.readFile(ctx, path);
    }

    /// Write a file to the filesystem.
    pub fn writeFile(self: *ToolContext, path: []const u8, contents: []const u8) !void {
        const vtable = self.host_api_vtable orelse return error.NoHostApi;
        const ctx = self.host_api_ctx orelse return error.NoHostApi;
        return vtable.writeFile(ctx, path, contents);
    }

    /// Spawn a child process and capture stdout/stderr.
    /// Returns owned ProcessResult; caller must call deinit.
    pub fn spawnProcess(self: *ToolContext, options: native_process.ProcessOptions) !native_process.ProcessResult {
        const vtable = self.host_api_vtable orelse return error.NoHostApi;
        const ctx = self.host_api_ctx orelse return error.NoHostApi;
        return vtable.spawnProcess(ctx, options);
    }

    /// Read an environment variable. Returns owned memory; caller must free.
    pub fn readEnv(self: *ToolContext, name: []const u8) ![]u8 {
        const vtable = self.host_api_vtable orelse return error.NoHostApi;
        const ctx = self.host_api_ctx orelse return error.NoHostApi;
        return vtable.readEnv(ctx, name);
    }

    /// Request a network call (counter stub in v0).
    pub fn requestNetwork(self: *ToolContext, url: []const u8) !void {
        const vtable = self.host_api_vtable orelse return error.NoHostApi;
        const ctx = self.host_api_ctx orelse return error.NoHostApi;
        return vtable.requestNetwork(ctx, url);
    }

    /// Run a shell command (counter stub in v0).
    pub fn runShell(self: *ToolContext, command: []const u8) !void {
        const vtable = self.host_api_vtable orelse return error.NoHostApi;
        const ctx = self.host_api_ctx orelse return error.NoHostApi;
        return vtable.runShell(ctx, command);
    }

    /// Call a model (counter stub in v0).
    pub fn callModel(self: *ToolContext, model: []const u8, payload_json: []const u8) !void {
        const vtable = self.host_api_vtable orelse return error.NoHostApi;
        const ctx = self.host_api_ctx orelse return error.NoHostApi;
        return vtable.callModel(ctx, model, payload_json);
    }

    /// Read session state (counter stub in v0).
    pub fn readSession(self: *ToolContext, session_id: []const u8) !void {
        const vtable = self.host_api_vtable orelse return error.NoHostApi;
        const ctx = self.host_api_ctx orelse return error.NoHostApi;
        return vtable.readSession(ctx, session_id);
    }

    /// Write session state (counter stub in v0).
    pub fn writeSession(self: *ToolContext, session_id: []const u8, payload_json: []const u8) !void {
        const vtable = self.host_api_vtable orelse return error.NoHostApi;
        const ctx = self.host_api_ctx orelse return error.NoHostApi;
        return vtable.writeSession(ctx, session_id, payload_json);
    }

    /// Notify UI (counter stub in v0).
    pub fn notifyUi(self: *ToolContext, payload_json: []const u8) !void {
        const vtable = self.host_api_vtable orelse return error.NoHostApi;
        const ctx = self.host_api_ctx orelse return error.NoHostApi;
        return vtable.notifyUi(ctx, payload_json);
    }

    /// Use another tool (counter stub in v0).
    pub fn useTool(self: *ToolContext, name: []const u8, payload_json: []const u8) !void {
        const vtable = self.host_api_vtable orelse return error.NoHostApi;
        const ctx = self.host_api_ctx orelse return error.NoHostApi;
        return vtable.useTool(ctx, name, payload_json);
    }

    /// Spawn an agent (counter stub in v0).
    pub fn spawnAgent(self: *ToolContext, task_json: []const u8) !void {
        const vtable = self.host_api_vtable orelse return error.NoHostApi;
        const ctx = self.host_api_ctx orelse return error.NoHostApi;
        return vtable.spawnAgent(ctx, task_json);
    }

    /// Delegate to an agent (counter stub in v0).
    pub fn delegateAgent(self: *ToolContext, task_json: []const u8) !void {
        const vtable = self.host_api_vtable orelse return error.NoHostApi;
        const ctx = self.host_api_ctx orelse return error.NoHostApi;
        return vtable.delegateAgent(ctx, task_json);
    }
};

/// Convenience: build a text-only tool result.
pub fn resultText(allocator: std.mem.Allocator, text: []const u8) !agent.AgentToolResult {
    return .{ .content = try makeTextContent(allocator, text) };
}

/// Convenience: build a tool result from a JSON value.
pub fn resultJson(allocator: std.mem.Allocator, value: std.json.Value) !agent.AgentToolResult {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return resultText(allocator, out.written());
}

fn makeTextContent(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var array = try std.json.Array.init(allocator, 1);
    errdefer array.deinit(allocator);
    array.items[0] = .{
        .object = blk: {
            var obj = try std.json.ObjectMap.init(allocator, 1, 1);
            errdefer obj.deinit(allocator);
            try obj.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "text") });
            try obj.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text) });
            break :blk obj;
        },
    };
    return .{ .array = array };
}
