const std = @import("std");
const ai = @import("ai");

const types = ai.types;
const openai = ai.providers.openai;

const fixture_dir = "test/golden/openai-chat";
const max_diff_output_bytes: usize = 12_000;
const max_value_bytes: usize = 512;
const max_diffs: usize = 20;

const ignored_field_allowlist = [_][]const u8{
    "id",
    "title",
    "input",
    "metadata",
    "schemaVersion",
    "expected.onPayload",
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    try runBoundedDiffSelfTest(allocator);
    try runIgnoredAllowlistSelfTest(allocator);

    const manifest = try readJsonFile(allocator, io, fixture_dir ++ "/manifest.json");
    defer manifest.deinit();

    const scenario_ids = getObjectField(manifest.value, "scenarioIds").array.items;
    var failures: usize = 0;
    var ignored_paths = IgnoredPathTracker{};

    for (scenario_ids) |scenario_id_value| {
        const scenario_id = scenario_id_value.string;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ fixture_dir, scenario_id });
        defer allocator.free(path);

        const fixture = try readJsonFile(allocator, io, path);
        defer fixture.deinit();

        const actual_fixture = try buildActualFixtureComparisonRoot(allocator, fixture.value);
        defer openai.freeOwnedJsonValue(allocator, actual_fixture);

        var diffs = DiffCollector.init(allocator);
        defer diffs.deinit();

        try compareJson(&diffs, &ignored_paths, scenario_id, "", fixture.value, actual_fixture);
        if (diffs.count == 0) {
            std.debug.print("  matched {s}\n", .{scenario_id});
        } else {
            failures += 1;
            std.debug.print("{s}", .{diffs.buffer.items});
            if (diffs.truncated) {
                std.debug.print("scenario {s}: diff output truncated at {d} bytes\n", .{ scenario_id, max_diff_output_bytes });
            }
        }
    }

    if (failures > 0) {
        std.debug.print("OpenAI Chat parity failed for {d} scenario(s); diff bound={d} bytes\n", .{ failures, max_diff_output_bytes });
        std.process.exit(1);
    }

    const ignored_summary = try ignored_paths.summary(allocator);
    defer allocator.free(ignored_summary);
    const allowlist_summary = try ignoredAllowlistSummary(allocator);
    defer allocator.free(allowlist_summary);

    std.debug.print(
        "OpenAI Chat parity matched {d} scenarios; ignored paths: {s}; ignored allowlist: {s}\n",
        .{ scenario_ids.len, ignored_summary, allowlist_summary },
    );
}

fn ignoredAllowlistSummary(allocator: std.mem.Allocator) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    for (ignored_field_allowlist, 0..) |path, index| {
        if (index > 0) try buffer.appendSlice(allocator, ", ");
        try buffer.appendSlice(allocator, path);
    }
    return try buffer.toOwnedSlice(allocator);
}

fn readJsonFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.Parsed(std.json.Value) {
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(1_000_000));
    defer allocator.free(bytes);
    return try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

fn buildActualRequestFromFixture(allocator: std.mem.Allocator, fixture: std.json.Value) !std.json.Value {
    if (getObjectField(fixture, "schemaVersion").integer != 1) return error.UnsupportedFixtureSchemaVersion;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scenario_allocator = arena.allocator();

    const input = getObjectField(fixture, "input");
    const model = try parseModel(scenario_allocator, getObjectField(input, "model"));
    const context = try parseContext(scenario_allocator, getObjectField(input, "context"));
    const options_value = getObjectField(input, "options");
    const options = try parseOptions(scenario_allocator, options_value);
    const cache_retention_env = fixtureCacheRetentionEnv(options_value);

    return try openai.buildRequestSnapshotValueWithCacheRetentionEnv(allocator, model, context, options, cache_retention_env);
}

fn buildActualCompatFromFixture(allocator: std.mem.Allocator, fixture: std.json.Value) !std.json.Value {
    if (getObjectField(fixture, "schemaVersion").integer != 1) return error.UnsupportedFixtureSchemaVersion;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scenario_allocator = arena.allocator();

    const input = getObjectField(fixture, "input");
    const model = try parseModel(scenario_allocator, getObjectField(input, "model"));
    return try openai.buildResolvedCompatSnapshotValue(allocator, model);
}

