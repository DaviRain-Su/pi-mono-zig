const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const session_mod = @import("../session.zig");
const session_manager = @import("../session_manager.zig");
const session_json_helpers = @import("../session_json_helpers.zig");
const tools_common = @import("../../tools/common.zig");
const extension_runtime = @import("../../extensions/extension_runtime.zig");
const extension_registry = @import("../../extensions/extension_registry.zig");
const sdk = @import("../../extensions/sdk.zig");
const wasm_manifest = @import("../../extensions/wasm/wasm_manifest.zig");

const AgentSession = session_mod.AgentSession;
const ExtensionHookContext = session_mod.testing.ExtensionHookContext;
const makeObject = session_json_helpers.makeObject;
const putString = session_json_helpers.putString;
const putBool = session_json_helpers.putBool;
const putValue = session_json_helpers.putValue;
const jsonObjectWithString = session_json_helpers.jsonObjectWithString;
const jsonObjectWithTruncateInput = session_json_helpers.jsonObjectWithTruncateInput;

fn absoluteSessionTmpPath(allocator: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", sub_path, name });
}

fn expectToolResultContains(messages: []const agent.AgentMessage, tool_name: []const u8, expected: []const u8) !void {
    for (messages) |message| {
        if (message != .tool_result) continue;
        if (!std.mem.eql(u8, message.tool_result.tool_name, tool_name)) continue;
        for (message.tool_result.content) |block| {
            if (block != .text) continue;
            if (std.mem.indexOf(u8, block.text.text, expected) != null) return;
        }
    }
    return error.ExpectedToolResultNotFound;
}

fn crossNativeEchoExecute(ctx: *sdk.ToolContext) !agent.AgentToolResult {
    const allocator = ctx.allocator;
    const params = ctx.params;
    if (params != .object) return crossNativeInvalidInput(allocator);
    const value = params.object.get("value") orelse return crossNativeInvalidInput(allocator);
    if (value != .string) return crossNativeInvalidInput(allocator);
    const text = try std.fmt.allocPrint(allocator, "{{\"runtime\":\"native\",\"echo\":\"{s}\"}}", .{value.string});
    defer allocator.free(text);
    return .{ .content = try tools_common.makeTextContent(allocator, text) };
}

fn crossNativeInvalidInput(allocator: std.mem.Allocator) !agent.AgentToolResult {
    return .{
        .content = try tools_common.makeTextContent(allocator, "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"expected object with string value\"}}"),
        .is_error = true,
    };
}

const cross_native_tool: extension_runtime.NativeToolDefinition = .{
    .name = "native.cross.echo",
    .label = "Native Cross Echo",
    .description = "Echoes a string through the cross-runtime native fixture.",
    .input_schema_json = "{\"type\":\"object\",\"required\":[\"value\"],\"properties\":{\"value\":{\"type\":\"string\"}},\"additionalProperties\":false}",
    .output_schema_json = "{\"type\":\"object\"}",
    .extension_path = "native://cross/echo",
    .execute = crossNativeEchoExecute,
};

const cross_native_descriptor: extension_runtime.NativeDescriptor = .{
    .id = "com.pi.native-cross-runtime",
    .name = "Native Cross Runtime",
    .version = "0.1.0",
    .description = "Native fixture used by the cross-runtime workflow lifecycle contract.",
    .tools = &.{cross_native_tool},
};

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
    var manager_transferred = false;
    errdefer if (!manager_transferred) std.testing.allocator.destroy(manager);
    manager.* = try session_manager.SessionManager.inMemory(std.testing.allocator, std.testing.io, "/tmp/project");
    errdefer if (!manager_transferred) manager.deinit();

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

    var session = try AgentSession.createWithManager(
        std.testing.allocator,
        std.testing.io,
        manager,
        .{
            .cwd = "/tmp/project",
            .system_prompt = "system prompt",
            .model = model,
        },
    );
    manager_transferred = true;
    defer session.deinit();

    try session.navigateTo(main_id);
    try std.testing.expectEqual(@as(usize, 2), session.agent.getMessages().len);
    try std.testing.expectEqualStrings("main", session.agent.getMessages()[1].assistant.content[0].text.text);

    try session.navigateTo(branch_id);
    try std.testing.expectEqual(@as(usize, 2), session.agent.getMessages().len);
    try std.testing.expectEqualStrings("branch", session.agent.getMessages()[1].assistant.content[0].text.text);
}

test "agent session tree navigation matches user parentage and summary attachment" {
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
    var manager_transferred = false;
    errdefer if (!manager_transferred) std.testing.allocator.destroy(manager);
    manager.* = try session_manager.SessionManager.inMemory(std.testing.allocator, std.testing.io, "/tmp/project");
    errdefer if (!manager_transferred) manager.deinit();

    var root = try makeUserMessage("root prompt", 1);
    defer session_manager.deinitMessage(std.testing.allocator, &root);
    const root_id = try manager.appendMessage(root);

    var main = try makeAssistantMessage("main branch", model, 2);
    defer session_manager.deinitMessage(std.testing.allocator, &main);
    const main_id = try manager.appendMessage(main);

    try manager.branch(root_id);
    var alternate_prompt = try makeUserMessage("alternate prompt", 3);
    defer session_manager.deinitMessage(std.testing.allocator, &alternate_prompt);
    const alternate_user_id = try manager.appendMessage(alternate_prompt);

    var alternate_reply = try makeAssistantMessage("alternate reply", model, 4);
    defer session_manager.deinitMessage(std.testing.allocator, &alternate_reply);
    const alternate_reply_id = try manager.appendMessage(alternate_reply);

    try manager.branch(main_id);

    var session = try AgentSession.createWithManager(
        std.testing.allocator,
        std.testing.io,
        manager,
        .{
            .cwd = "/tmp/project",
            .system_prompt = "system prompt",
            .model = model,
        },
    );
    manager_transferred = true;
    defer session.deinit();

    var user_result = try session.navigateTree(std.testing.allocator, alternate_user_id, .{});
    defer user_result.deinit(std.testing.allocator);
    try std.testing.expect(user_result.editor_text != null);
    try std.testing.expectEqualStrings("alternate prompt", user_result.editor_text.?);
    try std.testing.expectEqualStrings(root_id, session.session_manager.getLeafId().?);
    try std.testing.expectEqual(@as(usize, 1), session.agent.getMessages().len);
    try std.testing.expectEqualStrings("root prompt", session.agent.getMessages()[0].user.content[0].text.text);

    try session.navigateTo(main_id);
    var summary_result = try session.navigateTree(std.testing.allocator, alternate_reply_id, .{
        .summarize = true,
        .summary_text = "summarized abandoned branch",
    });
    defer summary_result.deinit(std.testing.allocator);
    try std.testing.expect(summary_result.summary_entry_id != null);
    const summary_entry = session.session_manager.getEntry(summary_result.summary_entry_id.?);
    try std.testing.expect(summary_entry != null);
    try std.testing.expect(summary_entry.?.* == .branch_summary);
    try std.testing.expectEqualStrings(alternate_reply_id, summary_entry.?.branch_summary.parent_id.?);
    try std.testing.expectEqualStrings(summary_result.summary_entry_id.?, session.session_manager.getLeafId().?);
    try std.testing.expect(std.mem.indexOf(u8, session.agent.getMessages()[session.agent.getMessages().len - 1].user.content[0].text.text, "summarized abandoned branch") != null);
}

