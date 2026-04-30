const std = @import("std");
const ai = @import("ai");

const types = ai.types;
const openai_responses = ai.providers.openai_responses;
const azure_openai_responses = ai.providers.azure_openai_responses;
const openai_codex_responses = ai.providers.openai_codex_responses;

const fixture_dir = "test/golden/openai-responses";
const fixture_codex_jwt = "eyJhbGciOiJub25lIn0.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiZml4dHVyZS1hY2NvdW50In19.c2lnbmF0dXJl";
const max_diff_output_bytes: usize = 12_000;
const max_value_bytes: usize = 512;
const max_diffs: usize = 20;
var provided_signal = std.atomic.Value(bool).init(false);

const ignored_field_allowlist = [_][]const u8{
    "id",
    "title",
    "providerFamily",
    "input",
    "metadata",
    "schemaVersion",
    "expected.onPayload",
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    try runBoundedDiffSelfTest(allocator);
    try runPathSpecificComparatorSelfTests(allocator);
    try runIgnoredAllowlistSelfTest(allocator);
    try runProductionRequestBuilderProofSelfTest(allocator);

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

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const actual_fixture = try buildActualFixtureComparisonRoot(arena.allocator(), fixture.value);

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
        std.debug.print("OpenAI Responses parity failed for {d} scenario(s); diff bound={d} bytes\n", .{ failures, max_diff_output_bytes });
        std.process.exit(1);
    }

    const ignored_summary = try ignored_paths.summary(allocator);
    defer allocator.free(ignored_summary);
    const allowlist_summary = try ignoredAllowlistSummary(allocator);
    defer allocator.free(allowlist_summary);

    std.debug.print(
        "OpenAI Responses parity matched {d} scenarios; comparator negative self-tests and production request-surface proof passed; ignored paths: {s}; ignored allowlist: {s}\n",
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

fn buildActualFixtureComparisonRoot(allocator: std.mem.Allocator, fixture: std.json.Value) !std.json.Value {
    if (getObjectField(fixture, "schemaVersion").integer != 1) return error.UnsupportedFixtureSchemaVersion;
    const request = try buildRequestFromFixtureInput(allocator, getObjectField(fixture, "input"), getObjectField(fixture, "providerFamily").string, getObjectField(fixture, "id").string);

    var expected = try initObject(allocator);
    try putValue(allocator, &expected, "typeScriptRequest", request);

    var root = try initObject(allocator);
    try putValue(allocator, &root, "expected", .{ .object = expected });
    return .{ .object = root };
}

fn buildRequestFromFixtureInput(allocator: std.mem.Allocator, input: std.json.Value, provider_family: []const u8, scenario_id: []const u8) !std.json.Value {
    const model_json = getObjectField(input, "model");
    const context_json = getObjectField(input, "context");
    const options_json = getObjectField(input, "options");
    const env = optionalField(input, "env");

    const model = try modelFromFixtureInput(allocator, model_json);
    const context = try contextFromFixtureInput(allocator, context_json, model);
    const options = try streamOptionsFromFixtureInput(allocator, model_json, options_json);
    const payload_override = if (optionalString(options_json, "onPayload")) |mode|
        if (std.mem.eql(u8, mode, "replace-with-fixture-payload")) getObjectField(options_json, "payloadReplacement") else null
    else
        null;

    if (std.mem.eql(u8, provider_family, "azure-openai")) {
        return try azure_openai_responses.buildRequestSnapshotValueWithEnv(
            allocator,
            model,
            context,
            options,
            .{
                .azure_api_version = if (env) |value| optionalString(value, "AZURE_OPENAI_API_VERSION") else null,
                .azure_base_url = if (env) |value| optionalString(value, "AZURE_OPENAI_BASE_URL") else null,
                .azure_resource_name = if (env) |value| optionalString(value, "AZURE_OPENAI_RESOURCE_NAME") else null,
                .azure_deployment_name_map = if (env) |value| optionalString(value, "AZURE_OPENAI_DEPLOYMENT_NAME_MAP") else null,
            },
            .{
                .scenario_id = scenario_id,
                .provider_family = provider_family,
                .payload_override = payload_override,
            },
        );
    }

    if (std.mem.eql(u8, provider_family, "openai-codex")) {
        const transport = optionalString(options_json, "transport") orelse "sse";
        const is_websocket = std.mem.eql(u8, transport, "websocket");
        const deferred = is_websocket or std.mem.eql(u8, transport, "auto");
        return try openai_codex_responses.buildRequestSnapshotValue(
            allocator,
            model,
            context,
            options,
            .{
                .scenario_id = scenario_id,
                .provider_family = provider_family,
                .payload_override = payload_override,
                .transport_mode = if (deferred) .deferred_websocket else .sse,
                .mocked_status = if (is_websocket) 101 else 200,
                .method = if (is_websocket) "WEBSOCKET" else "POST",
            },
        );
    }

    return try openai_responses.buildRequestSnapshotValue(
        allocator,
        model,
        context,
        options,
        .{
            .scenario_id = scenario_id,
            .provider_family = provider_family,
            .payload_override = payload_override,
        },
    );
}

fn modelFromFixtureInput(allocator: std.mem.Allocator, model: std.json.Value) !types.Model {
    const input_json = getObjectField(model, "input");
    const input_types = try allocator.alloc([]const u8, input_json.array.items.len);
    for (input_json.array.items, 0..) |item, index| input_types[index] = item.string;
    return .{
        .id = getObjectField(model, "id").string,
        .name = getObjectField(model, "name").string,
        .api = getObjectField(model, "api").string,
        .provider = getObjectField(model, "provider").string,
        .base_url = getObjectField(model, "baseUrl").string,
        .reasoning = optionalBool(model, "reasoning") orelse false,
        .input_types = input_types,
        .context_window = 0,
        .max_tokens = 0,
        .headers = try headersMapFromObject(allocator, optionalField(model, "headers")),
        .compat = optionalField(model, "compat"),
    };
}

fn contextFromFixtureInput(allocator: std.mem.Allocator, context: std.json.Value, model: types.Model) !types.Context {
    const messages_json = getObjectField(context, "messages");
    const messages = try allocator.alloc(types.Message, messages_json.array.items.len);
    for (messages_json.array.items, 0..) |message, index| messages[index] = try messageFromFixtureInput(allocator, message, model);
    return .{
        .system_prompt = optionalString(context, "systemPrompt"),
        .messages = messages,
        .tools = try toolsFromFixtureInput(allocator, optionalField(context, "tools")),
    };
}

fn messageFromFixtureInput(allocator: std.mem.Allocator, message: std.json.Value, model: types.Model) !types.Message {
    const role = getObjectField(message, "role").string;
    if (std.mem.eql(u8, role, "user")) {
        return .{ .user = .{
            .content = try contentBlocksFromFixtureInput(allocator, getObjectField(message, "content")),
            .timestamp = 0,
        } };
    }
    if (std.mem.eql(u8, role, "assistant")) {
        return .{ .assistant = .{
            .content = try contentBlocksFromFixtureInput(allocator, getObjectField(message, "content")),
            .api = optionalString(message, "api") orelse model.api,
            .provider = optionalString(message, "provider") orelse model.provider,
            .model = optionalString(message, "model") orelse model.id,
            .response_id = optionalString(message, "responseId"),
            .usage = types.Usage.init(),
            .stop_reason = stopReasonFromFixture(optionalString(message, "stopReason")),
            .timestamp = 0,
        } };
    }
    if (std.mem.eql(u8, role, "toolResult")) {
        return .{ .tool_result = .{
            .tool_call_id = getObjectField(message, "toolCallId").string,
            .tool_name = getObjectField(message, "toolName").string,
            .content = try contentBlocksFromFixtureInput(allocator, getObjectField(message, "content")),
            .is_error = optionalBool(message, "isError") orelse false,
            .timestamp = 0,
        } };
    }
    return error.UnsupportedFixtureMessageRole;
}

fn contentBlocksFromFixtureInput(allocator: std.mem.Allocator, content: std.json.Value) ![]const types.ContentBlock {
    if (content == .string) {
        const blocks = try allocator.alloc(types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = content.string } };
        return blocks;
    }

    var blocks = std.ArrayList(types.ContentBlock).empty;
    for (content.array.items) |part| {
        const part_type = getObjectField(part, "type").string;
        if (std.mem.eql(u8, part_type, "text")) {
            try blocks.append(allocator, .{ .text = .{
                .text = getObjectField(part, "text").string,
                .text_signature = optionalString(part, "textSignature"),
            } });
        } else if (std.mem.eql(u8, part_type, "image")) {
            try blocks.append(allocator, .{ .image = .{
                .data = getObjectField(part, "data").string,
                .mime_type = getObjectField(part, "mimeType").string,
            } });
        } else if (std.mem.eql(u8, part_type, "thinking")) {
            try blocks.append(allocator, .{ .thinking = .{
                .thinking = getObjectField(part, "thinking").string,
                .thinking_signature = optionalString(part, "thinkingSignature"),
            } });
        } else if (std.mem.eql(u8, part_type, "toolCall")) {
            try blocks.append(allocator, .{ .tool_call = .{
                .id = getObjectField(part, "id").string,
                .name = getObjectField(part, "name").string,
                .arguments = getObjectField(part, "arguments"),
            } });
        }
    }
    return try blocks.toOwnedSlice(allocator);
}

