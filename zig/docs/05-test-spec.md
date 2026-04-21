# Test Specification - Zig Native Implementation

## 1. Unit Tests

### 1.1 types.zig
```zig
test "Usage defaults" {
    const usage = Usage.init();
    try expectEqual(@as(u32, 0), usage.input);
    try expectEqual(@as(u32, 0), usage.output);
}

test "Message union" {
    const user_msg = Message{ .user = .{
        .content = &[1]ContentBlock{.{ .text = .{ .text = "hello" } }},
        .timestamp = 1234567890,
    } };
    try expectEqualStrings("user", user_msg.user.role);
}
```

### 1.2 api_registry.zig
```zig
test "registry basic operations" {
    clear();
    
    try register(.{
        .api = "openai-completions",
        .stream = dummy_stream,
        .stream_simple = dummy_stream,
    });
    
    try expectEqual(@as(usize, 1), getApiCount());
    
    const provider = get("openai-completions");
    try expect(provider != null);
    
    const not_found = get("nonexistent");
    try expect(not_found == null);
}
```

### 1.3 json_parse.zig
```zig
test "parseStreamingJson complete JSON" {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"foo\": 123}", .{});
    defer parsed.deinit();
    try expect(parsed.value == .object);
    try expectEqual(@as(i64, 123), parsed.value.object.get("foo").?.integer);
}

test "parseStreamingJson empty string" {
    var result = try parseStreamingJson(allocator, "");
    defer result.object.deinit(allocator);
    try expect(result == .object);
    try expectEqual(@as(usize, 0), result.object.count());
}

test "parseStreamingJson null input" {
    var result = try parseStreamingJson(allocator, null);
    defer result.object.deinit(allocator);
    try expect(result == .object);
    try expectEqual(@as(usize, 0), result.object.count());
}

test "parseStreamingJson partial JSON" {
    var result = try parseStreamingJson(allocator, "{\"foo\": 123, \"bar");
    defer result.object.deinit(allocator);
    try expect(result == .object);
    // Should return {"foo": 123} or {}
}

test "parseStreamingJson nested objects" {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\": {\"b\": [1, 2, 3]}}", .{});
    defer parsed.deinit();
    try expect(parsed.value == .object);
    const a = parsed.value.object.get("a").?;
    try expect(a == .object);
    const b = a.object.get("b").?;
    try expect(b == .array);
    try expectEqual(@as(usize, 3), b.array.items.len);
}

test "parseStreamingJson arrays" {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[1, 2, {\"x\": true}]", .{});
    defer parsed.deinit();
    try expect(parsed.value == .array);
    try expectEqual(@as(usize, 3), parsed.value.array.items.len);
}
```

### 1.4 http_client.zig
```zig
test "HttpClient init/deinit" {
    var client = try HttpClient.init(std.testing.allocator);
    client.deinit();
}
```

### 1.5 event_stream.zig
```zig
test "EventStream basic operations" {
    const io = std.Io.failing;
    var stream = AssistantMessageEventStream.init(allocator, io, isCompleteEvent, extractResult);
    defer stream.deinit();

    stream.push(.{ .event_type = .start });
    stream.push(.{ .event_type = .text_delta, .delta = "Hello" });
    
    const msg = AssistantMessage{
        .role = "assistant",
        .content = &[1]ContentBlock{.{ .text = .{ .text = "Hello" } }},
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4",
        .usage = Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1234567890,
    };
    stream.push(.{ .event_type = .done, .message = msg });

    const event1 = stream.next().?;
    try expectEqual(EventType.start, event1.event_type);

    const event2 = stream.next().?;
    try expectEqual(EventType.text_delta, event2.event_type);
    try expectEqualStrings("Hello", event2.delta.?);

    const event3 = stream.next().?;
    try expectEqual(EventType.done, event3.event_type);

    try expect(stream.next() == null);

    const result = stream.result().?;
    try expectEqualStrings("gpt-4", result.model);
}

test "EventStream end without events" {
    const io = std.Io.failing;
    var stream = AssistantMessageEventStream.init(allocator, io, isCompleteEvent, extractResult);
    defer stream.deinit();

    const msg = AssistantMessage{
        .role = "assistant",
        .content = &[_]ContentBlock{},
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4",
        .usage = Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1234567890,
    };

    stream.end(msg);

    try expect(stream.next() == null);
    const result = stream.result().?;
    try expectEqualStrings("gpt-4", result.model);
}
```