test "VAL-CROSS-006 session reload keeps errored partial assistant inert" {
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
    var manager_transferred = false;
    errdefer if (!manager_transferred) std.testing.allocator.destroy(manager);
    manager.* = try session_manager.SessionManager.inMemory(std.testing.allocator, std.testing.io, "/tmp/project");
    errdefer if (!manager_transferred) manager.deinit();

    var prompt = try makeUserMessage("root", 1);
    defer session_manager.deinitMessage(std.testing.allocator, &prompt);
    _ = try manager.appendMessage(prompt);

    var errored = try makeErroredPartialAssistantMessage(model, 2);
    defer session_manager.deinitMessage(std.testing.allocator, &errored);
    _ = try manager.appendMessage(errored);

    var session = try AgentSession.createWithManager(
        std.testing.allocator,
        std.testing.io,
        manager,
        .{
            .cwd = "/tmp/project",
            .system_prompt = "system prompt",
            .model = model,
        },
    );
    manager_transferred = true;
    defer session.deinit();

    try session_mod.testing.reloadFromSession(&session);
    try session_mod.testing.reloadFromSession(&session);

    const messages = session.agent.getMessages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("root", messages[0].user.content[0].text.text);
    const entries = session.session_manager.getEntries();
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expect(entries[1] == .message);
    const assistant = entries[1].message.message.assistant;
    try std.testing.expectEqual(ai.StopReason.error_reason, assistant.stop_reason);
    try std.testing.expect(!ai.types.shouldReplayAssistantInProviderContext(assistant));
    try std.testing.expectEqual(@as(usize, 3), assistant.content.len);
    try std.testing.expectEqualStrings("partial text", assistant.content[0].text.text);
    try std.testing.expectEqualStrings("private thought", assistant.content[1].thinking.thinking);
    try std.testing.expectEqualStrings("partial-call", assistant.content[2].tool_call.id);
    try std.testing.expectEqualStrings("lookup", assistant.content[2].tool_call.name);
    try std.testing.expectEqualStrings("partial", assistant.content[2].tool_call.arguments.object.get("query").?.string);
    try std.testing.expect(assistant.tool_calls == null);
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

test "auto compaction treats Kimi exceeded model errors as context overflow" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("warmup reply")}, .{}) },
        .{ .message = faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "HTTP 400: {\"error\":{\"type\":\"invalid_request_error\",\"message\":\"Invalid request: Your request exceeded model [REDACTED].\"}}" }) },
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("recovered after Kimi compaction")}, .{}) },
    });

    var model = registration.getModel();
    model.context_window = 32;
    model.provider = "kimi-coding";
    model.id = "kimi-for-coding";

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
    try session.prompt("second prompt that exceeds Kimi context");

    const messages = session.agent.getMessages();
    try std.testing.expect(messages.len >= 3);
    try std.testing.expect(std.mem.startsWith(u8, messages[0].user.content[0].text.text, "[compaction]\n"));
    try std.testing.expectEqualStrings("recovered after Kimi compaction", messages[messages.len - 1].assistant.content[0].text.text);
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

fn makeErroredPartialAssistantMessage(model: ai.Model, timestamp: i64) !agent.AgentMessage {
    var args_object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    try args_object.put(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, "query"),
        .{ .string = try std.testing.allocator.dupe(u8, "partial") },
    );
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 3);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, "partial text") } };
    blocks[1] = .{ .thinking = .{
        .thinking = try std.testing.allocator.dupe(u8, "private thought"),
        .thinking_signature = try std.testing.allocator.dupe(u8, "think-sig"),
    } };
    blocks[2] = .{ .tool_call = .{
        .id = try std.testing.allocator.dupe(u8, "partial-call"),
        .name = try std.testing.allocator.dupe(u8, "lookup"),
        .arguments = .{ .object = args_object },
        .thought_signature = try std.testing.allocator.dupe(u8, "tool-sig"),
    } };
    return .{ .assistant = .{
        .role = try std.testing.allocator.dupe(u8, "assistant"),
        .content = blocks,
        .tool_calls = null,
        .api = try std.testing.allocator.dupe(u8, model.api),
        .provider = try std.testing.allocator.dupe(u8, model.provider),
        .model = try std.testing.allocator.dupe(u8, model.id),
        .response_id = try std.testing.allocator.dupe(u8, "resp-partial-error"),
        .usage = ai.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = try std.testing.allocator.dupe(u8, "provider failed after partials"),
        .timestamp = timestamp,
    } };
}

