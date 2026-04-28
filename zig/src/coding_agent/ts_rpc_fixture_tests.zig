const std = @import("std");

const fixture_files = [_][]const u8{
    "commands-input.jsonl",
    "jsonl-framing.jsonl",
    "parse-errors.jsonl",
    "parse-error-corpus.jsonl",
    "responses-basic.jsonl",
    "events-base-stream.jsonl",
    "events-thinking-tool-usage.jsonl",
    "events-session-extras.jsonl",
    "prompt-concurrency-queue-order.input.jsonl",
    "prompt-concurrency-queue-order.jsonl",
    "extension-ui.jsonl",
};

fn readFixture(comptime name: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        "test/golden/ts-rpc/" ++ name,
        std.testing.allocator,
        .unlimited,
    );
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectValidJsonl(comptime name: []const u8) !void {
    const bytes = try readFixture(name);
    defer std.testing.allocator.free(bytes);

    try std.testing.expect(bytes.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, bytes, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\r\n") == null);

    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        parsed.deinit();
    }
    try std.testing.expect(line_count > 0);
}

test "TS RPC fixture files are checked in and valid JSONL" {
    inline for (fixture_files) |file| {
        try expectValidJsonl(file);
    }

    const manifest = try readFixture("manifest.json");
    defer std.testing.allocator.free(manifest);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, manifest, .{});
    defer parsed.deinit();
    try expectContains(manifest, "packages/coding-agent/src/modes/rpc/jsonl.ts:10-58");
    try expectContains(manifest, "packages/coding-agent/src/modes/rpc/rpc-mode.ts:369-704");
    try expectContains(manifest, "captureMethod");
    try expectContains(manifest, "runRpcMode");
    try expectContains(manifest, "AgentSession.subscribe");
}

test "TS RPC response fixtures preserve parse and unknown-command quirks" {
    const bytes = try readFixture("responses-basic.jsonl");
    defer std.testing.allocator.free(bytes);

    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command:",
    );
    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"mystery_command\",\"success\":false,\"error\":\"Unknown command: mystery_command\"}\n",
    );
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"id\":\"mystery") == null);
}

test "TS RPC parse-error fixtures cover multiple TypeScript JSON.parse messages" {
    const bytes = try readFixture("parse-errors.jsonl");
    defer std.testing.allocator.free(bytes);
    const corpus = try readFixture("parse-error-corpus.jsonl");
    defer std.testing.allocator.free(corpus);

    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command: Unexpected end of JSON input\"}\n",
    );
    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command: Unexpected token 'o', \\\"not-json\\\" is not valid JSON\"}\n",
    );
    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command: Expected double-quoted property name in JSON at position 20 (line 1 column 21)\"}\n",
    );
    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command: Unexpected token ']', \\\"[1,]\\\" is not valid JSON\"}\n",
    );
    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command: Unexpected non-whitespace character after JSON at position 2 (line 1 column 3)\"}\n",
    );
    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command: Expected ':' after property name in JSON at position 5 (line 1 column 6)\"}\n",
    );
    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command: Unexpected token '#', \\\"{\\\"a\\\":#}\\\" is not valid JSON\"}\n",
    );
    try expectContains(corpus, "\"name\":\"extra-tokens-after-primitive\",\"input\":\"1 2\"");
    try expectContains(corpus, "\"name\":\"missing-colon\",\"input\":\"{\\\"a\\\" 1}\"");
    try expectContains(corpus, "\"name\":\"invalid-value-token\",\"input\":\"{\\\"a\\\":#}\"");
}

test "TS RPC framing fixture captures LF CRLF final-line and Unicode separator behavior" {
    const bytes = try readFixture("jsonl-framing.jsonl");
    defer std.testing.allocator.free(bytes);

    try expectContains(bytes, "fixture\xe2\x80\xa8session\xe2\x80\xa9name");
    try expectContains(bytes, "\"case\":\"lf-input-reader\"");
    try expectContains(bytes, "\"case\":\"crlf-input-reader\"");
    try expectContains(bytes, "\"case\":\"final-unterminated-input-reader\"");
    try expectContains(bytes, "\"id\":\"framing_lf_a\"");
    try expectContains(bytes, "\"id\":\"framing_crlf_a\"");
    try expectContains(bytes, "\"id\":\"framing_final\"");
    try expectContains(bytes, "\"command\":\"parse\"");
}

