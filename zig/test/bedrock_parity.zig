const std = @import("std");
const ai = @import("ai");

const types = ai.types;
const bedrock = ai.providers.bedrock;

const fixture_dir = "test/golden/bedrock";
const max_diff_output_bytes: usize = 12_000;
const max_value_bytes: usize = 512;
const max_diffs: usize = 20;

const ignored_field_allowlist = [_][]const u8{
    "id",
    "title",
    "input",
    "metadata",
    "schemaVersion",
    "expected.onResponse",
    "expected.binaryEventStream",
};
const max_tokens_json_field = [_]u8{ 'm', 'a', 'x', 'T', 'o', 'k', 'e', 'n', 's' };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    try runBoundedDiffSelfTest(allocator);
    try runIgnoredAllowlistSelfTest(allocator);
    try runNegativeSuite(allocator);

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

        const actual_fixture = try buildActualFixtureComparisonRoot(allocator, io, fixture.value);
        defer bedrock.freeOwnedJsonValue(allocator, actual_fixture);

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
        std.debug.print("Bedrock parity failed for {d} scenario(s); diff bound={d} bytes\n", .{ failures, max_diff_output_bytes });
        std.process.exit(1);
    }

    const ignored_summary = try ignored_paths.summary(allocator);
    defer allocator.free(ignored_summary);
    const allowlist_summary = try ignoredAllowlistSummary(allocator);
    defer allocator.free(allowlist_summary);

    std.debug.print(
        "Bedrock parity matched {d} scenarios; negative suite passed; ignored paths: {s}; ignored allowlist: {s}\n",
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

fn buildActualFixtureComparisonRoot(allocator: std.mem.Allocator, io: std.Io, fixture: std.json.Value) !std.json.Value {
    if (getObjectField(fixture, "schemaVersion").integer != 1) return error.UnsupportedFixtureSchemaVersion;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scenario_allocator = arena.allocator();

    const input = getObjectField(fixture, "input");
    var model = try parseModel(scenario_allocator, getObjectField(input, "model"));
    const context = try parseContext(scenario_allocator, getObjectField(input, "context"));
    const options_value = getObjectField(input, "options");
    if (optionalU32(options_value, &max_tokens_json_field)) |fixture_max| {
        model.max_tokens = fixture_max;
    }
    const options = try parseOptions(scenario_allocator, options_value);
    const mode = getObjectField(input, "mode").string;

    const actual_request = try bedrock.buildRequestSnapshotValue(allocator, model, context, options, mode);
    errdefer bedrock.freeOwnedJsonValue(allocator, actual_request);

    const local_stream = getObjectField(input, "localStream");
    const stream_format = getObjectField(local_stream, "format").string;
    const actual_stream = if (std.mem.eql(u8, stream_format, "aws-eventstream"))
        try buildBinaryStreamSnapshot(allocator, io, fixture, model)
    else
        try bedrock.buildStreamSnapshotValueFromLocalEvents(allocator, io, model, getObjectField(local_stream, "events").array.items);
    errdefer bedrock.freeOwnedJsonValue(allocator, actual_stream);

    var expected = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer expected.deinit(allocator);
    try expected.put(allocator, try allocator.dupe(u8, "typeScriptRequest"), actual_request);
    try expected.put(allocator, try allocator.dupe(u8, "typeScriptStream"), actual_stream);

    var root = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer root.deinit(allocator);
    try root.put(allocator, try allocator.dupe(u8, "expected"), .{ .object = expected });
    return .{ .object = root };
}

fn buildBinaryStreamSnapshot(allocator: std.mem.Allocator, io: std.Io, fixture: std.json.Value, model: types.Model) !std.json.Value {
    const binary = getObjectField(getObjectField(fixture, "expected"), "binaryEventStream");
    const base64 = getObjectField(binary, "base64").string;
    const size = try std.base64.standard.Decoder.calcSizeForSlice(base64);
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    try std.base64.standard.Decoder.decode(bytes, base64);
    return try bedrock.buildStreamSnapshotValueFromBinaryBody(allocator, io, model, bytes);
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
        .context_window = 200_000,
        .max_tokens = 4096,
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
    return error.UnsupportedFixtureMessageRole;
}

fn parseContentBlocks(allocator: std.mem.Allocator, value: std.json.Value) ![]const types.ContentBlock {
    if (value == .string) {
        const blocks = try allocator.alloc(types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = value.string } };
        return blocks;
    }
    if (value == .array) {
        const blocks = try allocator.alloc(types.ContentBlock, value.array.items.len);
        for (value.array.items, 0..) |item, index| {
            const kind = getObjectField(item, "type").string;
            if (std.mem.eql(u8, kind, "text")) {
                blocks[index] = .{ .text = .{ .text = getObjectField(item, "text").string } };
            } else {
                return error.UnsupportedFixtureContentBlock;
            }
        }
        return blocks;
    }
    return error.UnsupportedFixtureContentBlock;
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

fn parseOptions(allocator: std.mem.Allocator, value: std.json.Value) !?types.StreamOptions {
    return .{
        .temperature = optionalF32(value, "temperature"),
        .cache_retention = parseCacheRetention(optionalString(value, "cacheRetention")),
        .metadata = try cloneJsonOptional(allocator, optionalField(value, "requestMetadata")),
    };
}

fn cloneJsonOptional(allocator: std.mem.Allocator, value: ?std.json.Value) !?std.json.Value {
    const input = value orelse return null;
    return try cloneJsonValue(allocator, input);
}

fn parseCacheRetention(value: ?[]const u8) types.CacheRetention {
    const retention = value orelse return .unset;
    if (std.mem.eql(u8, retention, "none")) return .none;
    if (std.mem.eql(u8, retention, "short")) return .short;
    if (std.mem.eql(u8, retention, "long")) return .long;
    return .unset;
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

fn optionalF32(value: std.json.Value, key: []const u8) ?f32 {
    const field = optionalField(value, key) orelse return null;
    return switch (field) {
        .integer => @floatFromInt(field.integer),
        .float => @floatCast(field.float),
        else => null,
    };
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
            var clone = std.json.Array.init(allocator);
            for (array.items) |item| try clone.append(try cloneJsonValue(allocator, item));
            return .{ .array = clone };
        },
        .object => |object| {
            var clone = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try clone.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            return .{ .object = clone };
        },
    }
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
    try diffs.add("bounded-diff-self-test", "expected.typeScriptRequest.payload.long", .{ .string = long_expected }, .{ .string = long_actual });
    if (diffs.buffer.items.len > max_diff_output_bytes) return error.UnboundedDiffOutput;
}