const TestHookHost = struct {
    input: bool = false,
    before_agent_start: bool = false,
    context: bool = false,
    agent_start: bool = false,
    agent_end: bool = false,
    turn_start: bool = false,
    message_start: bool = false,
    message_update: bool = false,
    message_end: bool = false,
    turn_end: bool = false,
    tool_call: bool = false,
    tool_result: bool = false,
    tool_execution_start: bool = false,
    tool_execution_update: bool = false,
    tool_execution_end: bool = false,
    model_select: bool = false,
    thinking_level_select: bool = false,
    session_start: bool = false,
    session_shutdown: bool = false,
    session_compact: bool = false,
    session_tree: bool = false,
    user_bash: bool = false,
    resources_discover: bool = false,
    session_before_compact: bool = false,
    session_before_tree: bool = false,
    cancel_session_before: bool = false,
    before_provider_request: bool = false,
    after_provider_response: bool = false,
    label: []const u8 = "",
    order_log: ?*std.ArrayList([]const u8) = null,
    order_allocator: ?std.mem.Allocator = null,
    input_calls: usize = 0,
    before_calls: usize = 0,
    context_calls: usize = 0,
    agent_start_calls: usize = 0,
    agent_end_calls: usize = 0,
    turn_start_calls: usize = 0,
    message_start_calls: usize = 0,
    message_update_calls: usize = 0,
    message_end_calls: usize = 0,
    turn_end_calls: usize = 0,
    tool_call_calls: usize = 0,
    tool_result_calls: usize = 0,
    tool_execution_start_calls: usize = 0,
    tool_execution_update_calls: usize = 0,
    tool_execution_end_calls: usize = 0,
    model_select_calls: usize = 0,
    thinking_level_select_calls: usize = 0,
    session_start_calls: usize = 0,
    session_shutdown_calls: usize = 0,
    session_compact_calls: usize = 0,
    session_tree_calls: usize = 0,
    user_bash_calls: usize = 0,
    resources_discover_calls: usize = 0,
    session_before_compact_calls: usize = 0,
    session_before_tree_calls: usize = 0,
    before_provider_request_calls: usize = 0,
    after_provider_response_calls: usize = 0,
    expected_model_select_model_id: ?[]const u8 = null,
    expected_model_select_previous_id: ?[]const u8 = null,
    expected_model_select_source: ?[]const u8 = null,
    model_select_payload_matched: bool = false,
    input_handled: bool = false,
    before_agent_start_handled: bool = false,
    context_invalid: bool = false,

    fn adapter(self: *TestHookHost) extension_runtime.RuntimeAdapter {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &test_hook_vtable,
            .kind = .process_jsonl,
        };
    }
};

fn testHookHost(ptr: *anyopaque) *TestHookHost {
    return @ptrCast(@alignCast(ptr));
}

fn testHookWait(ptr: *anyopaque, timeout_ms: u64) !void {
    _ = ptr;
    _ = timeout_ms;
}
fn testHookZero(ptr: *anyopaque) usize {
    _ = ptr;
    return 0;
}
fn testHookFalse(ptr: *anyopaque) bool {
    _ = ptr;
    return false;
}
fn testHookCategoryCount(ptr: *anyopaque, category: extension_runtime.DiagnosticCategory) usize {
    _ = ptr;
    _ = category;
    return 0;
}
fn testHookHasCommand(ptr: *anyopaque, name: []const u8) bool {
    _ = ptr;
    _ = name;
    return false;
}
/// Names of TestHookHost flag fields that map 1:1 to extension event names.
/// Each entry must match both an `event_name` string and a `bool` field on
/// TestHookHost; counter fields use the same name with a `_calls` suffix.
const test_hook_event_flag_names = [_][]const u8{
    "input",
    "before_agent_start",
    "context",
    "agent_start",
    "agent_end",
    "turn_start",
    "message_start",
    "message_update",
    "message_end",
    "turn_end",
    "tool_call",
    "tool_result",
    "tool_execution_start",
    "tool_execution_update",
    "tool_execution_end",
    "model_select",
    "thinking_level_select",
    "session_start",
    "session_shutdown",
    "session_compact",
    "session_tree",
    "user_bash",
    "resources_discover",
    "session_before_compact",
    "session_before_tree",
    "before_provider_request",
    "after_provider_response",
};