fn buildActualFixtureComparisonRoot(allocator: std.mem.Allocator, fixture: std.json.Value) !std.json.Value {
    const actual_request = try buildActualRequestFromFixture(allocator, fixture);
    errdefer openai.freeOwnedJsonValue(allocator, actual_request);
    const actual_compat = try buildActualCompatFromFixture(allocator, fixture);
    errdefer openai.freeOwnedJsonValue(allocator, actual_compat);

    var expected = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer expected.deinit(allocator);
    try expected.put(
        allocator,
        try allocator.dupe(u8, "resolvedCompat"),
        actual_compat,
    );
    try expected.put(
        allocator,
        try allocator.dupe(u8, "typeScriptRequest"),
        actual_request,
    );

    // If the fixture has input.mockChunks, parse the SSE and compare streamOutput
    const input = getObjectField(fixture, "input");
    if (input.object.get("mockChunks")) |mock_chunks| {
        if (mock_chunks == .array and mock_chunks.array.items.len > 0) {
            const sse_bytes = try mockChunksToSse(allocator, mock_chunks);
            defer allocator.free(sse_bytes);

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const scenario_allocator = arena.allocator();

            const model = try parseModel(scenario_allocator, getObjectField(input, "model"));

            const message = openai.parseSseAssistantMessageFromSlice(scenario_allocator, std.Io.failing, sse_bytes, model) catch |err| {
                std.debug.print("stream parse error: {s}\n", .{@errorName(err)});
                return err;
            };

            const stream_output = try assistantMessageToStreamOutputValue(allocator, message);
            try expected.put(
                allocator,
                try allocator.dupe(u8, "streamOutput"),
                stream_output,
            );
        }
    }

    var root = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer root.deinit(allocator);
    try root.put(allocator, try allocator.dupe(u8, "expected"), .{ .object = expected });

    return .{ .object = root };
}

fn stopReasonToString(reason: types.StopReason) []const u8 {
    return switch (reason) {
        .stop => "stop",
        .length => "length",
        .tool_use => "toolUse",
        .error_reason => "error",
        .aborted => "aborted",
    };
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .number_string => |ns| .{ .number_string = try allocator.dupe(u8, ns) },
        .array => |arr| {
            var new_arr = std.json.Array.init(allocator);
            errdefer new_arr.deinit();
            for (arr.items) |item| {
                try new_arr.append(try cloneJsonValue(allocator, item));
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            errdefer new_obj.deinit(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key_copy);
                try new_obj.put(allocator, key_copy, try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            return .{ .object = new_obj };
        },
    };
}

fn deinitJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .number_string => |ns| allocator.free(ns),
        .array => |arr| {
            for (arr.items) |item| deinitJsonValue(allocator, item);
            var arr_mut = arr;
            arr_mut.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValue(allocator, entry.value_ptr.*);
            }
            var obj_mut = obj;
            obj_mut.deinit(allocator);
        },
        else => {},
    }
}

fn mockChunksToSse(allocator: std.mem.Allocator, chunks: std.json.Value) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    for (chunks.array.items) |chunk| {
        try buffer.appendSlice(allocator, "data: ");
        const chunk_str = try std.json.Stringify.valueAlloc(allocator, chunk, .{});
        defer allocator.free(chunk_str);
        try buffer.appendSlice(allocator, chunk_str);
        try buffer.appendSlice(allocator, "\n\n");
    }
    try buffer.appendSlice(allocator, "data: [DONE]\n\n");

    return try buffer.toOwnedSlice(allocator);
}

