const std = @import("std");
const agent = @import("agent");
const sdk = @import("sdk.zig");
const native_runtime = @import("native_runtime.zig");
const native_process = @import("native_process.zig");
const capability = @import("capability.zig");
const tools_common = @import("../tools/common.zig");

fn getHomeDir(allocator: std.mem.Allocator) !?[]u8 {
    const env = currentProcessEnviron();
    var env_map = try env.createMap(allocator);
    defer env_map.deinit();
    const home = env_map.get("HOME") orelse return null;
    return try allocator.dupe(u8, home);
}

fn currentProcessEnviron() std.process.Environ {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .windows => .{ .block = .{ .use_global = true } },
        else => blk: {
            const c_environ = std.c.environ;
            var env_count: usize = 0;
            while (c_environ[env_count] != null) : (env_count += 1) {}
            break :blk .{ .block = .{ .slice = c_environ[0..env_count :null] } };
        },
    };
}

const MAX_PARALLEL_TASKS = 8;
const MAX_CONCURRENCY = 4;

/// Discovered agent configuration.
pub const AgentConfig = struct {
    name: []const u8,
    description: []const u8,
    model: ?[]const u8 = null,
    system_prompt: []const u8,
    source: []const u8,

    pub fn deinit(self: *AgentConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        if (self.model) |m| allocator.free(m);
        allocator.free(self.system_prompt);
        allocator.free(self.source);
    }
};

/// Result of running a single subagent task.
pub const SingleResult = struct {
    agent: []const u8,
    task: []const u8,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
    final_output: []const u8,

    pub fn deinit(self: *SingleResult, allocator: std.mem.Allocator) void {
        allocator.free(self.agent);
        allocator.free(self.task);
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        allocator.free(self.final_output);
    }
};

/// Discover agents from the user's agent directory.
/// Caller owns the returned slice and each AgentConfig inside.
pub fn discoverAgents(allocator: std.mem.Allocator) ![]AgentConfig {
    const home = getHomeDir(allocator) catch return &[_]AgentConfig{};
    defer if (home) |h| allocator.free(h);
    const home_dir = home orelse return &[_]AgentConfig{};
    const agents_dir = try std.fs.path.join(allocator, &.{ home_dir, ".pi", "agent", "agents" });
    defer allocator.free(agents_dir);

    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.openDirAbsolute(io, agents_dir, .{ .iterate = true }) catch return &[_]AgentConfig{};
    defer dir.close(io);

    var agents = std.ArrayList(AgentConfig).empty;
    errdefer {
        for (agents.items) |*a| a.deinit(allocator);
        agents.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

        const path = try std.fs.path.join(allocator, &.{ agents_dir, entry.name });
        defer allocator.free(path);
        const content = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(content);

        const parsed = parseAgentMarkdown(allocator, content) catch continue;
        if (parsed.name.len == 0 or parsed.description.len == 0) {
            parsed.deinit(allocator);
            continue;
        }
        try agents.append(allocator, .{
            .name = parsed.name,
            .description = parsed.description,
            .model = parsed.model,
            .system_prompt = parsed.body,
            .source = try allocator.dupe(u8, "user"),
        });
    }

    return try agents.toOwnedSlice(allocator);
}

const ParsedAgentMarkdown = struct {
    name: []const u8,
    description: []const u8,
    model: ?[]const u8,
    body: []const u8,

    fn deinit(self: ParsedAgentMarkdown, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        if (self.model) |m| allocator.free(m);
        allocator.free(self.body);
    }
};

fn parseAgentMarkdown(allocator: std.mem.Allocator, content: []const u8) !ParsedAgentMarkdown {
    var name: []const u8 = "";
    var description: []const u8 = "";
    var model: ?[]const u8 = null;
    var body_start: usize = 0;

    if (std.mem.startsWith(u8, content, "---\n") or std.mem.startsWith(u8, content, "---\r\n")) {
        const newline_len: usize = if (std.mem.startsWith(u8, content, "---\r\n")) 5 else 4;
        const end_marker = "\n---";
        if (std.mem.indexOf(u8, content[newline_len..], end_marker)) |end_rel| {
            const frontmatter = content[newline_len .. newline_len + end_rel];
            body_start = newline_len + end_rel + end_marker.len;
            while (body_start < content.len and (content[body_start] == '\n' or content[body_start] == '\r')) body_start += 1;

            var lines = std.mem.splitScalar(u8, frontmatter, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \r\t");
                if (std.mem.startsWith(u8, trimmed, "name:")) {
                    name = try allocator.dupe(u8, std.mem.trim(u8, trimmed[5..], " \""));
                } else if (std.mem.startsWith(u8, trimmed, "description:")) {
                    description = try allocator.dupe(u8, std.mem.trim(u8, trimmed[12..], " \""));
                } else if (std.mem.startsWith(u8, trimmed, "model:")) {
                    model = try allocator.dupe(u8, std.mem.trim(u8, trimmed[6..], " \""));
                }
            }
        }
    }

    if (name.len == 0) name = try allocator.dupe(u8, "");
    if (description.len == 0) description = try allocator.dupe(u8, "");
    const body = try allocator.dupe(u8, if (body_start < content.len) std.mem.trim(u8, content[body_start..], " \r\n\t") else "");

    return .{ .name = name, .description = description, .model = model, .body = body };
}