fn testHookHasHook(ptr: *anyopaque, event_name: []const u8) bool {
    const host = testHookHost(ptr);
    inline for (test_hook_event_flag_names) |name| {
        if (std.mem.eql(u8, event_name, name)) return @field(host, name);
    }
    return false;
}
fn testHookSnapshot(ptr: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    _ = ptr;
    return try allocator.dupe(u8, "{}");
}
fn testHookWithRegistry(ptr: *anyopaque, context: ?*anyopaque, callback: extension_runtime.RegistryCallback) !void {
    _ = ptr;
    _ = context;
    _ = callback;
}
fn testHookApplyFlags(ptr: *anyopaque, entries: []const extension_registry.ParsedCliFlag) !void {
    _ = ptr;
    _ = entries;
}
fn testHookAgentTool(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) !?agent.AgentTool {
    _ = ptr;
    _ = allocator;
    _ = name;
    return null;
}
fn testHookUiRequests(ptr: *anyopaque, allocator: std.mem.Allocator) ![]extension_runtime.ExtensionUiRequest {
    _ = ptr;
    return try allocator.alloc(extension_runtime.ExtensionUiRequest, 0);
}
fn testHookUiResponse(ptr: *anyopaque, id: []const u8, payload_json: []const u8) !void {
    _ = ptr;
    _ = id;
    _ = payload_json;
}
fn testHookEventFrame(ptr: *anyopaque, frame_json: []const u8) void {
    _ = ptr;
    _ = frame_json;
}
fn testHookInvoke(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    event_name: []const u8,
    event: std.json.Value,
    timeout_ms: u64,
) !?std.json.Value {
    _ = timeout_ms;
    const host = testHookHost(ptr);
    if (host.order_log) |log| {
        const name = if (host.label.len > 0) host.label else event_name;
        try log.append(host.order_allocator orelse allocator, name);
    }
    var result = try makeObject(allocator);
    errdefer tools_common.deinitJsonValue(allocator, result);
    if (std.mem.eql(u8, event_name, "input")) {
        host.input_calls += 1;
        if (host.input_handled) {
            try putString(allocator, &result.object, "action", "handled");
            try putString(allocator, &result.object, "reason", "input denied by fixture");
            return result;
        }
        try putString(allocator, &result.object, "text", "hooked input");
        return result;
    }
    if (std.mem.eql(u8, event_name, "before_agent_start")) {
        host.before_calls += 1;
        if (host.before_agent_start_handled) {
            try putString(allocator, &result.object, "action", "deny");
            try putString(allocator, &result.object, "reason", "startup denied by fixture");
            return result;
        }
        try putString(allocator, &result.object, "text", "hooked before");
        try putString(allocator, &result.object, "systemPrompt", "hook system");
        return result;
    }
    if (std.mem.eql(u8, event_name, "context")) {
        host.context_calls += 1;
        var messages = std.json.Array.init(allocator);
        if (host.context_invalid) {
            var invalid = try makeObject(allocator);
            try putString(allocator, &invalid.object, "role", "user");
            try messages.append(invalid);
            try putValue(allocator, &result.object, "messages", .{ .array = messages });
            return result;
        }
        try messages.append(.{ .string = try allocator.dupe(u8, "hook context") });
        try putValue(allocator, &result.object, "messages", .{ .array = messages });
        return result;
    }
    if (std.mem.eql(u8, event_name, "tool_call")) {
        host.tool_call_calls += 1;
        var input = try makeObject(allocator);
        try putString(allocator, &input.object, "value", "mutated");
        try putValue(allocator, &result.object, "input", input);
        return result;
    }
    if (std.mem.eql(u8, event_name, "tool_result")) {
        host.tool_result_calls += 1;
        try putString(allocator, &result.object, "content", "patched result");
        try putBool(allocator, &result.object, "isError", false);
        return result;
    }
    if (std.mem.eql(u8, event_name, "model_select")) {
        host.model_select_calls += 1;
        if (host.expected_model_select_model_id) |expected_model_id| {
            const expected_previous_id = host.expected_model_select_previous_id orelse "";
            const expected_source = host.expected_model_select_source orelse "";
            if (event == .object) {
                const model_value = event.object.get("model");
                const previous_value = event.object.get("previousModel");
                const source_value = event.object.get("source");
                if (model_value != null and
                    previous_value != null and
                    source_value != null and
                    model_value.? == .object and
                    previous_value.? == .object and
                    source_value.? == .string)
                {
                    const model_id = model_value.?.object.get("id");
                    const previous_id = previous_value.?.object.get("id");
                    if (model_id != null and
                        previous_id != null and
                        model_id.? == .string and
                        previous_id.? == .string)
                    {
                        host.model_select_payload_matched =
                            std.mem.eql(u8, model_id.?.string, expected_model_id) and
                            std.mem.eql(u8, previous_id.?.string, expected_previous_id) and
                            std.mem.eql(u8, source_value.?.string, expected_source);
                    }
                }
            }
        }
        return result;
    }
    if (std.mem.eql(u8, event_name, "session_before_compact")) {
        host.session_before_compact_calls += 1;
        if (host.cancel_session_before) try putBool(allocator, &result.object, "cancel", true);
        return result;
    }
    if (std.mem.eql(u8, event_name, "session_before_tree")) {
        host.session_before_tree_calls += 1;
        if (host.cancel_session_before) try putBool(allocator, &result.object, "cancel", true);
        return result;
    }
    // Simple counter-only events: each fixture event name has a matching
    // `<name>_calls` field on TestHookHost. Adding a new notification-only
    // event only needs a single entry here plus the bool/counter pair on
    // TestHookHost.
    inline for ([_][]const u8{
        "agent_start",
        "agent_end",
        "turn_start",
        "message_start",
        "message_update",
        "message_end",
        "turn_end",
        "tool_execution_start",
        "tool_execution_update",
        "tool_execution_end",
        "thinking_level_select",
        "session_start",
        "session_shutdown",
        "session_compact",
        "session_tree",
        "user_bash",
        "resources_discover",
        "before_provider_request",
        "after_provider_response",
    }) |name| {
        if (std.mem.eql(u8, event_name, name)) {
            @field(host, name ++ "_calls") += 1;
            return result;
        }
    }
    return result;
}
fn testHookShutdown(ptr: *anyopaque) !void {
    _ = ptr;
}
fn testHookDeinit(ptr: *anyopaque) void {
    _ = ptr;
}

const test_hook_vtable: extension_runtime.RuntimeAdapter.VTable = .{
    .wait_for_ready = testHookWait,
    .pending_count = testHookZero,
    .diagnostic_count = testHookZero,
    .diagnostic_category_count = testHookCategoryCount,
    .has_shutdown_complete = testHookFalse,
    .registry_frames_applied = testHookZero,
    .has_registered_command = testHookHasCommand,
    .has_registered_hook = testHookHasHook,
    .snapshot_registry_json = testHookSnapshot,
    .with_registry = testHookWithRegistry,
    .apply_cli_flag_values = testHookApplyFlags,
    .agent_tool = testHookAgentTool,
    .take_ui_requests = testHookUiRequests,
    .send_extension_ui_response = testHookUiResponse,
    .send_extension_event_frame = testHookEventFrame,
    .invoke_extension_event = testHookInvoke,
    .shutdown = testHookShutdown,
    .deinit = testHookDeinit,
};

