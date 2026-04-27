const std = @import("std");
const agent = @import("agent");
const tools = @import("../tools/root.zig");
const common = @import("../tools/common.zig");
const provider_config = @import("../provider_config.zig");
const session_mod = @import("../session.zig");
const session_manager_mod = @import("../session_manager.zig");
const shared = @import("shared.zig");

const AppContext = shared.AppContext;

pub const BuiltTools = struct {
    allocator: std.mem.Allocator,
    items: []agent.AgentTool,

    pub fn deinit(self: *BuiltTools) void {
        for (self.items) |item| common.deinitJsonValue(self.allocator, item.parameters);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn buildAgentTools(
    allocator: std.mem.Allocator,
    app_context: *AppContext,
    selected_tools: ?[]const []const u8,
) !BuiltTools {
    var items = std.ArrayList(agent.AgentTool).empty;
    errdefer {
        for (items.items) |item| common.deinitJsonValue(allocator, item.parameters);
        items.deinit(allocator);
    }

    try appendToolIfEnabled(allocator, &items, app_context, selected_tools, tools.ReadTool.name, tools.ReadTool.description, try tools.ReadTool.schema(allocator), runReadTool);
    try appendToolIfEnabled(allocator, &items, app_context, selected_tools, tools.BashTool.name, tools.BashTool.description, try tools.BashTool.schema(allocator), runBashTool);
    try appendToolIfEnabled(allocator, &items, app_context, selected_tools, tools.WriteTool.name, tools.WriteTool.description, try tools.WriteTool.schema(allocator), runWriteTool);
    try appendToolIfEnabled(allocator, &items, app_context, selected_tools, tools.EditTool.name, tools.EditTool.description, try tools.EditTool.schema(allocator), runEditTool);
    try appendToolIfEnabled(allocator, &items, app_context, selected_tools, tools.GrepTool.name, tools.GrepTool.description, try tools.GrepTool.schema(allocator), runGrepTool);
    try appendToolIfEnabled(allocator, &items, app_context, selected_tools, tools.FindTool.name, tools.FindTool.description, try tools.FindTool.schema(allocator), runFindTool);
    try appendToolIfEnabled(allocator, &items, app_context, selected_tools, tools.LsTool.name, tools.LsTool.description, try tools.LsTool.schema(allocator), runLsTool);

    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(allocator),
    };
}

fn appendToolIfEnabled(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(agent.AgentTool),
    app_context: *AppContext,
    selected_tools: ?[]const []const u8,
    name: []const u8,
    description: []const u8,
    schema: std.json.Value,
    execute: agent.types.ExecuteToolFn,
) !void {
    if (selected_tools) |allowlist| {
        var enabled = false;
        for (allowlist) |allowed| {
            if (std.mem.eql(u8, allowed, name)) {
                enabled = true;
                break;
            }
        }
        if (!enabled) {
            common.deinitJsonValue(allocator, schema);
            return;
        }
    }

    try items.append(allocator, .{
        .name = name,
        .description = description,
        .label = name,
        .parameters = schema,
        .execute = execute,
        .execute_context = app_context,
    });
}

fn getAppContext(tool_context: ?*anyopaque) !*AppContext {
    return @ptrCast(@alignCast(tool_context orelse return error.InvalidToolContext));
}

fn runReadTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = (try getAppContext(tool_context)).tool_runtime;
    const args = tools.ReadArgs{
        .path = try getRequiredString(params, "path"),
        .offset = getOptionalUsize(params, "offset"),
        .limit = getOptionalUsize(params, "limit"),
    };
    const result = try tools.ReadTool.init(runtime.cwd, runtime.io).execute(allocator, args);
    return .{ .content = result.content };
}

fn runBashTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = (try getAppContext(tool_context)).tool_runtime;
    const args = try tools.bash.parseArguments(params);
    var update_forward = BashToolUpdateForwardContext{
        .allocator = allocator,
        .downstream_context = on_update_context,
        .downstream = on_update,
    };
    var result = try tools.BashTool.init(runtime.cwd, runtime.io).executeWithUpdates(
        allocator,
        args,
        signal,
        &update_forward,
        forwardBashToolUpdate,
    );
    defer if (result.details) |*details| details.deinit(allocator);
    return .{
        .content = result.content,
        .details = if (result.details) |details| try tools.bash.detailsToJsonValue(allocator, details) else null,
    };
}