fn assistantMessageToStreamOutputValue(allocator: std.mem.Allocator, message: types.AssistantMessage) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);

    try object.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, message.model) });
    if (message.response_model) |response_model| {
        try object.put(allocator, try allocator.dupe(u8, "responseModel"), .{ .string = try allocator.dupe(u8, response_model) });
    }
    try object.put(allocator, try allocator.dupe(u8, "stopReason"), .{ .string = try allocator.dupe(u8, stopReasonToString(message.stop_reason)) });
    try object.put(allocator, try allocator.dupe(u8, "api"), .{ .string = try allocator.dupe(u8, message.api) });
    try object.put(allocator, try allocator.dupe(u8, "provider"), .{ .string = try allocator.dupe(u8, message.provider) });

    // Usage
    var usage_object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try usage_object.put(allocator, try allocator.dupe(u8, "input"), .{ .integer = @intCast(message.usage.input) });
    try usage_object.put(allocator, try allocator.dupe(u8, "output"), .{ .integer = @intCast(message.usage.output) });
    try usage_object.put(allocator, try allocator.dupe(u8, "cacheRead"), .{ .integer = @intCast(message.usage.cache_read) });
    try usage_object.put(allocator, try allocator.dupe(u8, "cacheWrite"), .{ .integer = @intCast(message.usage.cache_write) });
    try usage_object.put(allocator, try allocator.dupe(u8, "totalTokens"), .{ .integer = @intCast(message.usage.total_tokens) });
    try object.put(allocator, try allocator.dupe(u8, "usage"), .{ .object = usage_object });

    // Content
    var content_array = std.json.Array.init(allocator);
    for (message.content) |block| {
        var block_object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        switch (block) {
            .text => |text| {
                try block_object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "text") });
                try block_object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text.text) });
            },
            .thinking => |thinking| {
                try block_object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "thinking") });
                try block_object.put(allocator, try allocator.dupe(u8, "thinking"), .{ .string = try allocator.dupe(u8, thinking.thinking) });
                try block_object.put(allocator, try allocator.dupe(u8, "redacted"), .{ .bool = thinking.redacted });
            },
            .tool_call => |tool_call| {
                try block_object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "toolCall") });
                try block_object.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, tool_call.id) });
                try block_object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool_call.name) });
                try block_object.put(allocator, try allocator.dupe(u8, "arguments"), try cloneJsonValue(allocator, tool_call.arguments));
            },
            .image => |image| {
                try block_object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "image") });
                try block_object.put(allocator, try allocator.dupe(u8, "data"), .{ .string = try allocator.dupe(u8, image.data) });
                try block_object.put(allocator, try allocator.dupe(u8, "mimeType"), .{ .string = try allocator.dupe(u8, image.mime_type) });
            },
        }
        try content_array.append(.{ .object = block_object });
    }
    try object.put(allocator, try allocator.dupe(u8, "content"), .{ .array = content_array });

    return .{ .object = object };
}

fn parseModel(allocator: std.mem.Allocator, value: std.json.Value) !types.Model {
    const input_value = getObjectField(value, "input");
    const input_types = try allocator.alloc([]const u8, input_value.array.items.len);
    for (input_value.array.items, 0..) |item, index| {
        input_types[index] = item.string;
    }

    return .{
        .id = getObjectField(value, "id").string,
        .name = getObjectField(value, "name").string,
        .api = getObjectField(value, "api").string,
        .provider = getObjectField(value, "provider").string,
        .base_url = getObjectField(value, "baseUrl").string,
        .reasoning = optionalBool(value, "reasoning") orelse false,
        .input_types = input_types,
        .context_window = 128_000,
        .max_tokens = 4096,
        .headers = try parseStringMapOptional(allocator, optionalField(value, "headers")),
        .compat = optionalField(value, "compat"),
    };
}

fn parseContext(allocator: std.mem.Allocator, value: std.json.Value) !types.Context {
    const messages_value = getObjectField(value, "messages");
    const messages = try allocator.alloc(types.Message, messages_value.array.items.len);
    for (messages_value.array.items, 0..) |item, index| {
        messages[index] = try parseMessage(allocator, item);
    }

    return .{
        .system_prompt = optionalString(value, "systemPrompt"),
        .messages = messages,
        .tools = try parseToolsOptional(allocator, optionalField(value, "tools")),
    };
}