test "mixed runtime adapter helper covers tool hook workflow shutdown contracts" {
    const allocator = std.testing.allocator;
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const response_allocator = arena.allocator();

    const process_args = try jsonObjectWithString(response_allocator, "value", "process-input");
    const wasm_args = try jsonObjectWithTruncateInput(response_allocator, "alpha\nbravo\ncharlie", 2, 1024);
    const native_args = try jsonObjectWithString(response_allocator, "value", "native-input");
    const workflow_args = try jsonObjectWithString(response_allocator, "issue", "mixed-flow");
    const blocks = try response_allocator.alloc(faux.FauxContentBlock, 4);
    blocks[0] = try faux.fauxToolCall(response_allocator, "process-cross-tool", process_args, .{ .id = "cross-process-call" });
    blocks[1] = try faux.fauxToolCall(response_allocator, "builtin.truncateHead", wasm_args, .{ .id = "cross-wasm-call" });
    blocks[2] = try faux.fauxToolCall(response_allocator, "native.cross.echo", native_args, .{ .id = "cross-native-call" });
    blocks[3] = try faux.fauxToolCall(response_allocator, "workflow.cross-chain", workflow_args, .{ .id = "cross-workflow-call" });
    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("mixed runtime complete")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use }) },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const process_capture_path = try absoluteSessionTmpPath(allocator, &tmp.sub_path, "cross-runtime-process-capture.jsonl");
    defer allocator.free(process_capture_path);
    const process_script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; printf '%s\\n' \"$init\" > {s}; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "printf '{{\"type\":\"register_tool\",\"name\":\"process-cross-tool\",\"label\":\"Process Cross Tool\",\"description\":\"cross runtime process tool\",\"parameters\":{{\"type\":\"object\",\"required\":[\"value\"],\"properties\":{{\"value\":{{\"type\":\"string\"}}}},\"additionalProperties\":false}},\"extensionPath\":\"fixture/process-cross.ts\"}}\\n'; " ++
            "for hook in input before_agent_start context tool_call tool_result turn_start message_end turn_end; do printf '{{\"type\":\"register_hook\",\"event\":\"%s\",\"priority\":0,\"declarationOrder\":0,\"errorPolicy\":\"continue\",\"extensionPath\":\"fixture/process-cross.ts\"}}\\n' \"$hook\"; done; " ++
            "printf '{{\"type\":\"register_workflow\",\"id\":\"cross-chain\",\"description\":\"Mixed runtime workflow\",\"inputSchema\":{{\"type\":\"object\",\"required\":[\"issue\"],\"properties\":{{\"issue\":{{\"type\":\"string\"}}}},\"additionalProperties\":false}},\"outputSchema\":{{\"type\":\"object\",\"required\":[\"summary\"],\"properties\":{{\"summary\":{{\"type\":\"string\"}}}}}},\"toolName\":\"workflow.cross-chain\",\"commandName\":\"workflow-cross-chain\",\"presetId\":\"workflow-cross-chain-preset\",\"permissions\":[\"agent.delegate\"],\"childAgentLimits\":{{\"maxChildren\":1,\"maxTurns\":1,\"maxToolCalls\":1,\"timeoutMs\":100}},\"steps\":[{{\"id\":\"process-step\",\"kind\":\"side_effect\",\"input\":{{\"value\":\"from-workflow\"}},\"output\":{{\"runtime\":\"process\"}},\"replayMode\":\"recorded\",\"selectedCapability\":\"process-cross-tool\"}},{{\"id\":\"wasm-step\",\"kind\":\"side_effect\",\"input\":{{\"content\":\"alpha\\\\nbravo\",\"maxLines\":1,\"maxBytes\":1024}},\"output\":{{\"runtime\":\"wasm\"}},\"replayMode\":\"recorded\",\"selectedCapability\":\"builtin.truncateHead\"}},{{\"id\":\"native-step\",\"kind\":\"side_effect\",\"input\":{{\"value\":\"from-workflow\"}},\"output\":{{\"runtime\":\"native\"}},\"replayMode\":\"recorded\",\"selectedCapability\":\"native.cross.echo\"}},{{\"id\":\"child-step\",\"kind\":\"child_agent\",\"childDelta\":{{\"childrenStarted\":1,\"turns\":1,\"toolCalls\":1,\"elapsedMs\":10,\"permission\":\"agent.delegate\"}},\"output\":{{\"summary\":\"mixed workflow complete\"}},\"selectedCapability\":\"agent.delegate\"}}],\"extensionPath\":\"fixture/workflows.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_workflow\",\"id\":\"cross-cancel\",\"description\":\"Cancellable mixed workflow\",\"inputSchema\":{{\"type\":\"object\"}},\"outputSchema\":{{}},\"toolName\":\"workflow.cross-cancel\",\"steps\":[{{\"id\":\"active\",\"runtimeWork\":true,\"output\":{{\"ok\":true}}}}],\"extensionPath\":\"fixture/workflows.ts\"}}\\n'; " ++
            "while IFS= read -r line; do " ++
            "printf '%s\\n' \"$line\" >> {s}; " ++
            "case \"$line\" in " ++
            "*'\"type\":\"extension_event\"'*) event_id=$(printf '%s' \"$line\" | sed -n 's/.*\"eventId\":\"\\([^\"]*\\)\".*/\\1/p'); printf '{{\"type\":\"extension_event_result\",\"eventId\":\"%s\",\"result\":{{}}}}\\n' \"$event_id\";; " ++
            "*'\"toolName\":\"process-cross-tool\"'*) tool_call_id=$(printf '%s' \"$line\" | sed -n 's/.*\"toolCallId\":\"\\([^\"]*\\)\".*/\\1/p'); printf '{{\"type\":\"tool_result\",\"toolCallId\":\"%s\",\"content\":[{{\"type\":\"text\",\"text\":\"process cross ok\"}}],\"details\":{{\"runtime\":\"process_jsonl\",\"phase\":\"call\"}}}}\\n' \"$tool_call_id\";; " ++
            "*'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; " ++
            "esac; done",
        .{ process_capture_path, process_capture_path },
    );
    defer allocator.free(process_script);
    const process_argv = [_][]const u8{ "/bin/sh", "-c", process_script, "cross-runtime-process" };
    const process_adapter = try extension_runtime.startRuntimeAdapter(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &process_argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "cross-runtime-process",
            .cwd = "/cross-runtime-cwd",
            .fixture = "cross-runtime-process",
        },
        .shutdown_timeout_ms = 500,
    } });
    defer process_adapter.deinit();
    try process_adapter.waitForReady(500);
    var process_elapsed: u64 = 0;
    while (process_adapter.registryFramesApplied() < 11 and process_elapsed <= 1000) : (process_elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 11), process_adapter.registryFramesApplied());

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const wasm_adapter = try extension_runtime.startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
        .manifest = extension_runtime.WasmManifestHandoff.fromManifest(&manifest_result.valid),
    } });
    defer wasm_adapter.deinit();
    try wasm_adapter.waitForReady(0);

    const native_adapter = try extension_runtime.startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
        .descriptor = &cross_native_descriptor,
    } });
    defer native_adapter.deinit();
    try native_adapter.waitForReady(0);

    var process_tool = (try process_adapter.agentTool(allocator, "process-cross-tool")).?;
    defer extension_runtime.deinitAgentTool(allocator, &process_tool);
    var wasm_tool = (try wasm_adapter.agentTool(allocator, "builtin.truncateHead")).?;
    defer extension_runtime.deinitAgentTool(allocator, &wasm_tool);
    var native_tool = (try native_adapter.agentTool(allocator, "native.cross.echo")).?;
    defer extension_runtime.deinitAgentTool(allocator, &native_tool);
    var workflow_tool = (try process_adapter.agentTool(allocator, "workflow.cross-chain")).?;
    defer extension_runtime.deinitAgentTool(allocator, &workflow_tool);
    var cancel_tool = (try process_adapter.agentTool(allocator, "workflow.cross-cancel")).?;
    defer extension_runtime.deinitAgentTool(allocator, &cancel_tool);

    const extension_hosts = [_]extension_runtime.RuntimeAdapter{ process_adapter, wasm_adapter, native_adapter };
    var session_tools = [_]agent.AgentTool{ process_tool, wasm_tool, native_tool, workflow_tool };
    try extension_runtime.attachWorkflowDispatchAdapters(allocator, session_tools[0..], extension_hosts[0..]);
    var session = try AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/cross-runtime-e2e",
        .system_prompt = "system",
        .model = registration.getModel(),
        .tools = session_tools[0..],
        .extension_hosts = extension_hosts[0..],
    });
    defer session.deinit();
    try session.prompt("run mixed runtime flow");

    const messages = session.agent.getMessages();
    try std.testing.expect(messages.len >= 7);
    try std.testing.expectEqualStrings("mixed runtime complete", messages[messages.len - 1].assistant.content[0].text.text);
    try expectToolResultContains(messages, "process-cross-tool", "process cross ok");
    try expectToolResultContains(messages, "builtin.truncateHead", "\"content\":\"alpha\\nbravo\"");
    try expectToolResultContains(messages, "native.cross.echo", "\"runtime\":\"native\"");
    try expectToolResultContains(messages, "workflow.cross-chain", "mixed workflow complete");

    var cancel_signal = std.atomic.Value(bool).init(true);
    var empty_input = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer empty_input.deinit();
    const cancelled = try cancel_tool.execute.?(allocator, "cross-cancel-call", empty_input.value, cancel_tool.execute_context, &cancel_signal, null, null);
    defer tools_common.deinitContentBlocks(allocator, cancelled.content);
    defer if (cancelled.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), cancelled.is_error);
    try std.testing.expectEqualStrings("cancelled", cancelled.details.?.object.get("state").?.string);
    try std.testing.expectEqualStrings("active", cancelled.details.?.object.get("workflow").?.object.get("cancellationPoint").?.string);

    const process_capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, process_capture_path, allocator, .unlimited);
    defer allocator.free(process_capture);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "\"type\":\"initialize\",\"marker\":\"cross-runtime-process\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "\"type\":\"extension_event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "process-cross-tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "builtin.truncateHead") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "native.cross.echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "workflow.cross-chain") != null);

    const loaded_process_snapshot = try process_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(loaded_process_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, loaded_process_snapshot, "\"name\":\"process-cross-tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, loaded_process_snapshot, "\"id\":\"cross-chain\"") != null);
    const loaded_wasm_snapshot = try wasm_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(loaded_wasm_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, loaded_wasm_snapshot, "\"name\":\"builtin.truncateHead\"") != null);
    const loaded_native_snapshot = try native_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(loaded_native_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, loaded_native_snapshot, "\"name\":\"native.cross.echo\"") != null);

    try process_adapter.shutdown();
    try wasm_adapter.shutdown();
    try native_adapter.shutdown();
    try std.testing.expect(process_adapter.hasShutdownComplete());
    try std.testing.expect(wasm_adapter.hasShutdownComplete());
    try std.testing.expect(native_adapter.hasShutdownComplete());
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try process_adapter.agentTool(allocator, "process-cross-tool"));
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try wasm_adapter.agentTool(allocator, "builtin.truncateHead"));
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try native_adapter.agentTool(allocator, "native.cross.echo"));

    var stale_process_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"stale\"}", .{});
    defer stale_process_params.deinit();
    const stale_process = try process_tool.execute.?(allocator, "stale-process-call", stale_process_params.value, process_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, stale_process.content);
    defer if (stale_process.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), stale_process.is_error);
    try std.testing.expectEqualStrings("ToolNotRegistered", stale_process.details.?.object.get("code").?.string);

    var stale_wasm_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"content\":\"alpha\",\"maxLines\":1,\"maxBytes\":1024}", .{});
    defer stale_wasm_params.deinit();
    try std.testing.expectError(error.WasmToolNotRegistered, wasm_tool.execute.?(allocator, "stale-wasm-call", stale_wasm_params.value, wasm_tool.execute_context, null, null, null));

    var stale_native_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"stale\"}", .{});
    defer stale_native_params.deinit();
    try std.testing.expectError(error.NativeToolNotRegistered, native_tool.execute.?(allocator, "stale-native-call", stale_native_params.value, native_tool.execute_context, null, null, null));

    const shutdown_process_snapshot = try process_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(shutdown_process_snapshot);
    const shutdown_wasm_snapshot = try wasm_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(shutdown_wasm_snapshot);
    const shutdown_native_snapshot = try native_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(shutdown_native_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, shutdown_process_snapshot, "\"tools\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, shutdown_wasm_snapshot, "\"tools\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, shutdown_native_snapshot, "\"tools\":[]") != null);
}