test "TS RPC event fixtures cover base stream thinking tools usage details and stop reasons" {
    const base = try readFixture("events-base-stream.jsonl");
    defer std.testing.allocator.free(base);
    try expectContains(base, "\"type\":\"agent_start\"");
    try expectContains(base, "\"type\":\"turn_start\"");
    try expectContains(base, "\"type\":\"message_start\"");
    try expectContains(base, "\"type\":\"message_update\"");
    try expectContains(base, "\"type\":\"message_end\"");
    try expectContains(base, "\"type\":\"turn_end\"");
    try expectContains(base, "\"type\":\"agent_end\"");

    const tool = try readFixture("events-thinking-tool-usage.jsonl");
    defer std.testing.allocator.free(tool);
    try expectContains(tool, "\"type\":\"thinking_delta\"");
    try expectContains(tool, "\"type\":\"toolcall_start\"");
    try expectContains(tool, "\"type\":\"toolcall_delta\"");
    try expectContains(tool, "\"type\":\"toolcall_end\"");
    try expectContains(tool, "\"type\":\"tool_execution_start\"");
    try expectContains(tool, "\"type\":\"tool_execution_update\"");
    try expectContains(tool, "\"type\":\"tool_execution_end\"");
    try expectContains(tool, "\"details\":");
    try expectContains(tool, "\"usage\":");
    try expectContains(tool, "\"stopReason\":\"toolUse\"");
    try expectContains(tool, "\"reason\":\"length\"");
    try expectContains(tool, "\"reason\":\"aborted\"");
}

test "TS RPC prompt concurrency fixture captures queue ordering and streamingBehavior" {
    const bytes = try readFixture("prompt-concurrency-queue-order.jsonl");
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualStrings(
        "{\"id\":\"pc_start\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n" ++
            "{\"type\":\"queue_update\",\"steering\":[\"steer while prompt running\"],\"followUp\":[]}\n" ++
            "{\"type\":\"queue_update\",\"steering\":[\"steer while prompt running\"],\"followUp\":[\"follow while prompt running\"]}\n" ++
            "{\"type\":\"queue_update\",\"steering\":[\"steer while prompt running\",\"prompt as steer\"],\"followUp\":[\"follow while prompt running\"]}\n" ++
            "{\"type\":\"queue_update\",\"steering\":[\"steer while prompt running\",\"prompt as steer\"],\"followUp\":[\"follow while prompt running\",\"prompt as follow\"]}\n" ++
            "{\"id\":\"pc_prompt_steer\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n" ++
            "{\"id\":\"pc_prompt_follow\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n" ++
            "{\"id\":\"pc_abort\",\"type\":\"response\",\"command\":\"abort\",\"success\":true}\n" ++
            "{\"id\":\"pc_steer\",\"type\":\"response\",\"command\":\"steer\",\"success\":true}\n" ++
            "{\"id\":\"pc_follow\",\"type\":\"response\",\"command\":\"follow_up\",\"success\":true}\n",
        bytes,
    );
}

test "TS RPC production and test code do not contain fixture bypass symbols" {
    const allocator = std.testing.allocator;
    const forbidden = [_][]const u8{
        "PI_TS_RPC_" ++ "FIXTURE",
        "runTsRpcPromptConcurrencyQueueOrder" ++ "Fixture",
    };
    const checked_files = [_][]const u8{
        "src/coding_agent/ts_rpc_mode.zig",
        "src/coding_agent/ts_rpc_fixture_tests.zig",
        "test/generate-ts-rpc-fixtures.ts",
        "test/ts-rpc-prompt-concurrency-fixture-diff.sh",
    };

    inline for (checked_files) |path| {
        const bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .unlimited);
        defer allocator.free(bytes);
        inline for (forbidden) |needle| {
            try std.testing.expect(std.mem.indexOf(u8, bytes, needle) == null);
        }
    }
}