fn findAgent(agents: []const AgentConfig, name: []const u8) ?*const AgentConfig {
    for (agents) |*agent_config| {
        if (std.mem.eql(u8, agent_config.name, name)) return agent_config;
    }
    return null;
}

fn runSingleAgent(
    ctx: *sdk.ToolContext,
    agents: []const AgentConfig,
    agent_name: []const u8,
    task: []const u8,
) !SingleResult {
    const allocator = ctx.allocator;
    const agent_config = findAgent(agents, agent_name) orelse {
        const stderr = try std.fmt.allocPrint(allocator, "Unknown agent: \"{s}\"", .{agent_name});
        return .{
            .agent = try allocator.dupe(u8, agent_name),
            .task = try allocator.dupe(u8, task),
            .exit_code = 1,
            .stdout = try allocator.dupe(u8, ""),
            .stderr = stderr,
            .final_output = try allocator.dupe(u8, ""),
        };
    };

    // Build pi invocation: pi --mode json -p --no-session [Task: ...]
    var argv = std.ArrayList([]const u8).empty;
    defer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }
    try argv.append(allocator, try allocator.dupe(u8, "pi"));
    try argv.append(allocator, try allocator.dupe(u8, "--mode"));
    try argv.append(allocator, try allocator.dupe(u8, "json"));
    try argv.append(allocator, try allocator.dupe(u8, "-p"));
    try argv.append(allocator, try allocator.dupe(u8, "--no-session"));
    if (agent_config.model) |m| {
        try argv.append(allocator, try allocator.dupe(u8, "--model"));
        try argv.append(allocator, try allocator.dupe(u8, m));
    }

    // Write system prompt to temp file if present
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp_dir: ?[]const u8 = null;
    var tmp_path: ?[]const u8 = null;
    defer {
        if (tmp_path) |p| {
            std.Io.Dir.deleteFileAbsolute(io, p) catch {};
            allocator.free(p);
        }
        if (tmp_dir) |d| {
            std.Io.Dir.deleteDirAbsolute(io, d) catch {};
            allocator.free(d);
        }
    }

    if (agent_config.system_prompt.len > 0) {
        tmp_dir = try std.fs.path.join(allocator, &.{ "/tmp", "pi-subagent-XXXXXX" });
        // Note: mkdtemp not available in Zig std; use fixed tmp path
        allocator.free(tmp_dir.?);
        tmp_dir = try std.fs.path.join(allocator, &.{ "/tmp", "pi-subagent" });
        std.Io.Dir.createDirAbsolute(io, tmp_dir.?, .default_dir) catch {};
        tmp_path = try std.fs.path.join(allocator, &.{ tmp_dir.?, "prompt.md" });
        try tools_common.writeFileAbsolute(io, tmp_path.?, agent_config.system_prompt, false);
        try argv.append(allocator, try allocator.dupe(u8, "--append-system-prompt"));
        try argv.append(allocator, try allocator.dupe(u8, tmp_path.?));
    }

    const task_arg = try std.fmt.allocPrint(allocator, "Task: {s}", .{task});
    defer allocator.free(task_arg);
    try argv.append(allocator, try allocator.dupe(u8, task_arg));

    const result = try ctx.spawnProcess(.{
        .argv = argv.items,
    });
    defer result.deinit(allocator);

    const final_output = try extractFinalOutput(allocator, result.stdout);
    errdefer allocator.free(final_output);

    return .{
        .agent = try allocator.dupe(u8, agent_name),
        .task = try allocator.dupe(u8, task),
        .exit_code = result.exit_code,
        .stdout = try allocator.dupe(u8, result.stdout),
        .stderr = try allocator.dupe(u8, result.stderr),
        .final_output = final_output,
    };
}

fn extractFinalOutput(allocator: std.mem.Allocator, stdout: []const u8) ![]const u8 {
    var last_text: []const u8 = "";
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch continue;
        defer parsed.deinit();
        const event = parsed.value;
        if (event != .object) continue;
        const event_type = event.object.get("type") orelse continue;
        if (event_type != .string or !std.mem.eql(u8, event_type.string, "message_end")) continue;
        const message = event.object.get("message") orelse continue;
        if (message != .object) continue;
        const role = message.object.get("role") orelse continue;
        if (role != .string or !std.mem.eql(u8, role.string, "assistant")) continue;
        const content = message.object.get("content") orelse continue;
        if (content != .array) continue;
        for (content.array.items) |block| {
            if (block != .object) continue;
            const block_type = block.object.get("type") orelse continue;
            if (block_type != .string or !std.mem.eql(u8, block_type.string, "text")) continue;
            const text = block.object.get("text") orelse continue;
            if (text == .string) {
                allocator.free(last_text);
                last_text = try allocator.dupe(u8, text.string);
            }
        }
    }
    return last_text;
}