test "extension event hooks mutate input before start and context during session prompt" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("reply")}, .{}) },
    });

    var fixture = TestHookHost{
        .input = true,
        .before_agent_start = true,
        .context = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("original");

    try std.testing.expectEqual(@as(usize, 1), fixture.input_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.before_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.context_calls);
    try std.testing.expectEqualStrings("system", session.agent.getSystemPrompt());
    try std.testing.expectEqualStrings("hooked before", session.agent.getMessages()[0].user.content[0].text.text);
}

test "extension input hook handled result records visible diagnostic and skips provider turn" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("must not run")}, .{}) },
    });

    var fixture = TestHookHost{
        .input = true,
        .input_handled = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/input-hook-denial",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("denied");

    try std.testing.expectEqual(@as(usize, 1), fixture.input_calls);
    const messages = session.agent.getMessages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expect(messages[0] == .assistant);
    try std.testing.expectEqual(ai.StopReason.error_reason, messages[0].assistant.stop_reason);
    try std.testing.expect(std.mem.indexOf(u8, messages[0].assistant.error_message.?, "extensionId=process_jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages[0].assistant.error_message.?, "hook=input") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages[0].assistant.error_message.?, "reason=input denied by fixture") != null);
}

test "extension before_agent_start denial records visible diagnostic and skips provider turn" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("must not run")}, .{}) },
    });

    var fixture = TestHookHost{
        .before_agent_start = true,
        .before_agent_start_handled = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/before-hook-denial",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("denied before");

    try std.testing.expectEqual(@as(usize, 1), fixture.before_calls);
    const messages = session.agent.getMessages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expect(messages[0] == .assistant);
    try std.testing.expectEqual(ai.StopReason.error_reason, messages[0].assistant.stop_reason);
    try std.testing.expect(std.mem.indexOf(u8, messages[0].assistant.error_message.?, "extensionId=process_jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages[0].assistant.error_message.?, "hook=before_agent_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages[0].assistant.error_message.?, "reason=startup denied by fixture") != null);
}

