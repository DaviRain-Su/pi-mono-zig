pub const std = @import("std");
pub const agent = @import("agent");
pub const ai = @import("ai");
pub const config_mod = @import("../../../config/config.zig");
pub const extension_runtime = @import("../../extension_runtime.zig");
pub const interactive_mode = @import("../../../interactive_mode.zig");
pub const native_loader = @import("../../native/native_loader.zig");
pub const native_manifest = @import("../../native/native_manifest.zig");
pub const package_manager = @import("../../../packages/package_manager.zig");
pub const print_mode = @import("../../../modes/print_mode.zig");
pub const resources_mod = @import("../../../resources/resources.zig");
pub const sdk = @import("../pi_extension_sdk.zig");
pub const session_mod = @import("../../../sessions/session.zig");
pub const tool_selection_mod = @import("../../../tool_selection.zig");
pub const tools_common = @import("../../../tools/common.zig");
pub const wasm_manifest = @import("../wasm_manifest.zig");

pub const TEMPLATE_ROOT = "templates/extension-wasm-zig";
pub const TEMPLATE_FILES = [_][]const u8{
    "build.zig",
    "pi-extension.json",
    "sdk/pi_extension_sdk.zig",
    "src/main.zig",
    "test/main.zig",
    "wasm/.gitkeep",
};
pub const NATIVE_TEMPLATE_ROOT = "templates/extension-native-zig";
pub const NATIVE_TEMPLATE_FILES = [_][]const u8{
    "build.zig",
    "pi-extension.json",
    "sdk/pi_native_extension_sdk.zig",
    "src/main.zig",
    "test/main.zig",
    "native/.gitkeep",
};

pub const CommandCapture = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *CommandCapture, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub fn normalConstructionFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try std.testing.expect(context.messages.len >= 1);
    const prompt = context.messages[context.messages.len - 1].user.content[0].text.text;
    const tools = context.tools orelse &.{};
    const response_text = responseTextForNormalConstructionPrompt(prompt) orelse return error.UnexpectedNormalConstructionPrompt;
    if (std.mem.eql(u8, prompt, "default construction") or std.mem.eql(u8, prompt, "json construction") or std.mem.eql(u8, prompt, "mixed construction")) {
        try expectProviderToolPresent(tools, "read");
        try expectProviderToolPresent(tools, "bash");
        try expectProviderToolPresent(tools, "write");
        try expectProviderToolPresent(tools, "edit");
        try expectProviderToolPresent(tools, "grep");
        try expectProviderToolPresent(tools, "find");
        try expectProviderToolPresent(tools, "ls");
        try expectProviderToolPresent(tools, "template.echo");
        if (std.mem.eql(u8, prompt, "mixed construction")) {
            try expectProviderToolPresent(tools, "native.echo");
        }
    } else if (std.mem.eql(u8, prompt, "selected builtins")) {
        try expectProviderToolNamesExactly(tools, &.{ "read", "grep" });
    } else if (std.mem.eql(u8, prompt, "selected wasm")) {
        try expectProviderToolNamesExactly(tools, &.{"template.echo"});
    } else if (std.mem.eql(u8, prompt, "no tools")) {
        try expectProviderToolNamesExactly(tools, &.{});
    } else if (std.mem.eql(u8, prompt, "no builtins")) {
        try expectProviderToolNamesExactly(tools, &.{"template.echo"});
    } else if (std.mem.eql(u8, prompt, "no tools explicit wasm")) {
        try expectProviderToolNamesExactly(tools, &.{"template.echo"});
    } else {
        return error.UnexpectedNormalConstructionPrompt;
    }

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText(response_text);
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

pub fn responseTextForNormalConstructionPrompt(prompt: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, prompt, "default construction")) return "default construction ok";
    if (std.mem.eql(u8, prompt, "selected builtins")) return "selected builtins ok";
    if (std.mem.eql(u8, prompt, "selected wasm")) return "selected wasm ok";
    if (std.mem.eql(u8, prompt, "no tools")) return "no tools ok";
    if (std.mem.eql(u8, prompt, "no builtins")) return "no builtins ok";
    if (std.mem.eql(u8, prompt, "no tools explicit wasm")) return "no tools explicit wasm ok";
    if (std.mem.eql(u8, prompt, "json construction")) return "json construction ok";
    if (std.mem.eql(u8, prompt, "mixed construction")) return "mixed construction ok";
    return null;
}

pub fn forcedWasmSuccessToolCallFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try std.testing.expect(context.messages.len >= 1);
    const prompt = context.messages[context.messages.len - 1].user.content[0].text.text;
    try std.testing.expectEqualStrings("call installed wasm", prompt);

    var args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"message\":\"normal agent path\"}", .{});
    defer args.deinit();
    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = try ai.providers.faux.fauxToolCall(allocator, "template.echo", args.value, .{ .id = "wasm-normal-success" });
    return ai.providers.faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use });
}

pub fn verifyWasmSuccessResultFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try expectLatestToolResult(context.messages, .{
        .tool_call_id = "wasm-normal-success",
        .tool_name = "template.echo",
        .is_error = false,
        .content_contains = "\"message\":\"normal agent path\"",
        .expected_extension_id = "com.pi.template.echo",
        .expected_artifact_sha256 = null,
    });

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText("installed wasm success observed");
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

pub fn forcedNativeSuccessToolCallFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try std.testing.expect(context.messages.len >= 1);
    const prompt = context.messages[context.messages.len - 1].user.content[0].text.text;
    try std.testing.expectEqualStrings("call installed native", prompt);

    var args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"message\":\"normal native path\"}", .{});
    defer args.deinit();
    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = try ai.providers.faux.fauxToolCall(allocator, "native.echo", args.value, .{ .id = "native-normal-success" });
    return ai.providers.faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use });
}

pub fn verifyNativeSuccessResultFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try expectLatestToolResult(context.messages, .{
        .tool_call_id = "native-normal-success",
        .tool_name = "native.echo",
        .is_error = false,
        .content_contains = "\"message\":\"normal native path\"",
        .expected_runtime_kind = "native",
        .expected_extension_id = "com.pi.native.template.echo",
        .expected_artifact_sha256 = null,
    });

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText("installed native success observed");
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

pub fn forcedWasmInvalidInputToolCallFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try std.testing.expect(context.messages.len >= 1);
    const prompt = context.messages[context.messages.len - 1].user.content[0].text.text;
    try std.testing.expectEqualStrings("call installed wasm with invalid input", prompt);

    var args = try std.json.parseFromSlice(std.json.Value, allocator, "[]", .{});
    defer args.deinit();
    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = try ai.providers.faux.fauxToolCall(allocator, "template.echo", args.value, .{ .id = "wasm-normal-invalid" });
    return ai.providers.faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use });
}

pub fn verifyWasmInvalidResultFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try expectLatestGenericToolError(context.messages, "wasm-normal-invalid", "template.echo", "InvalidToolArguments");

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText("installed wasm invalid input observed");
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

pub fn forcedUpdatedWasmSuccessToolCallFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try std.testing.expect(context.messages.len >= 1);
    const prompt = context.messages[context.messages.len - 1].user.content[0].text.text;
    try std.testing.expectEqualStrings("call updated installed wasm", prompt);

    var args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"operation\":\"echo\",\"value\":\"edited runtime output\"}", .{});
    defer args.deinit();
    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = try ai.providers.faux.fauxToolCall(allocator, "fixture.echo", args.value, .{ .id = "wasm-updated-success" });
    return ai.providers.faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use });
}

pub fn verifyUpdatedWasmSuccessResultFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try expectLatestToolResult(context.messages, .{
        .tool_call_id = "wasm-updated-success",
        .tool_name = "fixture.echo",
        .is_error = false,
        .content_contains = "\"echo\":\"edited runtime output\"",
        .expected_extension_id = "com.pi.template.echo",
        .expected_artifact_sha256 = null,
    });

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText("updated installed wasm success observed");
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

pub fn postRemoveConstructionFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try std.testing.expect(context.messages.len >= 1);
    const prompt = context.messages[context.messages.len - 1].user.content[0].text.text;
    try std.testing.expectEqualStrings("post-remove construction", prompt);
    const tools = context.tools orelse &.{};
    try expectProviderToolPresent(tools, "read");
    try expectProviderToolPresent(tools, "bash");
    try expectProviderToolAbsent(tools, "template.echo");
    try expectProviderToolAbsent(tools, "fixture.echo");

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText("post-remove construction ok");
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

pub fn aggregatePostRemoveConstructionFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try std.testing.expect(context.messages.len >= 1);
    const prompt = context.messages[context.messages.len - 1].user.content[0].text.text;
    try std.testing.expectEqualStrings("aggregate post-remove construction", prompt);
    const tools = context.tools orelse &.{};
    try expectProviderToolPresent(tools, "read");
    try expectProviderToolPresent(tools, "bash");
    try expectProviderToolAbsent(tools, "template.echo");
    try expectProviderToolAbsent(tools, "native.echo");

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText("aggregate post-remove construction ok");
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

pub const ExpectedToolResult = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    is_error: bool,
    content_contains: []const u8,
    expected_runtime_kind: []const u8 = "wasm",
    expected_extension_id: []const u8,
    expected_artifact_sha256: ?[]const u8,
};

pub fn expectLatestToolResult(messages: []const ai.Message, expected: ExpectedToolResult) !void {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        switch (messages[index]) {
            .tool_result => |tool_result| {
                try std.testing.expectEqualStrings(expected.tool_call_id, tool_result.tool_call_id);
                try std.testing.expectEqualStrings(expected.tool_name, tool_result.tool_name);
                try std.testing.expectEqual(expected.is_error, tool_result.is_error);
                try std.testing.expect(std.mem.indexOf(u8, tool_result.content[0].text.text, expected.content_contains) != null);
                const details = tool_result.details orelse return error.ExpectedWasmRuntimeDetails;
                const runtime = details.object.get("extensionRuntime") orelse return error.ExpectedWasmRuntimeDetails;
                try std.testing.expectEqualStrings(expected.expected_runtime_kind, runtime.object.get("runtimeKind").?.string);
                try std.testing.expectEqualStrings(expected.expected_extension_id, runtime.object.get("extensionId").?.string);
                try std.testing.expectEqualStrings(expected.tool_name, runtime.object.get("toolId").?.string);
                if (expected.expected_artifact_sha256) |artifact_sha256| {
                    try std.testing.expectEqualStrings(artifact_sha256, runtime.object.get("artifactSha256").?.string);
                }
                return;
            },
            else => {},
        }
    }
    return error.ExpectedToolResultMissing;
}

pub fn expectLatestGenericToolError(
    messages: []const ai.Message,
    tool_call_id: []const u8,
    tool_name: []const u8,
    content_contains: []const u8,
) !void {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        switch (messages[index]) {
            .tool_result => |tool_result| {
                try std.testing.expectEqualStrings(tool_call_id, tool_result.tool_call_id);
                try std.testing.expectEqualStrings(tool_name, tool_result.tool_name);
                try std.testing.expect(tool_result.is_error);
                try std.testing.expect(std.mem.indexOf(u8, tool_result.content[0].text.text, content_contains) != null);
                return;
            },
            else => {},
        }
    }
    return error.ExpectedToolResultMissing;
}

pub fn runNormalTemplateInvocation(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    session_dir: []const u8,
    model: ai.Model,
    expected_artifact_sha256: []const u8,
) !void {
    try runNormalTemplateInvocationWithPrompt(allocator, home_dir, agent_dir, project_dir, session_dir, model, .{
        .prompt = "call installed wasm",
        .expected_stdout = "installed wasm success observed\n",
        .tool_name = "template.echo",
        .tool_call_id = "wasm-normal-success",
        .content_contains = "\"message\":\"normal agent path\"",
        .expected_artifact_sha256 = expected_artifact_sha256,
    });
}