fn subagentExecute(ctx: *sdk.ToolContext) !agent.AgentToolResult {
    const allocator = ctx.allocator;
    const params = ctx.params;

    if (params != .object) {
        return sdk.resultText(allocator, "Invalid parameters: expected JSON object");
    }

    const agent_name_json = params.object.get("agent");
    const task_json = params.object.get("task");
    const tasks_json = params.object.get("tasks");
    const chain_json = params.object.get("chain");

    const has_single = agent_name_json != null and task_json != null and agent_name_json.?.string.len > 0;
    const has_parallel = tasks_json != null and tasks_json.?.array.items.len > 0;
    const has_chain = chain_json != null and chain_json.?.array.items.len > 0;

    const mode_count = @intFromBool(has_single) + @intFromBool(has_parallel) + @intFromBool(has_chain);
    if (mode_count != 1) {
        return sdk.resultText(allocator, "Invalid parameters: provide exactly one of agent+task, tasks, or chain");
    }

    const agents = try discoverAgents(allocator);
    defer {
        for (agents) |*a| a.deinit(allocator);
        allocator.free(agents);
    }

    if (has_single) {
        const agent_name = agent_name_json.?.string;
        const task = task_json.?.string;
        var result = try runSingleAgent(ctx, agents, agent_name, task);
        defer result.deinit(allocator);
        return sdk.resultText(allocator, result.final_output);
    }

    if (has_parallel) {
        const tasks = tasks_json.?.array.items;
        if (tasks.len > MAX_PARALLEL_TASKS) {
            return sdk.resultText(allocator, "Too many parallel tasks");
        }
        var outputs = std.ArrayList([]const u8).empty;
        defer {
            for (outputs.items) |o| allocator.free(o);
            outputs.deinit(allocator);
        }
        for (tasks) |t| {
            if (t != .object) continue;
            const a_name = t.object.get("agent") orelse continue;
            const a_task = t.object.get("task") orelse continue;
            var result = try runSingleAgent(ctx, agents, a_name.string, a_task.string);
            defer result.deinit(allocator);
            const line = try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ result.agent, result.final_output });
            try outputs.append(allocator, line);
        }
        const combined = try std.mem.join(allocator, "\n", outputs.items);
        defer allocator.free(combined);
        return sdk.resultText(allocator, combined);
    }

    if (has_chain) {
        const steps = chain_json.?.array.items;
        var previous_output: []const u8 = "";
        defer allocator.free(previous_output);
        var result_text: []const u8 = "";
        errdefer allocator.free(result_text);

        for (steps, 0..) |step, i| {
            if (step != .object) continue;
            const a_name = step.object.get("agent") orelse continue;
            const a_task_raw = step.object.get("task") orelse continue;
            const a_task = try std.mem.replaceOwned(u8, allocator, a_task_raw.string, "{previous}", previous_output);
            defer allocator.free(a_task);
            var result = try runSingleAgent(ctx, agents, a_name.string, a_task);
            defer result.deinit(allocator);
            allocator.free(previous_output);
            previous_output = try allocator.dupe(u8, result.final_output);
            allocator.free(result_text);
            result_text = try std.fmt.allocPrint(allocator, "Step {d} ({s}): {s}", .{ i + 1, result.agent, result.final_output });
        }
        return sdk.resultText(allocator, result_text);
    }

    return sdk.resultText(allocator, "Invalid parameters");
}

const subagent_tool_definition: native_runtime.NativeToolDefinition = .{
    .name = "subagent",
    .label = "Subagent",
    .description = "Delegate tasks to specialized subagents with isolated context. Supports single, parallel, and chain modes.",
    .input_schema_json =
        \\{"type":"object","properties":{
        \\  "agent":{"type":"string","description":"Name of the agent to invoke (single mode)"},
        \\  "task":{"type":"string","description":"Task to delegate (single mode)"},
        \\  "tasks":{"type":"array","description":"Array of {agent, task} for parallel execution"},
        \\  "chain":{"type":"array","description":"Array of {agent, task} for sequential execution"}
        \\}}
    ,
    .extension_path = "native://subagent",
    .execute = subagentExecute,
};

pub const subagent_descriptor: native_runtime.NativeDescriptor = .{
    .id = "com.pi.native.subagent",
    .name = "Native Subagent",
    .version = "0.1.0",
    .description = "Native subagent extension for delegating tasks to specialized agents.",
    .tools = &.{subagent_tool_definition},
    .requested_capabilities = &.{ .shell_run, .file_read, .env_read },
};

test "subagent descriptor validates without errors" {
    const allocator = std.testing.allocator;
    try subagent_descriptor.validate(allocator);
}

test "subagent parseAgentMarkdown extracts frontmatter and body" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\name: test-agent
        \\description: A test agent
        \\model: gpt-4
        \\---
        \\System prompt line 1
        \\System prompt line 2
    ;
    const parsed = try parseAgentMarkdown(allocator, content);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("test-agent", parsed.name);
    try std.testing.expectEqualStrings("A test agent", parsed.description);
    try std.testing.expectEqualStrings("gpt-4", parsed.model.?);
    try std.testing.expect(std.mem.containsAtLeast(u8, parsed.body, 1, "System prompt line 1"));
}
