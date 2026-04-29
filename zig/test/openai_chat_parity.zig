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

    const manifest = try readJsonFile(allocator, io, fixture_dir ++ "/manifest.json");
    defer manifest.deinit();

    const scenario_ids = getObjectField(manifest.value, "scenarioIds").array.items;
    var failures: usize = 0;

    for (scenario_ids) |scenario_id_value| {
        const scenario_id = scenario_id_value.string;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ fixture_dir, scenario_id });
        defer allocator.free(path);

        const fixture = try readJsonFile(allocator, io, path);
        defer fixture.deinit();

        const actual = try buildActualRequestFromFixture(allocator, fixture.value);
        defer openai.freeOwnedJsonValue(allocator, actual);

        const expected = getObjectField(getObjectField(fixture.value, "expected"), "typeScriptRequest");
        var diffs = DiffCollector.init(allocator);
        defer diffs.deinit();

        try compareJson(&diffs, scenario_id, "request", expected, actual);
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

    std.debug.print(
        "OpenAI Chat parity matched {d} scenarios; ignored allowlist: {s}\n",
        .{ scenario_ids.len, ignoredAllowlistSummary() },
    );
}

fn ignoredAllowlistSummary() []const u8 {
    return "id, title, input, metadata, schemaVersion, expected.onPayload";
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
    const options = try parseOptions(scenario_allocator, getObjectField(input, "options"));

    return try openai.buildRequestSnapshotValue(allocator, model, context, options);
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
    const retention = value orelse return .short;
    if (std.mem.eql(u8, retention, "none")) return .none;
    if (std.mem.eql(u8, retention, "long")) return .long;
    return .short;
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

fn compareJson(
    diffs: *DiffCollector,
    scenario_id: []const u8,
    path: []const u8,
    expected: std.json.Value,
    actual: std.json.Value,
) !void {
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
                const child_path = try std.fmt.allocPrint(diffs.allocator, "{s}[{d}]", .{ path, index });
                defer diffs.allocator.free(child_path);
                try compareJson(diffs, scenario_id, child_path, expected_item, actual_item);
            }
        },
        .object => |expected_object| {
            var expected_iterator = expected_object.iterator();
            while (expected_iterator.next()) |entry| {
                const child_path = try std.fmt.allocPrint(diffs.allocator, "{s}.{s}", .{ path, entry.key_ptr.* });
                defer diffs.allocator.free(child_path);
                const actual_child = actual.object.get(entry.key_ptr.*) orelse {
                    try diffs.add(scenario_id, child_path, entry.value_ptr.*, .null);
                    continue;
                };
                try compareJson(diffs, scenario_id, child_path, entry.value_ptr.*, actual_child);
            }

            var actual_iterator = actual.object.iterator();
            while (actual_iterator.next()) |entry| {
                if (expected_object.get(entry.key_ptr.*) == null) {
                    const child_path = try std.fmt.allocPrint(diffs.allocator, "{s}.{s}", .{ path, entry.key_ptr.* });
                    defer diffs.allocator.free(child_path);
                    try diffs.add(scenario_id, child_path, .null, entry.value_ptr.*);
                }
            }
        },
    }
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