pub fn runNormalUpdatedTemplateInvocation(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    session_dir: []const u8,
    model: ai.Model,
    expected_artifact_sha256: []const u8,
) !void {
    try runNormalTemplateInvocationWithPrompt(allocator, home_dir, agent_dir, project_dir, session_dir, model, .{
        .prompt = "call updated installed wasm",
        .expected_stdout = "updated installed wasm success observed\n",
        .tool_name = "fixture.echo",
        .tool_call_id = "wasm-updated-success",
        .content_contains = "\"echo\":\"edited runtime output\"",
        .expected_artifact_sha256 = expected_artifact_sha256,
    });
}

pub fn runNormalNativeInvocation(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    session_dir: []const u8,
    model: ai.Model,
    expected_artifact_sha256: []const u8,
) !void {
    var runtime_config = try loadAuthorRuntimeConfig(allocator, home_dir, agent_dir, project_dir);
    defer runtime_config.deinit();

    var app_context = interactive_mode.AppContext.init(project_dir, std.testing.io);
    var built_tools = try interactive_mode.buildAgentToolsWithOptions(allocator, &app_context, .{
        .selected_tools = tool_selection_mod.ToolSelection.fromAllowlist(&.{"native.echo"}),
        .include_installed_wasm_tools = true,
        .include_installed_native_tools = true,
        .runtime_config = &runtime_config,
        .resource_options = .{
            .cwd = project_dir,
            .agent_dir = runtime_config.agent_dir,
            .global = interactive_mode.settingsResources(runtime_config.global_settings),
            .project = interactive_mode.settingsResources(runtime_config.project_settings),
            .include_default_extensions = false,
            .include_default_skills = false,
            .include_default_prompts = false,
            .include_default_themes = false,
        },
    });
    defer built_tools.deinit();
    try std.testing.expect(built_tools.locked_native_runtimes != null);
    try std.testing.expectEqual(@as(usize, 1), built_tools.locked_native_runtimes.?.entries.len);
    try expectBuiltToolPresent(built_tools.items, "native.echo");
    try expectBuiltToolAbsent(built_tools.items, "template.echo");

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_dir,
        .system_prompt = "sys",
        .model = model,
        .session_dir = session_dir,
        .tools = built_tools.items,
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    const exit_code = try print_mode.runPrintMode(
        allocator,
        std.testing.io,
        &session,
        "call installed native",
        .{ .mode = .text, .install_signal_handlers = false },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    if (exit_code != 0) {
        std.debug.print("native invocation stdout:\n{s}\nnative invocation stderr:\n{s}\n", .{ stdout_capture.writer.buffered(), stderr_capture.writer.buffered() });
    }
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("installed native success observed\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
    try expectLatestToolResult(session.agent.getMessages(), .{
        .tool_call_id = "native-normal-success",
        .tool_name = "native.echo",
        .is_error = false,
        .content_contains = "\"message\":\"normal native path\"",
        .expected_runtime_kind = "native",
        .expected_extension_id = "com.pi.native.template.echo",
        .expected_artifact_sha256 = expected_artifact_sha256,
    });
    try std.testing.expect(!built_tools.locked_native_runtimes.?.entries[0].loaded.unloaded);
}

pub const NormalInvocationExpected = struct {
    prompt: []const u8,
    expected_stdout: []const u8,
    tool_name: []const u8,
    tool_call_id: []const u8,
    content_contains: []const u8,
    expected_artifact_sha256: []const u8,
};

pub fn runNormalTemplateInvocationWithPrompt(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    session_dir: []const u8,
    model: ai.Model,
    expected: NormalInvocationExpected,
) !void {
    var runtime_config = try loadAuthorRuntimeConfig(allocator, home_dir, agent_dir, project_dir);
    defer runtime_config.deinit();

    var app_context = interactive_mode.AppContext.init(project_dir, std.testing.io);
    var built_tools = try interactive_mode.buildAgentToolsWithOptions(allocator, &app_context, .{
        .selected_tools = tool_selection_mod.ToolSelection.fromAllowlist(&.{expected.tool_name}),
        .runtime_config = &runtime_config,
        .resource_options = .{
            .cwd = project_dir,
            .agent_dir = runtime_config.agent_dir,
            .global = interactive_mode.settingsResources(runtime_config.global_settings),
            .project = interactive_mode.settingsResources(runtime_config.project_settings),
            .include_default_extensions = false,
            .include_default_skills = false,
            .include_default_prompts = false,
            .include_default_themes = false,
        },
    });
    defer built_tools.deinit();
    try std.testing.expect(built_tools.locked_wasm_runtimes != null);
    try std.testing.expectEqual(@as(usize, 1), built_tools.locked_wasm_runtimes.?.entries.len);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_dir,
        .system_prompt = "sys",
        .model = model,
        .session_dir = session_dir,
        .tools = built_tools.items,
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    const exit_code = try print_mode.runPrintMode(
        allocator,
        std.testing.io,
        &session,
        expected.prompt,
        .{ .mode = .text, .install_signal_handlers = false },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings(expected.expected_stdout, stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
    try expectLatestToolResult(session.agent.getMessages(), .{
        .tool_call_id = expected.tool_call_id,
        .tool_name = expected.tool_name,
        .is_error = false,
        .content_contains = expected.content_contains,
        .expected_extension_id = "com.pi.template.echo",
        .expected_artifact_sha256 = expected.expected_artifact_sha256,
    });
    try std.testing.expectEqual(@as(usize, 0), built_tools.locked_wasm_runtimes.?.entries[0].adapter.pendingCount());
}

pub fn runNormalConstructionCase(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    model: ai.Model,
    prompt: []const u8,
    tool_options: interactive_mode.ToolBuildOptions,
    output_mode: print_mode.OutputMode,
    expected_stdout: ?[]const u8,
) !void {
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    try env_map.put("PI_OFFLINE", "1");

    var runtime_config = try config_mod.loadRuntimeConfigWithOptions(
        allocator,
        std.testing.io,
        &env_map,
        project_dir,
        .{ .discover_models = false },
    );
    defer runtime_config.deinit();

    var app_context = interactive_mode.AppContext.init(project_dir, std.testing.io);
    var build_options = tool_options;
    build_options.runtime_config = &runtime_config;
    build_options.resource_options = .{
        .cwd = project_dir,
        .agent_dir = runtime_config.agent_dir,
        .global = interactive_mode.settingsResources(runtime_config.global_settings),
        .project = interactive_mode.settingsResources(runtime_config.project_settings),
        .include_default_extensions = false,
        .include_default_skills = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    };

    var built_tools = try interactive_mode.buildAgentToolsWithOptions(allocator, &app_context, build_options);
    defer built_tools.deinit();

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_dir,
        .system_prompt = "sys",
        .model = model,
        .tools = built_tools.items,
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try print_mode.runPrintMode(
        allocator,
        std.testing.io,
        &session,
        prompt,
        .{
            .mode = output_mode,
            .install_signal_handlers = false,
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
    if (expected_stdout) |value| {
        try std.testing.expectEqualStrings(value, stdout_capture.writer.buffered());
    } else {
        try expectContains(stdout_capture.writer.buffered(), "\"type\":\"agent_start\"");
        try expectContains(stdout_capture.writer.buffered(), "\"type\":\"agent_end\"");
    }
}

pub fn expectProviderToolPresent(tools: []const ai.types.Tool, name: []const u8) !void {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return;
    }
    return error.ExpectedProviderToolMissing;
}

pub fn expectProviderToolAbsent(tools: []const ai.types.Tool, name: []const u8) !void {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return error.ExpectedProviderToolAbsent;
    }
}

pub fn expectProviderToolNamesExactly(tools: []const ai.types.Tool, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, tools.len);
    for (expected) |name| try expectProviderToolPresent(tools, name);
    for (tools) |tool| {
        var found = false;
        for (expected) |name| {
            if (std.mem.eql(u8, tool.name, name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

pub fn expectBuiltToolPresent(tools: []const agent.AgentTool, name: []const u8) !void {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return;
    }
    return error.ExpectedBuiltToolMissing;
}

pub fn expectBuiltToolAbsent(tools: []const agent.AgentTool, name: []const u8) !void {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return error.ExpectedBuiltToolAbsent;
    }
}

pub fn runPackageCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    options: package_manager.ExecuteOptions,
) !CommandCapture {
    var stdout: std.Io.Writer.Allocating = .init(allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();
    var parsed = try package_manager.parsePackageCommand(allocator, args);
    defer parsed.deinit(allocator);
    const result = try package_manager.executePackageCommand(
        allocator,
        std.testing.io,
        parsed,
        options,
        &stdout.writer,
        &stderr.writer,
    );
    return .{
        .exit_code = result.exit_code,
        .stdout = try allocator.dupe(u8, stdout.written()),
        .stderr = try allocator.dupe(u8, stderr.written()),
    };
}

pub fn startAuthorRuntimeSet(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
) !extension_runtime.LockedWasmRuntimeSet {
    var runtime_config = try loadAuthorRuntimeConfig(allocator, home_dir, agent_dir, project_dir);
    defer runtime_config.deinit();

    return extension_runtime.startLockedWasmPackageRuntimes(allocator, std.testing.io, &runtime_config, .{
        .cwd = project_dir,
        .agent_dir = runtime_config.agent_dir,
        .global = resources_mod.SettingsResources{ .packages = runtime_config.global_settings.packages },
        .project = resources_mod.SettingsResources{ .packages = runtime_config.project_settings.packages },
        .include_default_extensions = false,
        .include_default_skills = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
}

pub fn loadAuthorRuntimeConfig(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
) !config_mod.RuntimeConfig {
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    try env_map.put("PI_OFFLINE", "1");
    return config_mod.loadRuntimeConfigWithOptions(
        allocator,
        std.testing.io,
        &env_map,
        project_dir,
        .{ .discover_models = false },
    );
}

pub fn startNativeAuthorRuntimeSet(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
) !extension_runtime.LockedNativeRuntimeSet {
    var runtime_config = try loadAuthorRuntimeConfig(allocator, home_dir, agent_dir, project_dir);
    defer runtime_config.deinit();

    return extension_runtime.startLockedNativePackageRuntimes(allocator, std.testing.io, &runtime_config, .{
        .cwd = project_dir,
        .agent_dir = runtime_config.agent_dir,
        .global = resources_mod.SettingsResources{ .packages = runtime_config.global_settings.packages },
        .project = resources_mod.SettingsResources{ .packages = runtime_config.project_settings.packages },
        .include_default_extensions = false,
        .include_default_skills = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
}

pub fn buildAggregateAuthorTools(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    selection: tool_selection_mod.ToolSelection,
) !interactive_mode.BuiltTools {
    var runtime_config = try loadAuthorRuntimeConfig(allocator, home_dir, agent_dir, project_dir);
    defer runtime_config.deinit();
    var app_context = interactive_mode.AppContext.init(project_dir, std.testing.io);
    return interactive_mode.buildAgentToolsWithOptions(allocator, &app_context, .{
        .selected_tools = selection,
        .include_installed_wasm_tools = true,
        .include_installed_native_tools = true,
        .runtime_config = &runtime_config,
        .resource_options = .{
            .cwd = project_dir,
            .agent_dir = runtime_config.agent_dir,
            .global = interactive_mode.settingsResources(runtime_config.global_settings),
            .project = interactive_mode.settingsResources(runtime_config.project_settings),
            .include_default_extensions = false,
            .include_default_skills = false,
            .include_default_prompts = false,
            .include_default_themes = false,
        },
    });
}

pub fn executeAuthorTool(
    allocator: std.mem.Allocator,
    runtime_set: *extension_runtime.LockedWasmRuntimeSet,
    tool_name: []const u8,
    params_json: []const u8,
    expected_output: []const u8,
) !void {
    var agent_tool = (try runtime_set.agentTool(allocator, tool_name)) orelse return error.ExpectedAuthorTool;
    defer extension_runtime.deinitAgentTool(allocator, &agent_tool);
    try std.testing.expect(agent_tool.execute != null);
    var params = try std.json.parseFromSlice(std.json.Value, allocator, params_json, .{});
    defer params.deinit();
    const result = try agent_tool.execute.?(allocator, "author-workflow", params.value, agent_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, result.content);
    defer if (result.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expectEqualStrings(expected_output, result.content[0].text.text);
}

pub fn expectNoAuthorTool(
    allocator: std.mem.Allocator,
    runtime_set: *extension_runtime.LockedWasmRuntimeSet,
    tool_name: []const u8,
) !void {
    if (try runtime_set.agentTool(allocator, tool_name)) |tool| {
        var owned = tool;
        defer extension_runtime.deinitAgentTool(allocator, &owned);
        return error.ExpectedNoAuthorTool;
    }
}

pub fn expectRuntimeDenied(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    expected_kind: []const u8,
) !void {
    var runtime_set = try startAuthorRuntimeSet(allocator, home_dir, agent_dir, project_dir);
    defer runtime_set.deinit();
    try std.testing.expectEqual(@as(usize, 0), runtime_set.entries.len);
    var saw_expected = false;
    for (runtime_set.diagnostics) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.kind, expected_kind)) saw_expected = true;
    }
    try std.testing.expect(saw_expected);
    try expectNoAuthorTool(allocator, &runtime_set, "template.echo");
}

pub fn expectRuntimeDeniedWithFields(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    expected_kind: []const u8,
    expected_fields: []const []const u8,
) !void {
    try expectRuntimeDiagnosticWithFields(allocator, home_dir, agent_dir, project_dir, expected_kind, expected_fields, 0);
}

pub fn expectRuntimeDiagnosticWithFields(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    expected_kind: []const u8,
    expected_fields: []const []const u8,
    expected_entries: usize,
) !void {
    var runtime_set = try startAuthorRuntimeSet(allocator, home_dir, agent_dir, project_dir);
    defer runtime_set.deinit();
    try std.testing.expectEqual(expected_entries, runtime_set.entries.len);
    for (runtime_set.diagnostics) |diagnostic| {
        if (!std.mem.eql(u8, diagnostic.kind, expected_kind)) continue;
        for (expected_fields) |field| {
            if (diagnostic.path) |path| {
                if (std.mem.indexOf(u8, path, field) != null) continue;
            }
            try expectContains(diagnostic.message, field);
        }
        return;
    }
    return error.ExpectedRuntimeDiagnosticMissing;
}

pub fn expectMixedRuntimeDeniedWithFields(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    wasm_kind: []const u8,
    wasm_fields: []const []const u8,
    native_kind: []const u8,
    native_fields: []const []const u8,
) !void {
    try expectRuntimeDiagnosticWithFields(allocator, home_dir, agent_dir, project_dir, wasm_kind, wasm_fields, 0);
    var native_set = try startNativeAuthorRuntimeSet(allocator, home_dir, agent_dir, project_dir);
    defer native_set.deinit();
    try std.testing.expectEqual(@as(usize, 0), native_set.entries.len);
    try expectDiagnosticFields(native_set.diagnostics, native_kind, native_fields);
}

pub fn expectMixedRuntimeProjectDenied(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
) !void {
    try expectRuntimeDiagnosticWithFields(allocator, home_dir, agent_dir, project_dir, "missing_policy", &.{"scope=project"}, 1);
    var native_set = try startNativeAuthorRuntimeSet(allocator, home_dir, agent_dir, project_dir);
    defer native_set.deinit();
    try std.testing.expectEqual(@as(usize, 1), native_set.entries.len);
    try expectDiagnosticFields(native_set.diagnostics, "missing_policy", &.{"scope=project"});
}

pub fn expectDiagnosticFields(
    diagnostics: []const resources_mod.Diagnostic,
    expected_kind: []const u8,
    expected_fields: []const []const u8,
) !void {
    for (diagnostics) |diagnostic| {
        if (!std.mem.eql(u8, diagnostic.kind, expected_kind)) continue;
        for (expected_fields) |field| {
            if (diagnostic.path) |path| {
                if (std.mem.indexOf(u8, path, field) != null) continue;
            }
            try expectContains(diagnostic.message, field);
        }
        return;
    }
    return error.ExpectedRuntimeDiagnosticMissing;
}

pub fn writeAuthorSettings(
    allocator: std.mem.Allocator,
    settings_path: []const u8,
    source: []const u8,
    policy_key: []const u8,
    tool_scope: []const u8,
) !void {
    const source_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = source }, .{});
    defer allocator.free(source_json);
    const policy_key_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = policy_key }, .{});
    defer allocator.free(policy_key_json);
    const tool_scope_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = tool_scope }, .{});
    defer allocator.free(tool_scope_json);
    const settings = try std.fmt.allocPrint(allocator,
        \\{{"packages":[{{"source":{s}}}],"extensionPolicies":{{{s}:{{"resourceLimits":{{"toolScopes":[{s}],"outputBytes":65536}}}}}}}}
    , .{ source_json, policy_key_json, tool_scope_json });
    defer allocator.free(settings);
    try tools_common.writeFileAbsolute(std.testing.io, settings_path, settings, true);
}

pub fn writeAuthorSettingsWithPolicies(
    allocator: std.mem.Allocator,
    settings_path: []const u8,
    source: []const u8,
    policy_keys: []const []const u8,
    tool_scope: []const u8,
) !void {
    const source_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = source }, .{});
    defer allocator.free(source_json);
    const tool_scope_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = tool_scope }, .{});
    defer allocator.free(tool_scope_json);

    var policies: std.Io.Writer.Allocating = .init(allocator);
    defer policies.deinit();
    for (policy_keys, 0..) |policy_key, index| {
        if (index > 0) try policies.writer.writeAll(",");
        try std.json.Stringify.value(policy_key, .{}, &policies.writer);
        try policies.writer.print(
            \\:{{"resourceLimits":{{"toolScopes":[{s}],"outputBytes":65536}}}}
        , .{tool_scope_json});
    }

    const settings = try std.fmt.allocPrint(allocator,
        \\{{"packages":[{{"source":{s}}}],"extensionPolicies":{{{s}}}}}
    , .{ source_json, policies.written() });
    defer allocator.free(settings);
    try tools_common.writeFileAbsolute(std.testing.io, settings_path, settings, true);
}