fn parseMessage(allocator: std.mem.Allocator, value: std.json.Value) !types.Message {
    const role = getObjectField(value, "role").string;
    if (std.mem.eql(u8, role, "user")) {
        return .{ .user = .{
            .content = try parseContentBlocks(allocator, getObjectField(value, "content")),
            .timestamp = 0,
        } };
    }
    if (std.mem.eql(u8, role, "assistant")) {
        return .{ .assistant = .{
            .content = try parseContentBlocks(allocator, getObjectField(value, "content")),
            .api = optionalString(value, "api") orelse "openai-completions",
            .provider = optionalString(value, "provider") orelse "openai",
            .model = optionalString(value, "model") orelse "fixture-model",
            .usage = parseUsage(optionalField(value, "usage")),
            .stop_reason = parseStopReason(optionalString(value, "stopReason")),
            .timestamp = 0,
        } };
    }
    if (std.mem.eql(u8, role, "toolResult")) {
        return .{ .tool_result = .{
            .tool_call_id = getObjectField(value, "toolCallId").string,
            .tool_name = optionalString(value, "toolName") orelse "",
            .content = try parseContentBlocks(allocator, getObjectField(value, "content")),
            .is_error = optionalBool(value, "isError") orelse false,
            .timestamp = 0,
        } };
    }
    return error.UnsupportedFixtureMessageRole;
}

fn parseContentBlocks(allocator: std.mem.Allocator, value: std.json.Value) ![]const types.ContentBlock {
    if (value == .string) {
        const blocks = try allocator.alloc(types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = value.string } };
        return blocks;
    }

    const items = value.array.items;
    const blocks = try allocator.alloc(types.ContentBlock, items.len);
    for (items, 0..) |item, index| {
        const item_type = getObjectField(item, "type").string;
        if (std.mem.eql(u8, item_type, "text")) {
            blocks[index] = .{ .text = .{ .text = getObjectField(item, "text").string } };
        } else if (std.mem.eql(u8, item_type, "image")) {
            blocks[index] = .{ .image = .{
                .data = getObjectField(item, "data").string,
                .mime_type = getObjectField(item, "mimeType").string,
            } };
        } else if (std.mem.eql(u8, item_type, "toolCall")) {
            blocks[index] = .{ .tool_call = .{
                .id = getObjectField(item, "id").string,
                .name = getObjectField(item, "name").string,
                .arguments = getObjectField(item, "arguments"),
            } };
        } else if (std.mem.eql(u8, item_type, "thinking")) {
            blocks[index] = .{ .thinking = .{
                .thinking = getObjectField(item, "thinking").string,
                .thinking_signature = optionalString(item, "thinkingSignature"),
            } };
        } else {
            return error.UnsupportedFixtureContentBlock;
        }
    }
    return blocks;
}

fn parseToolsOptional(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const types.Tool {
    const tools_value = value orelse return null;
    const tools = try allocator.alloc(types.Tool, tools_value.array.items.len);
    for (tools_value.array.items, 0..) |item, index| {
        tools[index] = .{
            .name = getObjectField(item, "name").string,
            .description = getObjectField(item, "description").string,
            .parameters = getObjectField(item, "parameters"),
        };
    }
    return tools;
}

fn parseOptions(allocator: std.mem.Allocator, value: std.json.Value) !types.StreamOptions {
    var options = types.StreamOptions{
        .api_key = "fixture-api-key-redacted",
        .cache_retention = parseCacheRetention(optionalString(value, "cacheRetention")),
        .headers = try parseStringMapOptional(allocator, optionalField(value, "headers")),
        .max_retries = optionalU32(value, "maxRetries"),
        .max_tokens = optionalU32(value, "maxTokens"),
        .openai_reasoning_effort = optionalString(value, "reasoningEffort"),
        .openai_tool_choice = optionalField(value, "toolChoice"),
        .session_id = optionalString(value, "sessionId"),
        .temperature = optionalF32(value, "temperature"),
        .timeout_ms = optionalU32(value, "timeoutMs"),
    };

    if (optionalString(value, "onPayload")) |mode| {
        if (std.mem.eql(u8, mode, "replace-with-fixture-payload")) {
            options.on_payload = fixturePayloadReplacement;
        } else if (!std.mem.eql(u8, mode, "pass-through")) {
            return error.UnsupportedFixtureOnPayloadMode;
        }
    }

    return options;
}

fn fixturePayloadReplacement(allocator: std.mem.Allocator, payload: std.json.Value, model: types.Model) !?std.json.Value {
    _ = payload;
    _ = model;

    var root = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer root.deinit(allocator);
    try root.put(allocator, try allocator.dupe(u8, "fixture_marker"), .{ .string = try allocator.dupe(u8, "on-payload-replacement") });

    var messages = std.json.Array.init(allocator);
    errdefer messages.deinit();
    var message = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer message.deinit(allocator);
    try message.put(allocator, try allocator.dupe(u8, "content"), .{ .string = try allocator.dupe(u8, "payload replaced by deterministic fixture callback") });
    try message.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "user") });
    try messages.append(.{ .object = message });

    try root.put(allocator, try allocator.dupe(u8, "messages"), .{ .array = messages });
    try root.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, "fixture-replacement-model") });
    try root.put(allocator, try allocator.dupe(u8, "stream"), .{ .bool = true });
    return .{ .object = root };
}