fn toolsFromFixtureInput(allocator: std.mem.Allocator, maybe_tools: ?std.json.Value) !?[]const types.Tool {
    const tools_json = maybe_tools orelse return null;
    if (tools_json != .array) return null;
    const tools = try allocator.alloc(types.Tool, tools_json.array.items.len);
    for (tools_json.array.items, 0..) |tool, index| {
        tools[index] = .{
            .name = getObjectField(tool, "name").string,
            .description = getObjectField(tool, "description").string,
            .parameters = getObjectField(tool, "parameters"),
        };
    }
    return tools;
}

fn streamOptionsFromFixtureInput(allocator: std.mem.Allocator, model: std.json.Value, options: std.json.Value) !?types.StreamOptions {
    var stream_options = types.StreamOptions{
        .api_key = if (std.mem.eql(u8, optionalString(options, "apiKeyMode") orelse "fixture-placeholder", "fixture-codex-jwt"))
            fixture_codex_jwt
        else
            "fixture-api-key-redacted",
        .headers = try headersMapFromObject(allocator, optionalField(options, "headers")),
        .cache_retention = cacheRetentionFromFixture(optionalString(options, "cacheRetention")),
        .session_id = optionalString(options, "sessionId"),
        .timeout_ms = optionalU32(options, "timeoutMs"),
        .max_retries = optionalU32(options, "maxRetries"),
        .max_tokens = optionalU32(options, "maxTokens"),
        .metadata = optionalField(options, "metadata"),
        .responses_reasoning_summary = optionalString(options, "reasoningSummary"),
        .responses_service_tier = optionalString(options, "serviceTier"),
        .responses_text_verbosity = optionalString(options, "textVerbosity"),
        .azure_api_version = optionalString(options, "azureApiVersion"),
        .azure_resource_name = optionalString(options, "azureResourceName"),
        .azure_base_url = optionalString(options, "azureBaseUrl"),
        .azure_deployment_name = optionalString(options, "azureDeploymentName"),
    };

    if (optionalNumber(options, "temperature")) |temperature| stream_options.temperature = @floatCast(temperature);
    if (optionalString(options, "signal")) |signal| {
        if (std.mem.eql(u8, signal, "provided")) {
            provided_signal.store(false, .seq_cst);
            stream_options.signal = &provided_signal;
        }
    }
    if (optionalString(options, "reasoningEffort")) |effort| stream_options.responses_reasoning_effort = try thinkingLevelFromString(effort);
    if (optionalString(options, "simpleReasoning")) |effort| {
        const clamped = try clampSimpleReasoning(allocator, getObjectField(model, "id").string, effort);
        stream_options.responses_reasoning_effort = try thinkingLevelFromString(clamped);
        if (stream_options.max_tokens == null) stream_options.max_tokens = 4096;
    }
    return stream_options;
}