pub const AggregatePolicyEntry = struct {
    source: []const u8,
    policy_key: []const u8,
    tool_scope: []const u8,
};

pub fn writeAggregateAuthorSettings(
    allocator: std.mem.Allocator,
    settings_path: []const u8,
    entries: []const AggregatePolicyEntry,
) !void {
    var packages: std.Io.Writer.Allocating = .init(allocator);
    defer packages.deinit();
    var policies: std.Io.Writer.Allocating = .init(allocator);
    defer policies.deinit();

    for (entries, 0..) |entry, index| {
        if (index > 0) {
            try packages.writer.writeAll(",");
            try policies.writer.writeAll(",");
        }
        const source_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = entry.source }, .{});
        defer allocator.free(source_json);
        const policy_key_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = entry.policy_key }, .{});
        defer allocator.free(policy_key_json);
        const tool_scope_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = entry.tool_scope }, .{});
        defer allocator.free(tool_scope_json);

        try packages.writer.print("{{\"source\":{s}}}", .{source_json});
        try policies.writer.print(
            \\{s}:{{"approvedGrants":[],"resourceLimits":{{"toolScopes":[{s}],"outputBytes":65536}}}}
        , .{ policy_key_json, tool_scope_json });
    }

    const settings = try std.fmt.allocPrint(allocator,
        \\{{"packages":[{s}],"extensionPolicies":{{{s}}}}}
    , .{ packages.written(), policies.written() });
    defer allocator.free(settings);
    try tools_common.writeFileAbsolute(std.testing.io, settings_path, settings, true);
}