fn runIgnoredAllowlistSelfTest(allocator: std.mem.Allocator) !void {
    const expected_json =
        \\{
        \\  "id": "allowlisted-id",
        \\  "expected": {
        \\    "typeScriptRequest": {},
        \\    "typeScriptStream": [],
        \\    "futureExpectedField": true
        \\  },
        \\  "futureRootField": true
        \\}
    ;
    const actual_json =
        \\{
        \\  "expected": {
        \\    "typeScriptRequest": {},
        \\    "typeScriptStream": []
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
    if (std.mem.indexOf(u8, diffs.buffer.items, "expected.futureExpectedField") == null) return error.UnallowlistedFixtureFieldPathNotReported;
    if (std.mem.indexOf(u8, diffs.buffer.items, "futureRootField") == null) return error.UnallowlistedFixtureFieldPathNotReported;
    if (std.mem.indexOf(u8, diffs.buffer.items, "actualOnlyField") == null) return error.UnallowlistedFixtureFieldPathNotReported;
}

fn runNegativeSuite(allocator: std.mem.Allocator) !void {
    const malformed_json = "{not-json";
    if (std.json.parseFromSlice(std.json.Value, allocator, malformed_json, .{})) |parsed| {
        parsed.deinit();
        return error.NegativeMalformedJsonUnexpectedlyPassed;
    } else |_| {}

    const invalid_tool_events_json =
        \\[
        \\  {"messageStart":{"role":"assistant"}},
        \\  {"contentBlockDelta":{"contentBlockIndex":0,"delta":{"toolUse":{"input":"{}"}}}}
        \\]
    ;
    const invalid_tool_events = try std.json.parseFromSlice(std.json.Value, allocator, invalid_tool_events_json, .{});
    defer invalid_tool_events.deinit();
    const model = types.Model{
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude",
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200_000,
        .max_tokens = 4096,
    };
    const stream = try bedrock.buildStreamSnapshotValueFromLocalEvents(allocator, std.Io.failing, model, invalid_tool_events.value.array.items);
    defer bedrock.freeOwnedJsonValue(allocator, stream);
    const last = stream.array.items[stream.array.items.len - 1];
    if (!std.mem.eql(u8, getObjectField(last, "type").string, "error_event")) {
        return error.NegativeInvalidToolFramingUnexpectedlyPassed;
    }

    const bad_binary = [_]u8{ 0, 0, 0, 1 };
    const binary_stream = try bedrock.buildStreamSnapshotValueFromBinaryBody(allocator, std.Io.failing, model, &bad_binary);
    defer bedrock.freeOwnedJsonValue(allocator, binary_stream);
    const binary_last = binary_stream.array.items[binary_stream.array.items.len - 1];
    if (!std.mem.eql(u8, getObjectField(binary_last, "type").string, "error_event")) {
        return error.NegativeMalformedBinaryUnexpectedlyPassed;
    }
}