fn parseStringMapOptional(allocator: std.mem.Allocator, value: ?std.json.Value) !?std.StringHashMap([]const u8) {
    const object_value = value orelse return null;
    var map = std.StringHashMap([]const u8).init(allocator);
    var iterator = object_value.object.iterator();
    while (iterator.next()) |entry| {
        try map.put(entry.key_ptr.*, entry.value_ptr.string);
    }
    return map;
}

fn parseUsage(value: ?std.json.Value) types.Usage {
    const usage_value = value orelse return .{};
    return .{
        .input = optionalObjectU32(usage_value, "input") orelse 0,
        .output = optionalObjectU32(usage_value, "output") orelse 0,
        .cache_read = optionalObjectU32(usage_value, "cacheRead") orelse 0,
        .cache_write = optionalObjectU32(usage_value, "cacheWrite") orelse 0,
        .total_tokens = optionalObjectU32(usage_value, "totalTokens") orelse 0,
    };
}

fn parseStopReason(value: ?[]const u8) types.StopReason {
    const reason = value orelse return .stop;
    if (std.mem.eql(u8, reason, "toolUse")) return .tool_use;
    if (std.mem.eql(u8, reason, "length")) return .length;
    if (std.mem.eql(u8, reason, "error")) return .error_reason;
    if (std.mem.eql(u8, reason, "aborted")) return .aborted;
    return .stop;
}

fn parseCacheRetention(value: ?[]const u8) types.CacheRetention {
    const retention = value orelse return .unset;
    if (std.mem.eql(u8, retention, "none")) return .none;
    if (std.mem.eql(u8, retention, "short")) return .short;
    if (std.mem.eql(u8, retention, "long")) return .long;
    if (std.mem.eql(u8, retention, "env-long")) return .unset;
    return .unset;
}

fn fixtureCacheRetentionEnv(options: std.json.Value) ?[]const u8 {
    const retention = optionalString(options, "cacheRetention") orelse return null;
    if (std.mem.eql(u8, retention, "env-long")) return "long";
    return null;
}

fn getObjectField(value: std.json.Value, key: []const u8) std.json.Value {
    return value.object.get(key) orelse @panic("fixture missing required field");
}

fn optionalField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn optionalString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = optionalField(value, key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn optionalBool(value: std.json.Value, key: []const u8) ?bool {
    const field = optionalField(value, key) orelse return null;
    if (field != .bool) return null;
    return field.bool;
}

fn optionalU32(value: std.json.Value, key: []const u8) ?u32 {
    const field = optionalField(value, key) orelse return null;
    if (field != .integer) return null;
    return @intCast(field.integer);
}

fn optionalObjectU32(value: std.json.Value, key: []const u8) ?u32 {
    return optionalU32(value, key);
}

fn optionalF32(value: std.json.Value, key: []const u8) ?f32 {
    const field = optionalField(value, key) orelse return null;
    return switch (field) {
        .integer => @floatFromInt(field.integer),
        .float => @floatCast(field.float),
        else => null,
    };
}

const DiffCollector = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    count: usize = 0,
    truncated: bool = false,

    fn init(allocator: std.mem.Allocator) DiffCollector {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).empty,
        };
    }

    fn deinit(self: *DiffCollector) void {
        self.buffer.deinit(self.allocator);
    }

    fn add(self: *DiffCollector, scenario_id: []const u8, path: []const u8, expected: std.json.Value, actual: std.json.Value) !void {
        self.count += 1;
        if (self.count > max_diffs or self.buffer.items.len >= max_diff_output_bytes) {
            self.truncated = true;
            return;
        }

        const expected_rendered = try renderBoundedJson(self.allocator, expected);
        defer self.allocator.free(expected_rendered);
        const actual_rendered = try renderBoundedJson(self.allocator, actual);
        defer self.allocator.free(actual_rendered);

        const header = try std.fmt.allocPrint(
            self.allocator,
            "scenario {s}: path {s}\n  expected: ",
            .{ scenario_id, path },
        );
        defer self.allocator.free(header);
        try self.appendBounded(header);
        try self.appendBounded(expected_rendered);
        try self.appendBounded("\n  actual: ");
        try self.appendBounded(actual_rendered);
        try self.appendBounded("\n");
    }

    fn appendBounded(self: *DiffCollector, text: []const u8) !void {
        if (self.buffer.items.len >= max_diff_output_bytes) {
            self.truncated = true;
            return;
        }
        const remaining = max_diff_output_bytes - self.buffer.items.len;
        const take = @min(remaining, text.len);
        try self.buffer.appendSlice(self.allocator, text[0..take]);
        if (take < text.len) self.truncated = true;
    }
};