fn headersMapFromObject(allocator: std.mem.Allocator, maybe_headers: ?std.json.Value) !?std.StringHashMap([]const u8) {
    const headers_json = maybe_headers orelse return null;
    if (headers_json != .object) return null;
    var headers = std.StringHashMap([]const u8).init(allocator);
    var iterator = headers_json.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* == .string) try headers.put(entry.key_ptr.*, entry.value_ptr.string);
    }
    return headers;
}

fn cacheRetentionFromFixture(value: ?[]const u8) types.CacheRetention {
    const retention = value orelse return .unset;
    if (std.mem.eql(u8, retention, "none")) return .none;
    if (std.mem.eql(u8, retention, "long") or std.mem.eql(u8, retention, "env-long")) return .long;
    if (std.mem.eql(u8, retention, "short")) return .short;
    return .unset;
}

fn thinkingLevelFromString(value: []const u8) !types.ThinkingLevel {
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return error.UnsupportedFixtureThinkingLevel;
}

fn stopReasonFromFixture(value: ?[]const u8) types.StopReason {
    const reason = value orelse return .stop;
    if (std.mem.eql(u8, reason, "length")) return .length;
    if (std.mem.eql(u8, reason, "toolUse")) return .tool_use;
    if (std.mem.eql(u8, reason, "error")) return .error_reason;
    if (std.mem.eql(u8, reason, "aborted")) return .aborted;
    return .stop;
}