pub fn exactWasmPolicyKeyForTest(
    allocator: std.mem.Allocator,
    manifest: *const wasm_manifest.Manifest,
    scope: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "wasm:locked:{s}:{s}:{s}:{s}:{s}:{s}:{s}:{s}",
        .{
            scope,
            manifest.schema_version,
            manifest.id,
            manifest.version,
            manifest.package_root_sha256,
            manifest.artifact_sha256,
            manifest.manifest_path,
            manifest.artifact_absolute_path,
        },
    );
}

pub fn legacyArtifactOnlyPolicyKeyForTest(
    allocator: std.mem.Allocator,
    manifest: *const wasm_manifest.Manifest,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "wasm:{s}:{s}:{s}:{s}:{s}:{s}",
        .{
            manifest.schema_version,
            manifest.id,
            manifest.version,
            manifest.artifact_sha256,
            manifest.manifest_path,
            manifest.artifact_absolute_path,
        },
    );
}

pub fn installedPackageSource(allocator: std.mem.Allocator, settings_path: []const u8) ![]u8 {
    const settings = try readFile(allocator, settings_path);
    defer allocator.free(settings);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, settings, .{});
    defer parsed.deinit();
    const packages = parsed.value.object.get("packages").?.array;
    const first = packages.items[0];
    return switch (first) {
        .string => |value| try allocator.dupe(u8, value),
        .object => |object| try allocator.dupe(u8, object.get("source").?.string),
        else => error.InvalidPackageSource,
    };
}