const IgnoredPathTracker = struct {
    paths: [ignored_field_allowlist.len]bool = [_]bool{false} ** ignored_field_allowlist.len,

    fn shouldIgnore(self: *IgnoredPathTracker, path: []const u8) bool {
        for (ignored_field_allowlist, 0..) |ignored_path, index| {
            if (std.mem.eql(u8, path, ignored_path)) {
                self.paths[index] = true;
                return true;
            }
        }
        return false;
    }

    fn wasIgnored(self: *const IgnoredPathTracker, path: []const u8) bool {
        for (ignored_field_allowlist, 0..) |ignored_path, index| {
            if (std.mem.eql(u8, path, ignored_path)) return self.paths[index];
        }
        return false;
    }

    fn summary(self: *const IgnoredPathTracker, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).empty;
        errdefer buffer.deinit(allocator);
        var first = true;
        for (ignored_field_allowlist, 0..) |path, index| {
            if (!self.paths[index]) continue;
            if (!first) try buffer.appendSlice(allocator, ", ");
            try buffer.appendSlice(allocator, path);
            first = false;
        }
        if (first) try buffer.appendSlice(allocator, "(none)");
        return try buffer.toOwnedSlice(allocator);
    }
};

fn compareJson(
    diffs: *DiffCollector,
    ignored_paths: *IgnoredPathTracker,
    scenario_id: []const u8,
    path: []const u8,
    expected: std.json.Value,
    actual: std.json.Value,
) !void {
    if (ignored_paths.shouldIgnore(path)) return;

    if (expected == .integer and actual == .float) {
        if (@as(f64, @floatFromInt(expected.integer)) == actual.float) return;
    }
    if (expected == .float and actual == .integer) {
        if (expected.float == @as(f64, @floatFromInt(actual.integer))) return;
    }

    if (std.meta.activeTag(expected) != std.meta.activeTag(actual)) {
        try diffs.add(scenario_id, path, expected, actual);
        return;
    }

    switch (expected) {
        .null => {},
        .bool => |expected_bool| if (expected_bool != actual.bool) try diffs.add(scenario_id, path, expected, actual),
        .integer => |expected_integer| if (expected_integer != actual.integer) try diffs.add(scenario_id, path, expected, actual),
        .float => |expected_float| if (expected_float != actual.float) try diffs.add(scenario_id, path, expected, actual),
        .number_string => |expected_number| if (!std.mem.eql(u8, expected_number, actual.number_string)) try diffs.add(scenario_id, path, expected, actual),
        .string => |expected_string| if (!std.mem.eql(u8, expected_string, actual.string)) try diffs.add(scenario_id, path, expected, actual),
        .array => |expected_array| {
            if (expected_array.items.len != actual.array.items.len) {
                try diffs.add(scenario_id, path, expected, actual);
                return;
            }
            for (expected_array.items, actual.array.items, 0..) |expected_item, actual_item, index| {
                const child_path = try arrayChildPath(diffs.allocator, path, index);
                defer diffs.allocator.free(child_path);
                try compareJson(diffs, ignored_paths, scenario_id, child_path, expected_item, actual_item);
            }
        },
        .object => |expected_object| {
            var expected_iterator = expected_object.iterator();
            while (expected_iterator.next()) |entry| {
                const child_path = try objectChildPath(diffs.allocator, path, entry.key_ptr.*);
                defer diffs.allocator.free(child_path);
                if (ignored_paths.shouldIgnore(child_path)) continue;
                const actual_child = actual.object.get(entry.key_ptr.*) orelse {
                    try diffs.add(scenario_id, child_path, entry.value_ptr.*, .null);
                    continue;
                };
                try compareJson(diffs, ignored_paths, scenario_id, child_path, entry.value_ptr.*, actual_child);
            }

            var actual_iterator = actual.object.iterator();
            while (actual_iterator.next()) |entry| {
                if (expected_object.get(entry.key_ptr.*) == null) {
                    const child_path = try objectChildPath(diffs.allocator, path, entry.key_ptr.*);
                    defer diffs.allocator.free(child_path);
                    if (ignored_paths.shouldIgnore(child_path)) continue;
                    try diffs.add(scenario_id, child_path, .null, entry.value_ptr.*);
                }
            }
        },
    }
}