fn clampSimpleReasoning(allocator: std.mem.Allocator, model_id: []const u8, effort: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, effort, "xhigh")) return effort;
    if (supportsXhigh(model_id)) return effort;
    return try allocator.dupe(u8, "high");
}

fn supportsXhigh(model_id: []const u8) bool {
    return std.mem.indexOf(u8, model_id, "gpt-5.2") != null or
        std.mem.indexOf(u8, model_id, "gpt-5.3") != null or
        std.mem.indexOf(u8, model_id, "gpt-5.4") != null or
        std.mem.indexOf(u8, model_id, "gpt-5.5") != null or
        std.mem.indexOf(u8, model_id, "deepseek-v4-pro") != null or
        std.mem.indexOf(u8, model_id, "deepseek-v4-flash") != null or
        std.mem.indexOf(u8, model_id, "opus-4-6") != null or
        std.mem.indexOf(u8, model_id, "opus-4.6") != null or
        std.mem.indexOf(u8, model_id, "opus-4-7") != null or
        std.mem.indexOf(u8, model_id, "opus-4.7") != null;
}

fn initObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
}

fn putString(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .string = try allocator.dupe(u8, value) });
}

fn putBool(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: bool) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .bool = value });
}

fn putInteger(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: u32) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .integer = @intCast(value) });
}

fn putFloat(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: f64) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .float = value });
}

fn putValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    try object.put(allocator, try allocator.dupe(u8, key), value);
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => |boolean| return .{ .bool = boolean },
        .integer => |integer| return .{ .integer = integer },
        .float => |float| return .{ .float = float },
        .number_string => |number_string| return .{ .number_string = try allocator.dupe(u8, number_string) },
        .string => |string| return .{ .string = try allocator.dupe(u8, string) },
        .array => |array| {
            var cloned = std.json.Array.init(allocator);
            for (array.items) |item| try cloned.append(try cloneJsonValue(allocator, item));
            return .{ .array = cloned };
        },
        .object => |object| {
            var cloned = try initObject(allocator);
            var iterator = object.iterator();
            while (iterator.next()) |entry| try putValue(allocator, &cloned, entry.key_ptr.*, try cloneJsonValue(allocator, entry.value_ptr.*));
            return .{ .object = cloned };
        },
    }
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

fn optionalNumber(value: std.json.Value, key: []const u8) ?f64 {
    const field = optionalField(value, key) orelse return null;
    return switch (field) {
        .integer => @floatFromInt(field.integer),
        .float => field.float,
        else => null,
    };
}