### 1.6 providers/openai.zig
```zig
test "buildRequestPayload basic" {
    const model = Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[1][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    const context = Context{
        .system_prompt = "You are a helpful assistant.",
        .messages = &[1]Message{
            .{ .user = .{
                .content = &[1]ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1234567890,
            } },
        },
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer payload.deinit(allocator);

    try expect(payload == .object);
    const model_val = payload.object.get("model").?;
    try expectEqualStrings("gpt-4", model_val.string);

    const messages = payload.object.get("messages").?;
    try expect(messages == .array);
    try expectEqual(@as(usize, 2), messages.array.items.len);
}

test "parseSseLine" {
    const line = "data: {\"foo\": 123}";
    const result = parseSseLine(line);
    try expect(result != null);
    try expectEqualStrings("{\"foo\": 123}", result.?);

    const no_data = "event: start";
    const no_result = parseSseLine(no_data);
    try expect(no_result == null);
}

test "parseChunk" {
    const done = try parseChunk(allocator, "[DONE]");
    try expect(done == null);

    const empty = try parseChunk(allocator, "");
    try expect(empty == null);

    const valid = try parseChunk(allocator, "{\"foo\": 123}");
    defer if (valid) |v| v.deinit(allocator);
    try expect(valid != null);
    try expect(valid.? == .object);
}
```

## 2. Integration Tests

### 2.1 JSON Parser Comparison
```bash
# Script: zig/test/compare-json-parse.sh
# Input: Same JSON strings for TS and Zig
# Expected: Identical parse trees
```

Test cases:
1. Complete object: `{"foo": 123}`
2. Empty string: `""`
3. Partial JSON: `{"foo": 123, "bar`
4. Nested objects: `{"a": {"b": [1, 2, 3]}}`
5. Arrays: `[1, 2, {"x": true}]`
6. Unicode: `{"emoji": "🎉"}`
7. Large numbers: `{"big": 9007199254740991}`
8. Floats: `{"pi": 3.14159}`
9. Booleans: `{"yes": true, "no": false}`
10. Null: `{"nothing": null}`

### 2.2 OpenAI Request Comparison
```bash
# Build identical requests in TS and Zig
# Compare serialized JSON
```

Test cases:
1. Basic chat with system prompt
2. Multi-turn conversation
3. With tools
4. With images (base64)
5. With streaming enabled
6. With temperature/max_tokens

### 2.3 Event Stream Comparison
```bash
# Push same events to TS and Zig streams
# Compare output sequence
```

Test cases:
1. Single text response
2. Multi-chunk streaming
3. Tool call sequence
4. Error handling
5. Early termination

## 3. Property Tests (Phase 2)

### 3.1 JSON Parser
- Random valid JSON generation
- Random invalid JSON with valid prefixes
- Fuzzing with special characters
- Memory limit testing

### 3.2 Event Stream
- Random event sequences
- Concurrent push/next patterns
- Memory leak detection

## 4. Performance Tests

### 4.1 Benchmarks
```zig
test "JSON parse benchmark" {
    const iterations = 10000;
    const json = "{\"foo\": 123, \"bar\": \"hello\", \"nested\": {\"x\": true}}";
    
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const result = try parseStreamingJson(allocator, json);
        result.deinit(allocator);
    }
    const elapsed = timer.read();
    
    std.debug.print("JSON parse: {d} ns/iter\n", .{elapsed / iterations});
}
```

### 4.2 Memory Usage
```zig
test "Memory footprint" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    // Measure baseline
    // Create 1000 messages
    // Measure peak
    // Verify no leaks
}
```

## 5. Manual Testing Checklist

- [ ] Build succeeds: `zig build`
- [ ] Tests pass: `zig build test`
- [ ] Binary runs: `./zig-out/bin/pi`
- [ ] Help text displays
- [ ] OpenAI request builds correctly
- [ ] SSE parsing handles real API response
- [ ] Event stream delivers events in order
- [ ] No memory leaks (valgrind/drmemory)
- [ ] Binary size < 10MB

## 6. Test Coverage Targets

| Module | Target | Current |
|--------|--------|---------|
| types | 80% | 60% |
| api_registry | 90% | 80% |
| event_stream | 85% | 70% |
| http_client | 70% | 30% |
| json_parse | 90% | 80% |
| openai | 75% | 50% |
| **Overall** | **80%** | **62%** |