const BashToolUpdateForwardContext = struct {
    allocator: std.mem.Allocator,
    downstream_context: ?*anyopaque,
    downstream: ?agent.types.AgentToolUpdateCallback,
};

fn forwardBashToolUpdate(
    context: ?*anyopaque,
    result: tools.BashExecutionResult,
) !void {
    const forward_context: *BashToolUpdateForwardContext = @ptrCast(@alignCast(context.?));
    const callback = forward_context.downstream orelse return;
    const details = if (result.details) |details_value|
        try tools.bash.detailsToJsonValue(forward_context.allocator, details_value)
    else
        null;
    defer if (details) |details_value| common.deinitJsonValue(forward_context.allocator, details_value);

    const partial = agent.AgentToolResult{
        .content = result.content,
        .details = details,
    };

    try callback(forward_context.downstream_context, partial);
}

fn runWriteTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = (try getAppContext(tool_context)).tool_runtime;
    const args = tools.WriteArgs{
        .path = try getRequiredString(params, "path"),
        .content = try getRequiredString(params, "content"),
    };
    const result = try tools.WriteTool.init(runtime.cwd, runtime.io).execute(allocator, args);
    return .{ .content = result.content };
}

fn runEditTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = (try getAppContext(tool_context)).tool_runtime;
    var parsed_args_storage = try tools.edit.parseArguments(allocator, params);
    defer parsed_args_storage.deinit(allocator);
    const edit_args = parsed_args_storage.toArgs();
    const result = try tools.EditTool.init(runtime.cwd, runtime.io).execute(allocator, edit_args);
    return .{ .content = result.content };
}

fn runGrepTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = (try getAppContext(tool_context)).tool_runtime;
    const args = tools.GrepArgs{
        .pattern = try getRequiredString(params, "pattern"),
        .path = getOptionalString(params, "path"),
        .glob = getOptionalStringEither(params, "glob", "glob_pattern"),
        .ignore_case = getOptionalBoolEither(params, "ignoreCase", "ignore_case") orelse false,
        .literal = getOptionalBool(params, "literal") orelse false,
        .context = getOptionalUsize(params, "context") orelse 0,
        .limit = getOptionalUsize(params, "limit"),
    };
    const result = try tools.GrepTool.init(runtime.cwd, runtime.io).execute(allocator, args);
    return .{ .content = result.content };
}

fn runFindTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = (try getAppContext(tool_context)).tool_runtime;
    const args = tools.FindArgs{
        .pattern = try getRequiredString(params, "pattern"),
        .path = getOptionalString(params, "path"),
        .limit = getOptionalUsize(params, "limit"),
    };
    const result = try tools.FindTool.init(runtime.cwd, runtime.io).execute(allocator, args);
    return .{ .content = result.content };
}

fn runLsTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = (try getAppContext(tool_context)).tool_runtime;
    const args = tools.LsArgs{
        .path = getOptionalString(params, "path"),
        .limit = getOptionalUsize(params, "limit"),
    };
    const result = try tools.LsTool.init(runtime.cwd, runtime.io).execute(allocator, args);
    return .{ .content = result.content };
}

fn getRequiredString(value: std.json.Value, key: []const u8) ![]const u8 {
    return getStringObjectValue(value, key) orelse error.InvalidToolArguments;
}

fn getOptionalString(value: std.json.Value, key: []const u8) ?[]const u8 {
    return getStringObjectValue(value, key);
}

fn getOptionalStringEither(value: std.json.Value, first: []const u8, second: []const u8) ?[]const u8 {
    return getStringObjectValue(value, first) orelse getStringObjectValue(value, second);
}

fn getOptionalBool(value: std.json.Value, key: []const u8) ?bool {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const raw = object.get(key) orelse return null;
    return switch (raw) {
        .bool => |bool_value| bool_value,
        else => null,
    };
}