pub fn extractApprovalTarget(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const marker = "approval target:";
    const marker_index = std.mem.indexOf(u8, text, marker) orelse return error.ExpectedApprovalTarget;
    const after_marker = std.mem.trim(u8, text[marker_index + marker.len ..], " \t");
    const newline_index = std.mem.indexOfScalar(u8, after_marker, '\n') orelse after_marker.len;
    return allocator.dupe(u8, std.mem.trim(u8, after_marker[0..newline_index], " \t\r\n"));
}

pub fn extractApprovalTargetWithPrefix(allocator: std.mem.Allocator, text: []const u8, prefix: []const u8) ![]u8 {
    const marker = "approval target:";
    var remainder = text;
    while (std.mem.indexOf(u8, remainder, marker)) |marker_index| {
        const after_marker = std.mem.trim(u8, remainder[marker_index + marker.len ..], " \t");
        const newline_index = std.mem.indexOfScalar(u8, after_marker, '\n') orelse after_marker.len;
        const candidate = std.mem.trim(u8, after_marker[0..newline_index], " \t\r\n");
        if (std.mem.startsWith(u8, candidate, prefix)) return allocator.dupe(u8, candidate);
        remainder = after_marker[newline_index..];
    }
    return error.ExpectedApprovalTarget;
}

pub fn copyTemplateToTmp(allocator: std.mem.Allocator, tmp: anytype, package_relative_path: []const u8) ![]u8 {
    try tmp.dir.createDirPath(std.testing.io, package_relative_path);
    for (TEMPLATE_FILES) |relative_path| {
        if (std.fs.path.dirname(relative_path)) |dirname| {
            const target_dir = try std.fs.path.join(allocator, &.{ package_relative_path, dirname });
            defer allocator.free(target_dir);
            try tmp.dir.createDirPath(std.testing.io, target_dir);
        }
        const source_path = try std.fs.path.join(allocator, &.{ TEMPLATE_ROOT, relative_path });
        defer allocator.free(source_path);
        const bytes = try readFile(allocator, source_path);
        defer allocator.free(bytes);
        const target_path = try std.fs.path.join(allocator, &.{ package_relative_path, relative_path });
        defer allocator.free(target_path);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = target_path, .data = bytes });
    }
    return absoluteTmpPath(allocator, &tmp.sub_path, package_relative_path);
}

