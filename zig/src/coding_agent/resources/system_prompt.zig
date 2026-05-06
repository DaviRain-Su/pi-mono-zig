const std = @import("std");
const context_files_mod = @import("context_files.zig");
const resources_mod = @import("resources.zig");

const BUILTIN_TOOLS = [_]ToolInfo{
    .{ .name = "read", .description = "Read file contents" },
    .{ .name = "bash", .description = "Execute shell commands" },
    .{ .name = "edit", .description = "Edit files with exact text replacement" },
    .{ .name = "write", .description = "Write files and create parent directories" },
    .{ .name = "grep", .description = "Search file contents with ripgrep" },
    .{ .name = "find", .description = "Find files by glob pattern" },
    .{ .name = "ls", .description = "List directory contents" },
};

const ToolInfo = struct {
    name: []const u8,
    description: []const u8,
};

pub const BuildSystemPromptOptions = struct {
    cwd: []const u8,
    current_date: []const u8,
    custom_prompt: ?[]const u8 = null,
    append_prompt: ?[]const u8 = null,
    selected_tools: ?[]const []const u8 = null,
    context_files: []const context_files_mod.ContextFile = &.{},
    skills: []const resources_mod.Skill = &.{},
};

pub fn buildSystemPrompt(allocator: std.mem.Allocator, options: BuildSystemPromptOptions) ![]u8 {
    var prompt = std.ArrayList(u8).empty;
    defer prompt.deinit(allocator);

    if (options.custom_prompt) |custom_prompt| {
        try prompt.appendSlice(allocator, custom_prompt);
    } else {
        try prompt.appendSlice(allocator, "You are an expert coding assistant operating inside pi, a coding agent harness.\n\n");
        try prompt.appendSlice(allocator, "Available tools:\n");
        try appendToolSection(allocator, &prompt, options.selected_tools);
        try prompt.appendSlice(allocator, "\n\nGuidelines:\n");
        try appendGuidelines(allocator, &prompt, options.selected_tools);
    }

    if (options.append_prompt) |append_prompt| {
        try prompt.appendSlice(allocator, "\n\n");
        try prompt.appendSlice(allocator, append_prompt);
    }

    if (options.context_files.len > 0) {
        try appendContextFiles(allocator, &prompt, options.context_files);
    }

    if (hasTool(options.selected_tools, "read") and options.skills.len > 0) {
        const skills_text = try resources_mod.formatSkillsForPrompt(allocator, options.skills);
        defer allocator.free(skills_text);
        if (skills_text.len > 0) {
            try prompt.appendSlice(allocator, skills_text);
        }
    }

    try prompt.appendSlice(allocator, "\n\nCurrent date: ");
    try prompt.appendSlice(allocator, options.current_date);
    try prompt.appendSlice(allocator, "\nCurrent working directory: ");
    try prompt.appendSlice(allocator, options.cwd);

    return try prompt.toOwnedSlice(allocator);
}

fn appendToolSection(
    allocator: std.mem.Allocator,
    prompt: *std.ArrayList(u8),
    selected_tools: ?[]const []const u8,
) !void {
    if (selected_tools) |tools| {
        if (tools.len == 0) {
            try prompt.appendSlice(allocator, "(none)");
            return;
        }

        for (tools, 0..) |tool_name, index| {
            if (index > 0) try prompt.appendSlice(allocator, "\n");
            const info = findTool(tool_name) orelse ToolInfo{
                .name = tool_name,
                .description = "Custom tool available in this environment",
            };
            try appendToolLine(allocator, prompt, info);
        }
        return;
    }

    for (BUILTIN_TOOLS, 0..) |tool, index| {
        if (index > 0) try prompt.appendSlice(allocator, "\n");
        try appendToolLine(allocator, prompt, tool);
    }
}

fn appendToolLine(allocator: std.mem.Allocator, prompt: *std.ArrayList(u8), info: ToolInfo) !void {
    try prompt.appendSlice(allocator, "- ");
    try prompt.appendSlice(allocator, info.name);
    try prompt.appendSlice(allocator, ": ");
    try prompt.appendSlice(allocator, info.description);
}