fn getOptionalBoolEither(value: std.json.Value, first: []const u8, second: []const u8) ?bool {
    return getOptionalBool(value, first) orelse getOptionalBool(value, second);
}

fn getOptionalUsize(value: std.json.Value, key: []const u8) ?usize {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const raw = object.get(key) orelse return null;
    return switch (raw) {
        .integer => |integer| std.math.cast(usize, integer) orelse null,
        else => null,
    };
}

fn getStringObjectValue(value: std.json.Value, key: []const u8) ?[]const u8 {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const raw = object.get(key) orelse return null;
    return switch (raw) {
        .string => |string| string,
        else => null,
    };
}

test "buildAgentTools threads app context into execute callbacks" {
    var app_context = AppContext.init("/tmp", std.testing.io);
    var built_tools = try buildAgentTools(std.testing.allocator, &app_context, &[_][]const u8{ "read", "bash" });
    defer built_tools.deinit();

    try std.testing.expectEqual(@as(usize, 2), built_tools.items.len);
    for (built_tools.items) |tool| {
        try std.testing.expect(tool.execute != null);
        try std.testing.expect(tool.execute_context == @as(?*anyopaque, @ptrCast(&app_context)));
    }
}

test "forwardBashToolUpdate borrows streaming content without freeing it twice" {
    const allocator = std.testing.allocator;

    const Capture = struct {
        allocator: std.mem.Allocator,
        text: ?[]u8 = null,

        fn deinit(self: *@This()) void {
            if (self.text) |text| self.allocator.free(text);
        }

        fn collect(context: ?*anyopaque, partial_result: agent.AgentToolResult) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqual(@as(usize, 1), partial_result.content.len);
            try std.testing.expectEqualStrings("streaming update", partial_result.content[0].text.text);
            self.text = try self.allocator.dupe(u8, partial_result.content[0].text.text);
        }
    };

    var capture = Capture{ .allocator = allocator };
    defer capture.deinit();

    var context = BashToolUpdateForwardContext{
        .allocator = allocator,
        .downstream_context = &capture,
        .downstream = Capture.collect,
    };

    var result = tools.BashExecutionResult{
        .content = try common.makeTextContent(allocator, "streaming update"),
        .details = null,
        .is_error = false,
    };
    defer result.deinit(allocator);

    try forwardBashToolUpdate(&context, result);
    try std.testing.expectEqualStrings("streaming update", capture.text.?);
}

test "buildAgentTools accepts bash timeout alias through the agent adapter" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/sessions");

    const root_dir = try makeToolAdapterTestPath(allocator, tmp, "workspace");
    defer allocator.free(root_dir);
    const session_dir = try makeToolAdapterTestPath(allocator, tmp, "workspace/sessions");
    defer allocator.free(session_dir);

    try env_map.put("PI_FAUX_TOOL_NAME", "bash");
    try env_map.put("PI_FAUX_TOOL_ARGS_JSON", "{\"command\":\"sleep 5\",\"timeout\":1}");
    try env_map.put("PI_FAUX_TOOL_FINAL_RESPONSE", "The command timed out");

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var app_context = AppContext.init(root_dir, std.testing.io);
    var built_tools = try buildAgentTools(allocator, &app_context, &[_][]const u8{"bash"});
    defer built_tools.deinit();

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
        .tools = built_tools.items,
    });
    defer session.deinit();

    try session.prompt("run bash with alias timeout");

    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);

    var reopened = try session_manager_mod.SessionManager.open(allocator, std.testing.io, session_file, root_dir);
    defer reopened.deinit();

    var context = try reopened.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqualStrings("bash", context.messages[2].tool_result.tool_name);
    try std.testing.expect(context.messages[2].tool_result.details != null);
    const details = context.messages[2].tool_result.details.?.object;
    try std.testing.expectEqual(true, details.get("timed_out").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, context.messages[2].tool_result.content[0].text.text, "Command timed out after 1 seconds") != null);
}

fn makeToolAdapterTestPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, ".zig-cache", "tmp", &tmp.sub_path, name });
}