test "extension context hook records invalid contribution diagnostic and preserves base context" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("base-only reply")}, .{}) },
    });

    var fixture = TestHookHost{
        .context = true,
        .context_invalid = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/invalid-context-hook",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("base prompt");

    try std.testing.expectEqual(@as(usize, 1), fixture.context_calls);
    const messages = session.agent.getMessages();
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqualStrings("base prompt", messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("base-only reply", messages[1].assistant.content[0].text.text);
    try std.testing.expect(messages[2] == .assistant);
    try std.testing.expectEqual(ai.StopReason.error_reason, messages[2].assistant.stop_reason);
    const diagnostic = messages[2].assistant.error_message.?;
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "Invalid extension context hook contribution") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "extensionId=process_jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "hook=context") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "path=$.messages[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "missing string content or text field") != null);
}

test "extension tool hooks mutate arguments and patch results" {
    var fixture = TestHookHost{
        .tool_call = true,
        .tool_result = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    const hook_context = ExtensionHookContext{
        .allocator = std.testing.allocator,
        .hosts = adapters[0..],
        .timeout_ms = 1000,
    };
    var args = try makeObject(std.testing.allocator);
    defer tools_common.deinitJsonValue(std.testing.allocator, args);
    try putString(std.testing.allocator, &args.object, "value", "original");
    const tool_call = ai.ToolCall{
        .id = "tool-1",
        .name = "fixture-tool",
        .arguments = .null,
    };
    const agent_context = agent.AgentContext{
        .system_prompt = "system",
        .messages = &.{},
        .tools = &.{},
        .extension_hook_context = @constCast(&hook_context),
    };
    _ = try session_mod.testing.callBeforeToolCallHook(std.testing.allocator, .{
        .assistant_message = .{
            .content = &.{},
            .api = "faux",
            .provider = "faux",
            .model = "faux-1",
            .usage = ai.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 1,
        },
        .tool_call = tool_call,
        .args = &args,
        .context = agent_context,
    }, null);
    try std.testing.expectEqual(@as(usize, 1), fixture.tool_call_calls);
    try std.testing.expectEqualStrings("mutated", args.object.get("value").?.string);

    const raw_content = try tools_common.makeTextContent(std.testing.allocator, "raw result");
    defer {
        std.testing.allocator.free(raw_content[0].text.text);
        std.testing.allocator.free(raw_content);
    }
    const patch = (try session_mod.testing.callAfterToolCallHook(std.testing.allocator, .{
        .assistant_message = .{
            .content = &.{},
            .api = "faux",
            .provider = "faux",
            .model = "faux-1",
            .usage = ai.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 1,
        },
        .tool_call = tool_call,
        .args = args,
        .result = .{ .content = raw_content },
        .is_error = false,
        .context = agent_context,
    }, null)).?;
    defer if (patch.content) |content| {
        std.testing.allocator.free(content[0].text.text);
        std.testing.allocator.free(content);
    };
    try std.testing.expectEqual(@as(usize, 1), fixture.tool_result_calls);
    try std.testing.expectEqualStrings("patched result", patch.content.?[0].text.text);
    try std.testing.expectEqual(false, patch.is_error.?);
}

test "extension lifecycle hooks fire once per turn and message in agent order" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("lifecycle reply")}, .{}) },
    });

    var order_log = std.ArrayList([]const u8).empty;
    defer order_log.deinit(std.testing.allocator);
    var fixture = TestHookHost{
        .turn_start = true,
        .message_end = true,
        .turn_end = true,
        .order_log = &order_log,
        .order_allocator = std.testing.allocator,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/lifecycle-hooks",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("hello lifecycle");

    try std.testing.expectEqual(@as(usize, 1), fixture.turn_start_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.message_end_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.turn_end_calls);
    try std.testing.expect(order_log.items.len >= 4);
    try std.testing.expectEqualStrings("turn_start", order_log.items[0]);
    try std.testing.expectEqualStrings("message_end", order_log.items[1]);
    try std.testing.expectEqualStrings("message_end", order_log.items[2]);
    try std.testing.expectEqualStrings("turn_end", order_log.items[3]);
}

test "Stage A: agent_start / agent_end / message_start / message_update events fire from agent loop" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("hello there")}, .{}) },
    });

    var fixture = TestHookHost{
        .agent_start = true,
        .agent_end = true,
        .message_start = true,
        .message_update = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/stage-a-events",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("trigger Stage A events");

    // agent_start fires exactly once at loop entry.
    try std.testing.expectEqual(@as(usize, 1), fixture.agent_start_calls);
    // agent_end fires exactly once at loop exit (any of the three exit paths).
    try std.testing.expectEqual(@as(usize, 1), fixture.agent_end_calls);
    // message_start fires for both the user message and the assistant message.
    try std.testing.expect(fixture.message_start_calls >= 1);
    // message_update fires at least once during assistant streaming.
    try std.testing.expect(fixture.message_update_calls >= 1);
}

test "Stage G: resources_discover fires on session creation" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    var fixture = TestHookHost{
        .resources_discover = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/stage-g-resources",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, 1), fixture.resources_discover_calls);
}

test "Stage J: before_provider_request / after_provider_response fire around stream boundary" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("response body")}, .{}) },
    });

    var fixture = TestHookHost{
        .before_provider_request = true,
        .after_provider_response = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/stage-j-provider",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("trigger one provider request");

    // Each turn issues exactly one provider request: before fires once, after fires once.
    try std.testing.expectEqual(@as(usize, 1), fixture.before_provider_request_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.after_provider_response_calls);
}