const DiffCollector = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    count: usize = 0,
    truncated: bool = false,

    fn init(allocator: std.mem.Allocator) DiffCollector {
        return .{ .allocator = allocator, .buffer = std.ArrayList(u8).empty };
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
        const header = try std.fmt.allocPrint(self.allocator, "scenario {s}: path {s}\n  expected: ", .{ scenario_id, path });
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

fn compareJson(diffs: *DiffCollector, ignored_paths: *IgnoredPathTracker, scenario_id: []const u8, path: []const u8, expected: std.json.Value, actual: std.json.Value) !void {
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

const ComparatorNegativeCase = struct {
    name: []const u8,
    scenario_id: []const u8,
    path: []const u8,
    expected_json: []const u8,
    actual_json: []const u8,
};

fn runPathSpecificComparatorSelfTests(allocator: std.mem.Allocator) !void {
    const cases = [_]ComparatorNegativeCase{
        .{
            .name = "header diff",
            .scenario_id = "negative-header-diff-self-test",
            .path = "expected.typeScriptRequest.headers.openai-intent",
            .expected_json = "{\"expected\":{\"typeScriptRequest\":{\"headers\":{\"openai-intent\":\"conversation-edits\"}}}}",
            .actual_json = "{\"expected\":{\"typeScriptRequest\":{\"headers\":{\"openai-intent\":\"fixture-override\"}}}}",
        },
        .{
            .name = "payload diff",
            .scenario_id = "negative-payload-diff-self-test",
            .path = "expected.typeScriptRequest.jsonPayload.input[0].role",
            .expected_json = "{\"expected\":{\"typeScriptRequest\":{\"jsonPayload\":{\"input\":[{\"role\":\"developer\"}]}}}}",
            .actual_json = "{\"expected\":{\"typeScriptRequest\":{\"jsonPayload\":{\"input\":[{\"role\":\"system\"}]}}}}",
        },
        .{
            .name = "url diff",
            .scenario_id = "negative-url-diff-self-test",
            .path = "expected.typeScriptRequest.url",
            .expected_json = "{\"expected\":{\"typeScriptRequest\":{\"url\":\"https://api.openai.com/v1/responses\"}}}",
            .actual_json = "{\"expected\":{\"typeScriptRequest\":{\"url\":\"https://api.openai.com/v1/wrong\"}}}",
        },
        .{
            .name = "path/query diff",
            .scenario_id = "negative-query-diff-self-test",
            .path = "expected.typeScriptRequest.query.api-version",
            .expected_json = "{\"expected\":{\"typeScriptRequest\":{\"path\":\"/openai/v1/responses\",\"query\":{\"api-version\":\"2025-04-01-preview\"}}}}",
            .actual_json = "{\"expected\":{\"typeScriptRequest\":{\"path\":\"/openai/v1/responses\",\"query\":{\"api-version\":\"v1\"}}}}",
        },
        .{
            .name = "request options diff",
            .scenario_id = "negative-request-options-diff-self-test",
            .path = "expected.typeScriptRequest.requestOptions.timeoutMs",
            .expected_json = "{\"expected\":{\"typeScriptRequest\":{\"requestOptions\":{\"signal\":\"not-provided\",\"timeoutMs\":1234}}}}",
            .actual_json = "{\"expected\":{\"typeScriptRequest\":{\"requestOptions\":{\"signal\":\"not-provided\",\"timeoutMs\":5678}}}}",
        },
        .{
            .name = "transport metadata diff",
            .scenario_id = "negative-metadata-diff-self-test",
            .path = "expected.typeScriptRequest.transportMetadata.mode",
            .expected_json = "{\"expected\":{\"typeScriptRequest\":{\"transportMetadata\":{\"mode\":\"sse\"}}}}",
            .actual_json = "{\"expected\":{\"typeScriptRequest\":{\"transportMetadata\":{\"mode\":\"deferred-websocket\"}}}}",
        },
        .{
            .name = "unallowlisted extra diff",
            .scenario_id = "negative-unallowlisted-extra-self-test",
            .path = "expected.typeScriptRequest.unallowlistedExtra",
            .expected_json = "{\"expected\":{\"typeScriptRequest\":{\"unallowlistedExtra\":true}}}",
            .actual_json = "{\"expected\":{\"typeScriptRequest\":{}}}",
        },
    };

    for (cases) |case| try runComparatorNegativeCase(allocator, case);
}

fn runComparatorNegativeCase(allocator: std.mem.Allocator, case: ComparatorNegativeCase) !void {
    const expected = try std.json.parseFromSlice(std.json.Value, allocator, case.expected_json, .{});
    defer expected.deinit();
    const actual = try std.json.parseFromSlice(std.json.Value, allocator, case.actual_json, .{});
    defer actual.deinit();

    var ignored_paths = IgnoredPathTracker{};
    var diffs = DiffCollector.init(allocator);
    defer diffs.deinit();
    try compareJson(&diffs, &ignored_paths, case.scenario_id, "", expected.value, actual.value);
    if (diffs.count == 0) return error.ComparatorNegativeSelfTestDidNotFail;
    if (diffs.buffer.items.len > max_diff_output_bytes) return error.UnboundedDiffOutput;
    if (std.mem.indexOf(u8, diffs.buffer.items, case.scenario_id) == null) return error.ComparatorNegativeScenarioIdNotReported;
    const path_text = try std.fmt.allocPrint(allocator, "path {s}", .{case.path});
    defer allocator.free(path_text);
    if (std.mem.indexOf(u8, diffs.buffer.items, path_text) == null) {
        std.debug.print("Comparator negative self-test {s} did not report exact path {s}; output:\n{s}", .{ case.name, case.path, diffs.buffer.items });
        return error.ComparatorNegativePathNotReported;
    }
    const forbidden = [_][]const u8{ "Bearer ", "sk-", "/Users/", "file://" };
    for (forbidden) |marker| {
        if (std.mem.indexOf(u8, diffs.buffer.items, marker) != null) return error.ComparatorNegativeOutputLeakedSecretLikeValue;
    }
}

fn runIgnoredAllowlistSelfTest(allocator: std.mem.Allocator) !void {
    const expected_json =
        \\{
        \\  "id": "allowlisted-id",
        \\  "expected": {"typeScriptRequest": {}, "futureExpectedField": true},
        \\  "futureRootField": true
        \\}
    ;
    const actual_json =
        \\{
        \\  "expected": {"typeScriptRequest": {}},
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
    if (std.mem.indexOf(u8, diffs.buffer.items, "expected.futureExpectedField") == null) return error.UnallowlistedFixtureFieldPathNotReported;
    if (std.mem.indexOf(u8, diffs.buffer.items, "futureRootField") == null) return error.UnallowlistedFixtureFieldPathNotReported;
    if (std.mem.indexOf(u8, diffs.buffer.items, "actualOnlyField") == null) return error.UnallowlistedFixtureFieldPathNotReported;
}

fn runProductionRequestBuilderProofSelfTest(allocator: std.mem.Allocator) !void {
    try runProductionSnapshotProofCase(
        allocator,
        "production-openai-responses-snapshot-proof",
        "openai",
        "{\"id\":\"gpt-5-mini-proof\",\"name\":\"proof\",\"api\":\"openai-responses\",\"provider\":\"openai\",\"baseUrl\":\"https://api.openai.com/v1\",\"reasoning\":true,\"input\":[\"text\"]}",
        "{\"systemPrompt\":\"Proof prompt.\",\"messages\":[{\"role\":\"user\",\"content\":\"Proof user.\"}],\"tools\":[{\"name\":\"lookup_fixture\",\"description\":\"Lookup.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}}}}]}",
        "{\"apiKeyMode\":\"fixture-placeholder\",\"cacheRetention\":\"long\",\"sessionId\":\"proof-session\",\"reasoningEffort\":\"high\",\"reasoningSummary\":\"concise\",\"maxTokens\":64,\"temperature\":0}",
    );
    try runProductionSnapshotProofCase(
        allocator,
        "production-copilot-responses-snapshot-proof",
        "github-copilot",
        "{\"id\":\"gpt-4.1-copilot-proof\",\"name\":\"proof\",\"api\":\"openai-responses\",\"provider\":\"github-copilot\",\"baseUrl\":\"https://api.githubcopilot.com\",\"reasoning\":true,\"input\":[\"text\",\"image\"],\"headers\":{\"User-Agent\":\"GitHubCopilotChat/0.35.0\",\"Editor-Version\":\"vscode/1.107.0\",\"Editor-Plugin-Version\":\"copilot-chat/0.35.0\",\"Copilot-Integration-Id\":\"vscode-chat\"}}",
        "{\"messages\":[{\"role\":\"toolResult\",\"toolCallId\":\"call-proof\",\"toolName\":\"lookup_fixture\",\"content\":[{\"type\":\"image\",\"data\":\"iVBORw0KGgo=\",\"mimeType\":\"image/png\"}],\"isError\":false}]}",
        "{\"apiKeyMode\":\"fixture-placeholder\",\"sessionId\":\"copilot-proof-session\",\"headers\":{\"X-Initiator\":\"proof-option-initiator\"}}",
    );
    try runProductionSnapshotProofCase(
        allocator,
        "production-openai-responses-empty-user-proof",
        "openai",
        "{\"id\":\"gpt-4.1-responses-vision\",\"name\":\"proof\",\"api\":\"openai-responses\",\"provider\":\"openai\",\"baseUrl\":\"https://api.openai.com/v1\",\"reasoning\":false,\"input\":[\"text\",\"image\"]}",
        "{\"messages\":[{\"role\":\"user\",\"content\":[]},{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Look at this.\"},{\"type\":\"image\",\"data\":\"iVBORw0KGgo=\",\"mimeType\":\"image/png\"}]}]}",
        "{\"apiKeyMode\":\"fixture-placeholder\"}",
    );
    try runProductionSnapshotProofCase(
        allocator,
        "production-openai-responses-text-signature-proof",
        "openai",
        "{\"id\":\"gpt-5-mini-long-signature\",\"name\":\"proof\",\"api\":\"openai-responses\",\"provider\":\"openai\",\"baseUrl\":\"https://api.openai.com/v1\",\"reasoning\":true,\"input\":[\"text\"]}",
        "{\"messages\":[{\"role\":\"assistant\",\"api\":\"openai-responses\",\"provider\":\"openai\",\"model\":\"gpt-5-mini-long-signature\",\"stopReason\":\"stop\",\"content\":[{\"type\":\"text\",\"text\":\"Signed assistant text with long id.\",\"textSignature\":\"{\\\"v\\\":1,\\\"id\\\":\\\"message-id-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\\",\\\"phase\\\":\\\"commentary\\\"}\"}]},{\"role\":\"user\",\"content\":\"Continue after long signed replay.\"}]}",
        "{\"apiKeyMode\":\"fixture-placeholder\",\"reasoningEffort\":\"medium\"}",
    );
    try runProductionSnapshotProofCase(
        allocator,
        "production-openai-responses-tool-id-proof",
        "openai",
        "{\"id\":\"gpt-5-mini-id-normalization\",\"name\":\"proof\",\"api\":\"openai-responses\",\"provider\":\"openai\",\"baseUrl\":\"https://api.openai.com/v1\",\"reasoning\":true,\"input\":[\"text\"]}",
        "{\"messages\":[{\"role\":\"assistant\",\"api\":\"anthropic-messages\",\"provider\":\"anthropic\",\"model\":\"claude-foreign-fixture\",\"stopReason\":\"toolUse\",\"content\":[{\"type\":\"toolCall\",\"id\":\"call:foreign/with spaces|foreign-item-id-with-symbols-and-a-very-very-very-long-suffix\",\"name\":\"lookup_fixture\",\"arguments\":{\"query\":\"foreign\"}}]},{\"role\":\"toolResult\",\"toolCallId\":\"call:foreign/with spaces|foreign-item-id-with-symbols-and-a-very-very-very-long-suffix\",\"toolName\":\"lookup_fixture\",\"content\":[{\"type\":\"text\",\"text\":\"Foreign result\"}],\"isError\":false},{\"role\":\"user\",\"content\":\"Use normalized tool history.\"}]}",
        "{\"apiKeyMode\":\"fixture-placeholder\",\"reasoningEffort\":\"low\"}",
    );
    try runProductionSnapshotProofCase(
        allocator,
        "production-openai-responses-different-model-fc-id-proof",
        "openai",
        "{\"id\":\"gpt-5-mini-target-replay\",\"name\":\"proof\",\"api\":\"openai-responses\",\"provider\":\"openai\",\"baseUrl\":\"https://api.openai.com/v1\",\"reasoning\":true,\"input\":[\"text\"]}",
        "{\"messages\":[{\"role\":\"assistant\",\"api\":\"openai-responses\",\"provider\":\"openai\",\"model\":\"gpt-5-mini-source-replay\",\"stopReason\":\"toolUse\",\"content\":[{\"type\":\"toolCall\",\"id\":\"call_same_provider|fc_same_provider_item\",\"name\":\"lookup_fixture\",\"arguments\":{\"query\":\"same-provider\"}}]},{\"role\":\"toolResult\",\"toolCallId\":\"call_same_provider|fc_same_provider_item\",\"toolName\":\"lookup_fixture\",\"content\":[{\"type\":\"text\",\"text\":\"Same-provider result\"}],\"isError\":false},{\"role\":\"user\",\"content\":\"Continue after different model tool replay.\"}]}",
        "{\"apiKeyMode\":\"fixture-placeholder\",\"reasoningEffort\":\"medium\"}",
    );
    try runProductionSnapshotProofCase(
        allocator,
        "production-openai-responses-skipped-empty-message-id-proof",
        "openai",
        "{\"id\":\"gpt-5-mini-skip-counter\",\"name\":\"proof\",\"api\":\"openai-responses\",\"provider\":\"openai\",\"baseUrl\":\"https://api.openai.com/v1\",\"reasoning\":true,\"input\":[\"text\"]}",
        "{\"messages\":[{\"role\":\"user\",\"content\":[]},{\"role\":\"assistant\",\"api\":\"openai-responses\",\"provider\":\"openai\",\"model\":\"gpt-5-mini-source-skip-counter\",\"stopReason\":\"stop\",\"content\":[{\"type\":\"text\",\"text\":\"Fallback id should ignore the skipped empty user message.\"}]},{\"role\":\"user\",\"content\":\"Continue after skipped empty content.\"}]}",
        "{\"apiKeyMode\":\"fixture-placeholder\",\"reasoningEffort\":\"medium\"}",
    );
    try runProductionSnapshotProofCase(
        allocator,
        "production-azure-responses-snapshot-proof",
        "azure-openai",
        "{\"id\":\"gpt-4.1-azure-proof\",\"name\":\"proof\",\"api\":\"azure-openai-responses\",\"provider\":\"azure-openai-responses\",\"baseUrl\":\"https://fixture-resource.openai.azure.com\",\"reasoning\":false,\"input\":[\"text\"]}",
        "{\"messages\":[{\"role\":\"user\",\"content\":\"Proof Azure.\"}]}",
        "{\"apiKeyMode\":\"fixture-placeholder\",\"azureDeploymentName\":\"proof-deployment\",\"sessionId\":\"azure-proof-session\",\"maxTokens\":32}",
    );
    try runProductionSnapshotProofCase(
        allocator,
        "production-codex-responses-snapshot-proof",
        "openai-codex",
        "{\"id\":\"gpt-5.1-codex\",\"name\":\"proof\",\"api\":\"openai-codex-responses\",\"provider\":\"openai-codex\",\"baseUrl\":\"https://chatgpt.com/backend-api\",\"reasoning\":true,\"input\":[\"text\"]}",
        "{\"systemPrompt\":\"Codex proof instructions.\",\"messages\":[{\"role\":\"user\",\"content\":\"Proof Codex.\"}]}",
        "{\"apiKeyMode\":\"fixture-codex-jwt\",\"sessionId\":\"codex-proof-session\",\"textVerbosity\":\"low\",\"reasoningEffort\":\"minimal\",\"serviceTier\":\"flex\",\"metadata\":{\"fixture\":\"codex-metadata-should-be-omitted\"},\"transport\":\"sse\"}",
    );
}

fn runProductionSnapshotProofCase(
    allocator: std.mem.Allocator,
    scenario_id: []const u8,
    provider_family: []const u8,
    model_json_text: []const u8,
    context_json_text: []const u8,
    options_json_text: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const proof_allocator = arena.allocator();

    const model = try std.json.parseFromSlice(std.json.Value, proof_allocator, model_json_text, .{});
    const context = try std.json.parseFromSlice(std.json.Value, proof_allocator, context_json_text, .{});
    const options = try std.json.parseFromSlice(std.json.Value, proof_allocator, options_json_text, .{});

    var input = try initObject(proof_allocator);
    try putValue(proof_allocator, &input, "model", model.value);
    try putValue(proof_allocator, &input, "context", context.value);
    try putValue(proof_allocator, &input, "options", options.value);

    const snapshot = try buildRequestFromFixtureInput(proof_allocator, .{ .object = input }, provider_family, scenario_id);
    try requireSnapshotField(snapshot, "url");
    try requireSnapshotField(snapshot, "baseUrl");
    try requireSnapshotField(snapshot, "path");
    try requireSnapshotField(snapshot, "query");
    try requireSnapshotField(snapshot, "headers");
    try requireSnapshotField(snapshot, "jsonPayload");
    try requireSnapshotField(snapshot, "requestOptions");
    try requireSnapshotField(snapshot, "transportMetadata");
}

fn requireSnapshotField(snapshot: std.json.Value, field: []const u8) !void {
    if (snapshot != .object or snapshot.object.get(field) == null) return error.ProductionRequestBuilderProofFailed;
}