pub fn copyNativeTemplateToTmp(allocator: std.mem.Allocator, tmp: anytype, package_relative_path: []const u8) ![]u8 {
    try tmp.dir.createDirPath(std.testing.io, package_relative_path);
    for (NATIVE_TEMPLATE_FILES) |relative_path| {
        if (std.fs.path.dirname(relative_path)) |dirname| {
            const target_dir = try std.fs.path.join(allocator, &.{ package_relative_path, dirname });
            defer allocator.free(target_dir);
            try tmp.dir.createDirPath(std.testing.io, target_dir);
        }
        const source_path = try std.fs.path.join(allocator, &.{ NATIVE_TEMPLATE_ROOT, relative_path });
        defer allocator.free(source_path);
        const bytes = try readFile(allocator, source_path);
        defer allocator.free(bytes);
        const target_path = try std.fs.path.join(allocator, &.{ package_relative_path, relative_path });
        defer allocator.free(target_path);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = target_path, .data = bytes });
    }
    return absoluteTmpPath(allocator, &tmp.sub_path, package_relative_path);
}

pub fn writeNativeDynamicPackage(allocator: std.mem.Allocator, tmp: anytype, package_relative_path: []const u8) ![]u8 {
    try tmp.dir.createDirPath(std.testing.io, package_relative_path);
    const bin_relative_path = try std.fs.path.join(allocator, &.{ package_relative_path, "bin" });
    defer allocator.free(bin_relative_path);
    try tmp.dir.createDirPath(std.testing.io, bin_relative_path);
    const artifact_relative_path = try std.fs.path.join(allocator, &.{ package_relative_path, "bin/plugin.dylib" });
    defer allocator.free(artifact_relative_path);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = artifact_relative_path,
        .data = "native dynamic plugin placeholder",
    });
    const manifest_relative_path = try std.fs.path.join(allocator, &.{ package_relative_path, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_relative_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = manifest_relative_path, .data =
        \\{
        \\  "schemaVersion": "pi-extension.v0",
        \\  "id": "com.pi.native.dynamic",
        \\  "name": "Native Dynamic",
        \\  "version": "0.1.0",
        \\  "description": "Unsupported native dynamic package.",
        \\  "artifact": {
        \\    "kind": "native-dylib",
        \\    "path": "bin/plugin.dylib"
        \\  },
        \\  "tool": {
        \\    "id": "native.dynamic",
        \\    "description": "Unsupported native dynamic tool.",
        \\    "inputSchema": {},
        \\    "outputSchema": {}
        \\  },
        \\  "capabilities": []
        \\}
        \\
    });
    return absoluteTmpPath(allocator, &tmp.sub_path, package_relative_path);
}

pub fn runTemplateBuild(allocator: std.mem.Allocator, package_root: []const u8) !void {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "zig", "build", "-p", "." },
        .cwd = .{ .path = package_root },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (exitCodeFromTerm(result.term) != 0) {
        std.debug.print("zig build stdout:\n{s}\nzig build stderr:\n{s}\n", .{ result.stdout, result.stderr });
        return error.TemplateBuildFailed;
    }
}

pub fn runNativeTemplateBuild(allocator: std.mem.Allocator, package_root: []const u8) !void {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "zig", "build", "-p", "." },
        .cwd = .{ .path = package_root },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (exitCodeFromTerm(result.term) != 0) {
        std.debug.print("native zig build stdout:\n{s}\nnative zig build stderr:\n{s}\n", .{ result.stdout, result.stderr });
        return error.NativeTemplateBuildFailed;
    }
}

pub fn runNativeTemplateValidate(allocator: std.mem.Allocator, package_root: []const u8) !void {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "zig", "build", "-p", ".", "validate" },
        .cwd = .{ .path = package_root },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (exitCodeFromTerm(result.term) != 0) {
        std.debug.print("native zig build validate stdout:\n{s}\nnative zig build validate stderr:\n{s}\n", .{ result.stdout, result.stderr });
        return error.NativeTemplateValidationFailed;
    }
}

pub fn writeEditedAuthorSource(allocator: std.mem.Allocator, package_root: []const u8) !void {
    const source_path = try std.fs.path.join(allocator, &.{ package_root, "src/main.zig" });
    defer allocator.free(source_path);
    try tools_common.writeFileAbsolute(std.testing.io, source_path,
        \\const sdk = @import("pi-extension-sdk");
        \\
        \\const input_schema_json =
        \\    \\{"type":"object","required":["operation","value"],"properties":{"operation":{"type":"string"},"value":{"type":"string"}}}
        \\;
        \\const output_schema_json =
        \\    \\{"type":"object","required":["ok","tool","echo"],"properties":{"ok":{"type":"boolean"},"tool":{"type":"string"},"echo":{"type":"string"}}}
        \\;
        \\
        \\const metadata_json = sdk.staticMetadataJson(
        \\    "fixture.echo",
        \\    "Pi Zig Edited Fixture Echo",
        \\    "0.1.0",
        \\    "Returns fixture echo output after an author rebuild.",
        \\);
        \\const schema_json = sdk.staticSchemaJson(input_schema_json, output_schema_json);
        \\const edited_execute_output = "{\"ok\":true,\"tool\":\"fixture.echo\",\"echo\":\"edited runtime output\"}";
        \\
        \\export fn metadata() i32 {
        \\    return sdk.ptr(metadata_json);
        \\}
        \\
        \\export fn metadata_len() i32 {
        \\    return sdk.len(metadata_json);
        \\}
        \\
        \\export fn schema() i32 {
        \\    return sdk.ptr(schema_json);
        \\}
        \\
        \\export fn schema_len() i32 {
        \\    return sdk.len(schema_json);
        \\}
        \\
        \\export fn execute(input_ptr: [*]const u8, input_len: usize) i32 {
        \\    _ = input_ptr;
        \\    _ = input_len;
        \\    return sdk.ptr(edited_execute_output);
        \\}
        \\
        \\export fn execute_len() i32 {
        \\    return sdk.len(edited_execute_output);
        \\}
        \\
    , true);
}