fn objectChildPath(allocator: std.mem.Allocator, path: []const u8, child: []const u8) ![]const u8 {
    if (path.len == 0) return try allocator.dupe(u8, child);
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, child });
}

fn arrayChildPath(allocator: std.mem.Allocator, path: []const u8, index: usize) ![]const u8 {
    if (path.len == 0) return try std.fmt.allocPrint(allocator, "[{d}]", .{index});
    return try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, index });
}

fn renderBoundedJson(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    const rendered = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(rendered);
    if (rendered.len <= max_value_bytes) return try allocator.dupe(u8, rendered);
    const suffix = "...<truncated>";
    var output = try allocator.alloc(u8, max_value_bytes + suffix.len);
    @memcpy(output[0..max_value_bytes], rendered[0..max_value_bytes]);
    @memcpy(output[max_value_bytes..], suffix);
    return output;
}

fn runBoundedDiffSelfTest(allocator: std.mem.Allocator) !void {
    const long_expected = try allocator.alloc(u8, max_diff_output_bytes * 2);
    defer allocator.free(long_expected);
    @memset(long_expected, 'e');
    const long_actual = try allocator.alloc(u8, max_diff_output_bytes * 2);
    defer allocator.free(long_actual);
    @memset(long_actual, 'a');

    var diffs = DiffCollector.init(allocator);
    defer diffs.deinit();
    try diffs.add("bounded-diff-self-test", "request.jsonPayload.long", .{ .string = long_expected }, .{ .string = long_actual });
    if (diffs.buffer.items.len > max_diff_output_bytes) return error.UnboundedDiffOutput;
}

fn runIgnoredAllowlistSelfTest(allocator: std.mem.Allocator) !void {
    const expected_json =
        \\{
        \\  "id": "allowlisted-id",
        \\  "expected": {
        \\    "resolvedCompat": {},
        \\    "typeScriptRequest": {},
        \\    "futureExpectedField": true
        \\  },
        \\  "futureRootField": true
        \\}
    ;
    const actual_json =
        \\{
        \\  "expected": {
        \\    "resolvedCompat": {},
        \\    "typeScriptRequest": {}
        \\  },
        \\  "actualOnlyField": true
        \\}
    ;

    const expected = try std.json.parseFromSlice(std.json.Value, allocator, expected_json, .{});
    defer expected.deinit();
    const actual = try std.json.parseFromSlice(std.json.Value, allocator, actual_json, .{});
    defer actual.deinit();

    var ignored_paths = IgnoredPathTracker{};
    var diffs = DiffCollector.init(allocator);
    defer diffs.deinit();

    try compareJson(&diffs, &ignored_paths, "ignored-allowlist-self-test", "", expected.value, actual.value);
    if (diffs.count != 3) return error.UnallowlistedFixtureFieldWasNotRejected;
    if (!ignored_paths.wasIgnored("id")) return error.AllowlistedFixtureFieldWasNotIgnored;
    if (std.mem.indexOf(u8, diffs.buffer.items, "expected.futureExpectedField") == null) {
        return error.UnallowlistedFixtureFieldPathNotReported;
    }
    if (std.mem.indexOf(u8, diffs.buffer.items, "futureRootField") == null) {
        return error.UnallowlistedFixtureFieldPathNotReported;
    }
    if (std.mem.indexOf(u8, diffs.buffer.items, "actualOnlyField") == null) {
        return error.UnallowlistedFixtureFieldPathNotReported;
    }
}