fn appendGuidelines(
    allocator: std.mem.Allocator,
    prompt: *std.ArrayList(u8),
    selected_tools: ?[]const []const u8,
) !void {
    try prompt.appendSlice(allocator, "- Use the available tools when they help answer the user's request.\n");

    if (hasAnyTool(selected_tools, &.{ "grep", "find", "ls" })) {
        try prompt.appendSlice(allocator, "- Prefer grep/find/ls over bash for repository exploration when those tools are available.\n");
    } else if (hasTool(selected_tools, "bash")) {
        try prompt.appendSlice(allocator, "- Use bash for repository exploration when dedicated search tools are unavailable.\n");
    }

    try prompt.appendSlice(allocator, "- Be concise in your responses.\n");
    try prompt.appendSlice(allocator, "- Show file paths clearly when referring to project files.");
}

fn appendContextFiles(
    allocator: std.mem.Allocator,
    prompt: *std.ArrayList(u8),
    context_files: []const context_files_mod.ContextFile,
) !void {
    try prompt.appendSlice(allocator, "\n\n# Project Context\n\n");
    try prompt.appendSlice(allocator, "Project-specific instructions and guidelines:\n\n");
    for (context_files) |context_file| {
        try prompt.appendSlice(allocator, "## ");
        try prompt.appendSlice(allocator, context_file.path);
        try prompt.appendSlice(allocator, "\n\n");
        try prompt.appendSlice(allocator, context_file.content);
        try prompt.appendSlice(allocator, "\n\n");
    }
}

fn hasAnyTool(selected_tools: ?[]const []const u8, names: []const []const u8) bool {
    for (names) |name| {
        if (hasTool(selected_tools, name)) return true;
    }
    return false;
}

fn hasTool(selected_tools: ?[]const []const u8, name: []const u8) bool {
    const tools = selected_tools orelse builtinToolNames();
    for (tools) |tool_name| {
        if (std.mem.eql(u8, tool_name, name)) return true;
    }
    return false;
}

fn builtinToolNames() []const []const u8 {
    return &.{
        "read",
        "bash",
        "edit",
        "write",
        "grep",
        "find",
        "ls",
    };
}

fn findTool(name: []const u8) ?ToolInfo {
    for (BUILTIN_TOOLS) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

test "default system prompt includes tools, guidelines, date, and cwd" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .cwd = "/tmp/project",
        .current_date = "2026-04-24",
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Available tools:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- read: Read file contents") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- bash: Execute shell commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- grep: Search file contents with ripgrep") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Guidelines:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Current date: 2026-04-24") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Current working directory: /tmp/project") != null);
}

test "custom system prompt replaces default and appends extra text" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .cwd = "/tmp/project",
        .custom_prompt = "You are a terse assistant.",
        .append_prompt = "Prefer short answers.",
        .current_date = "2026-04-24",
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "You are a terse assistant.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Prefer short answers.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Available tools:") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Current date: 2026-04-24") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Current working directory: /tmp/project") != null);
}

test "selected tools limit the visible tool list" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .cwd = "/tmp/project",
        .selected_tools = &.{ "read", "ls" },
        .current_date = "2026-04-24",
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "- read: Read file contents") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- ls: List directory contents") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- bash: Execute shell commands") == null);
}

test "system prompt appends project context files and skills when read is available" {
    const allocator = std.testing.allocator;

    const context_files = [_]context_files_mod.ContextFile{
        .{
            .path = "/tmp/project/AGENTS.md",
            .content = "Use ripgrep first.",
        },
    };
    const skills = [_]resources_mod.Skill{
        .{
            .name = @constCast("reviewer"),
            .description = @constCast("Review changes for correctness"),
            .file_path = @constCast("/tmp/project/.pi/skills/reviewer/SKILL.md"),
            .base_dir = @constCast("/tmp/project/.pi/skills/reviewer"),
            .source_info = .{
                .path = @constCast("/tmp/project/.pi/skills/reviewer/SKILL.md"),
                .source = @constCast("local"),
                .scope = .project,
                .origin = .top_level,
                .base_dir = @constCast("/tmp/project/.pi/skills/reviewer"),
            },
        },
    };

    const prompt = try buildSystemPrompt(allocator, .{
        .cwd = "/tmp/project",
        .current_date = "2026-04-24",
        .selected_tools = &.{ "read", "ls" },
        .context_files = &context_files,
        .skills = &skills,
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Project Context") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## /tmp/project/AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Use ripgrep first.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<name>reviewer</name>") != null);
}