pub fn writeEditedAuthorManifest(allocator: std.mem.Allocator, package_root: []const u8) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    try tools_common.writeFileAbsolute(std.testing.io, manifest_path,
        \\{
        \\  "schemaVersion": "pi-extension.v0",
        \\  "id": "com.pi.template.echo",
        \\  "name": "Pi Zig Edited Fixture Echo",
        \\  "version": "0.1.0",
        \\  "description": "Edited capability-free Zig WASM tool extension template.",
        \\  "artifact": {
        \\    "kind": "wasm-component",
        \\    "path": "wasm/plugin.wasm"
        \\  },
        \\  "tool": {
        \\    "id": "fixture.echo",
        \\    "description": "Returns fixture echo output after an author rebuild.",
        \\    "inputSchema": {
        \\      "type": "object",
        \\      "required": ["operation", "value"],
        \\      "properties": {
        \\        "operation": { "type": "string" },
        \\        "value": { "type": "string" }
        \\      }
        \\    },
        \\    "outputSchema": {
        \\      "type": "object",
        \\      "required": ["ok", "tool", "echo"],
        \\      "properties": {
        \\        "ok": { "type": "boolean" },
        \\        "tool": { "type": "string" },
        \\        "echo": { "type": "string" }
        \\      }
        \\    }
        \\  },
        \\  "capabilities": [],
        \\  "resourceLimits": {
        \\    "timeoutMs": 1000,
        \\    "outputBytes": 65536
        \\  }
        \\}
        \\
    , true);
}

pub fn writeRootOnlyAuthorManifest(allocator: std.mem.Allocator, package_root: []const u8) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    try tools_common.writeFileAbsolute(std.testing.io, manifest_path,
        \\{
        \\  "schemaVersion": "pi-extension.v0",
        \\  "id": "com.pi.template.echo",
        \\  "name": "Pi Zig Echo Template",
        \\  "version": "0.1.0",
        \\  "description": "Root-only metadata change for digest-bound policy validation.",
        \\  "artifact": {
        \\    "kind": "wasm-component",
        \\    "path": "wasm/plugin.wasm"
        \\  },
        \\  "tool": {
        \\    "id": "template.echo",
        \\    "description": "Echoes a message field from the JSON input.",
        \\    "inputSchema": {
        \\      "type": "object",
        \\      "required": ["message"],
        \\      "properties": {
        \\        "message": { "type": "string" }
        \\      }
        \\    },
        \\    "outputSchema": {
        \\      "type": "object",
        \\      "required": ["message"],
        \\      "properties": {
        \\        "message": { "type": "string" }
        \\      }
        \\    }
        \\  },
        \\  "capabilities": [],
        \\  "resourceLimits": {
        \\    "timeoutMs": 1000,
        \\    "outputBytes": 65536
        \\  }
        \\}
        \\
    , true);
}

pub fn writePackageRootDriftFile(
    allocator: std.mem.Allocator,
    package_root: []const u8,
    relative_path: []const u8,
    contents: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ package_root, relative_path });
    defer allocator.free(path);
    try tools_common.writeFileAbsolute(std.testing.io, path, contents, true);
}

pub fn expectPackageTreeExcludesProductSurfaces(allocator: std.mem.Allocator, package_root: []const u8) !void {
    var dir = try std.Io.Dir.openDir(.cwd(), std.testing.io, package_root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    try expectDirectoryTreeExcludesProductSurfaces(allocator, package_root, &dir);
}

pub fn expectDirectoryTreeExcludesProductSurfaces(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    dir: *std.Io.Dir,
) !void {
    var iterator = dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
        defer allocator.free(child_path);
        switch (entry.kind) {
            .directory => {
                if (std.mem.eql(u8, entry.name, ".zig-cache") or std.mem.eql(u8, entry.name, "zig-out")) continue;
                var child_dir = try std.Io.Dir.openDir(.cwd(), std.testing.io, child_path, .{ .iterate = true });
                defer child_dir.close(std.testing.io);
                try expectDirectoryTreeExcludesProductSurfaces(allocator, child_path, &child_dir);
            },
            .file => {
                if (std.mem.indexOf(u8, child_path, std.fs.path.sep_str ++ "sdk" ++ std.fs.path.sep_str) != null) continue;
                const ext = std.fs.path.extension(child_path);
                if (std.mem.eql(u8, ext, ".wasm") or std.mem.eql(u8, ext, ".dylib") or std.mem.eql(u8, ext, ".so") or std.mem.eql(u8, ext, ".dll")) continue;
                const bytes = try readFile(allocator, child_path);
                defer allocator.free(bytes);
                try expectNotContains(bytes, "Web Simulator");
                try expectNotContains(bytes, "Workflow");
                try expectNotContains(bytes, "Wiki");
                try expectNotContains(bytes, "QA");
                try expectNotContains(bytes, "Review");
                try expectNotContains(bytes, "marketplace");
                try expectNotContains(bytes, "signing");
                try expectNotContains(bytes, "Remote WASM");
                try expectNotContains(bytes, "remote WASM");
            },
            else => {},
        }
    }
}

pub fn appendFile(allocator: std.mem.Allocator, path: []const u8, suffix: []const u8) !void {
    const before = try readFile(allocator, path);
    defer allocator.free(before);
    const after = try std.mem.concat(allocator, u8, &.{ before, suffix });
    defer allocator.free(after);
    try tools_common.writeFileAbsolute(std.testing.io, path, after, true);
}

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .limited(1024 * 1024));
}

pub fn absoluteTmpPath(allocator: std.mem.Allocator, tmp_sub_path: []const u8, relative: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const rel = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp_sub_path, relative });
    defer allocator.free(rel);
    return std.fs.path.resolve(allocator, &.{ cwd, rel });
}

pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

pub fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

pub fn exitCodeFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}