test "Stage H: session_before_compact cancellation short-circuits compact()" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    var fixture = TestHookHost{
        .session_before_compact = true,
        .cancel_session_before = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/stage-h-compact",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try std.testing.expectError(error.SessionBeforeCompactCancelled, session.compact(null));
    try std.testing.expectEqual(@as(usize, 1), fixture.session_before_compact_calls);
}

test "Stage G: emitUserBashEvent forwards user_bash to extension hooks" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    var fixture = TestHookHost{
        .user_bash = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/stage-g-bash",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.emitUserBashEvent("ls -la", false);
    try session.emitUserBashEvent("rm -rf /tmp/x", true);
    try std.testing.expectEqual(@as(usize, 2), fixture.user_bash_calls);
}

test "Stage F: session_start fires on AgentSession.create and session_shutdown on deinit" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    var fixture = TestHookHost{
        .session_start = true,
        .session_shutdown = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/stage-f-events",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    // session_start fires once during create.
    try std.testing.expectEqual(@as(usize, 1), fixture.session_start_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.session_shutdown_calls);

    session.deinit();
    // session_shutdown fires during deinit (before the hook context tears down).
    try std.testing.expectEqual(@as(usize, 1), fixture.session_shutdown_calls);
}

test "Stage C: model_select / thinking_level_select fire from session setters" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    var fixture = TestHookHost{
        .model_select = true,
        .thinking_level_select = true,
        .expected_model_select_model_id = "faux-2",
        .expected_model_select_previous_id = registration.getModel().id,
        .expected_model_select_source = "set",
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/stage-c-events",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    // Switch the model to a fresh registration to trigger model_select.
    const second_registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .models = &.{.{ .id = "faux-2", .name = "Faux 2" }},
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer second_registration.unregister();
    try session.setModel(second_registration.getModel());
    try std.testing.expectEqual(@as(usize, 1), fixture.model_select_calls);
    try std.testing.expect(fixture.model_select_payload_matched);

    // Change the thinking level to trigger thinking_level_select.
    try session.setThinkingLevel(.medium);
    try std.testing.expectEqual(@as(usize, 1), fixture.thinking_level_select_calls);
}

test "Session.setModel does not leak model select JSON when hook is absent" {
    const first_model = ai.Model{
        .id = "first-model",
        .name = "First Model",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };
    const second_model = ai.Model{
        .id = "second-model",
        .name = "Second Model",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };
    var fixture = TestHookHost{};
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/model-select-no-hook",
        .system_prompt = "system",
        .model = first_model,
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.setModel(second_model);
    try std.testing.expectEqual(@as(usize, 0), fixture.model_select_calls);
}

test "Stage B: tool_execution_start / update / end events forward to extension hooks" {
    const allocator = std.testing.allocator;
    var fixture = TestHookHost{
        .tool_execution_start = true,
        .tool_execution_update = true,
        .tool_execution_end = true,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{fixture.adapter()};
    var hook_context = ExtensionHookContext{
        .allocator = allocator,
        .hosts = adapters[0..],
        .timeout_ms = 1000,
    };

    // Build a synthetic args JSON value to thread through events.
    var args = try makeObject(allocator);
    defer tools_common.deinitJsonValue(allocator, args);
    try putString(allocator, &args.object, "value", "exec-input");

    // tool_execution_start
    try session_mod.testing.invokeLifecycle(&hook_context, allocator, .{
        .event_type = .tool_execution_start,
        .tool_call_id = "exec-1",
        .tool_name = "demo-tool",
        .args = args,
    });
    try std.testing.expectEqual(@as(usize, 1), fixture.tool_execution_start_calls);

    // tool_execution_update with a partial result
    const partial_blocks = try tools_common.makeTextContent(allocator, "partial output");
    defer tools_common.deinitContentBlocks(allocator, partial_blocks);
    try session_mod.testing.invokeLifecycle(&hook_context, allocator, .{
        .event_type = .tool_execution_update,
        .tool_call_id = "exec-1",
        .tool_name = "demo-tool",
        .args = args,
        .partial_result = .{ .content = partial_blocks },
    });
    try std.testing.expectEqual(@as(usize, 1), fixture.tool_execution_update_calls);

    // tool_execution_end with final result + isError
    const final_blocks = try tools_common.makeTextContent(allocator, "final output");
    defer tools_common.deinitContentBlocks(allocator, final_blocks);
    try session_mod.testing.invokeLifecycle(&hook_context, allocator, .{
        .event_type = .tool_execution_end,
        .tool_call_id = "exec-1",
        .tool_name = "demo-tool",
        .args = args,
        .result = .{ .content = final_blocks },
        .is_error = false,
    });
    try std.testing.expectEqual(@as(usize, 1), fixture.tool_execution_end_calls);
}

test "extension lifecycle hooks run deterministically by host order" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(&[_]faux.FauxContentBlock{faux.fauxText("ordered reply")}, .{}) },
    });

    var order_log = std.ArrayList([]const u8).empty;
    defer order_log.deinit(std.testing.allocator);
    var first = TestHookHost{
        .turn_start = true,
        .label = "first",
        .order_log = &order_log,
        .order_allocator = std.testing.allocator,
    };
    var second = TestHookHost{
        .turn_start = true,
        .label = "second",
        .order_log = &order_log,
        .order_allocator = std.testing.allocator,
    };
    const adapters = [_]extension_runtime.RuntimeAdapter{ first.adapter(), second.adapter() };
    var session = try AgentSession.create(std.testing.allocator, std.testing.io, .{
        .cwd = "/tmp/lifecycle-hook-order",
        .system_prompt = "system",
        .model = registration.getModel(),
        .extension_hosts = adapters[0..],
    });
    defer session.deinit();

    try session.prompt("hello ordering");

    try std.testing.expect(order_log.items.len >= 2);
    try std.testing.expectEqualStrings("first", order_log.items[0]);
    try std.testing.expectEqualStrings("second", order_log.items[1]);
    try std.testing.expectEqual(@as(usize, 1), first.turn_start_calls);
    try std.testing.expectEqual(@as(usize, 1), second.turn_start_calls);
}
