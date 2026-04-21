# Technical Specification - Zig Native Implementation

## 1. Data Structures

### 1.1 Model
```zig
pub const Model = struct {
    id: []const u8,              // e.g., "gpt-4"
    name: []const u8,            // e.g., "GPT-4"
    api: Api,                    // "openai-completions"
    provider: Provider,          // "openai"
    base_url: []const u8,        // "https://api.openai.com/v1"
    reasoning: bool = false,     // Supports reasoning
    input_types: []const []const u8,  // ["text", "image"]
    context_window: u32,         // 8192
    max_tokens: u32,             // 4096
};
```

### 1.2 Message Types
```zig
pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,
};

pub const UserMessage = struct {
    role: []const u8 = "user",
    content: []const ContentBlock,
    timestamp: i64,
};

pub const AssistantMessage = struct {
    role: []const u8 = "assistant",
    content: []const ContentBlock,
    tool_calls: ?[]const ToolCall = null,
    api: Api,
    provider: Provider,
    model: []const u8,
    usage: Usage,
    stop_reason: StopReason,
    error_message: ?[]const u8 = null,
    timestamp: i64,
};
```

### 1.3 Content Blocks
```zig
pub const ContentBlock = union(enum) {
    text: TextContent,
    image: ImageContent,
    thinking: ThinkingContent,
};

pub const TextContent = struct {
    text: []const u8,
};

pub const ImageContent = struct {
    data: []const u8,        // base64 encoded
    mime_type: []const u8,   // "image/png"
};

pub const ThinkingContent = struct {
    thinking: []const u8,
    signature: ?[]const u8 = null,
    redacted: bool = false,
};
```

### 1.4 Event Types
```zig
pub const EventType = enum {
    start,
    text_start,
    text_delta,
    text_end,
    thinking_start,
    thinking_delta,
    thinking_end,
    toolcall_start,
    toolcall_delta,
    toolcall_end,
    done,
    error_event,
};

pub const AssistantMessageEvent = struct {
    event_type: EventType,
    content_index: ?u32 = null,
    delta: ?[]const u8 = null,
    content: ?[]const u8 = null,
    tool_call: ?ToolCall = null,
    message: ?AssistantMessage = null,
    error_message: ?[]const u8 = null,
};
```

## 2. Interface Specifications

### 2.1 EventStream

**Type**: Generic(T, R)

**Methods**:
```zig
pub fn init(
    allocator: Allocator,
    io: Io,
    is_complete: *const fn (event: T) bool,
    extract_result: *const fn (event: T) R,
) Self

pub fn deinit(self: *Self) void

pub fn push(self: *Self, event: T) void
// Precondition: mutex not held by caller
// Postcondition: event queued or delivered to waiter

pub fn next(self: *Self) ?T
// Blocking: spins until event available or stream ended
// Returns: null if stream done

pub fn end(self: *Self, result: ?R) void
// Postcondition: all waiters receive done signal

pub fn result(self: *Self) ?R
// Returns: final result if stream completed
```

**Thread Safety**: Single-producer, single-consumer. Mutex protects internal state.

**Memory**: All allocations use provided allocator. Caller must call deinit.

### 2.2 HTTP Client

**Type**: HttpClient

**Methods**:
```zig
pub fn init(allocator: Allocator) !HttpClient
// Returns: client with Threaded Io initialized

pub fn deinit(self: *HttpClient) void
// Frees Threaded Io instance

pub fn request(
    self: *HttpClient,
    req: HttpRequest,
) !HttpResponse
// Blocking: waits for full response
// Returns: status, headers, body
```

**Request Structure**:
```zig
pub const HttpRequest = struct {
    method: HttpMethod = .POST,
    url: []const u8,
    headers: ?std.StringHashMap([]const u8) = null,
    body: ?[]const u8 = null,
};
```

**Response Structure**:
```zig
pub const HttpResponse = struct {
    status: u16,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *HttpResponse) void
};
```

### 2.3 JSON Parser

**Function**:
```zig
pub fn parseStreamingJson(
    allocator: Allocator,
    input: ?[]const u8,
) !std.json.Value
```

**Algorithm**:
1. If input null or empty, return empty object
2. Trim whitespace
3. Try full parse with std.json.parseFromSlice
4. On failure, binary search for longest valid prefix
5. If all prefixes fail, return empty object

**Memory**: Caller must free returned Value with std.json.parseFree

### 2.4 OpenAI Provider

**Functions**:
```zig
pub fn buildRequestPayload(
    allocator: Allocator,
    model: Model,
    context: Context,
    options: ?StreamOptions,
) !std.json.Value

pub fn parseSseLine(line: []const u8) ?[]const u8
// Returns: data after "data: " prefix, or null

pub fn parseChunk(
    allocator: Allocator,
    data: []const u8,
) !?std.json.Value
// Returns: null for "[DONE]" or empty
```

## 3. Constants

```zig
// HTTP
const DEFAULT_TIMEOUT_MS = 30000;
const MAX_BODY_SIZE = 10 * 1024 * 1024;  // 10MB

// SSE
const SSE_PREFIX = "data: ";
const SSE_DONE = "[DONE]";

// JSON
const DEFAULT_MAX_TOKENS = 4096;
const DEFAULT_TEMPERATURE = 0.7;

// Memory
const INITIAL_QUEUE_CAPACITY = 16;
const INITIAL_WAITING_CAPACITY = 4;
```

## 4. Algorithms

### 4.1 SSE Line Processing
```
Input: byte stream from HTTP response
Output: sequence of JSON chunks

1. Read line until '\n'
2. If line starts with "data: ", extract payload
3. If payload == "[DONE]", signal completion
4. Else parse payload as JSON
5. Yield parsed chunk
6. Repeat until stream closed
```

### 4.2 Event Stream State Machine
```
States: IDLE, STREAMING, DONE, ERROR

IDLE + push(event) → STREAMING
STREAMING + push(done_event) → DONE
STREAMING + push(error_event) → ERROR
STREAMING + next() → STREAMING (return event)
DONE + next() → DONE (return null)
ERROR + next() → ERROR (return null)
```

### 4.3 Partial JSON Recovery
```
Input: invalid JSON string
Output: longest valid prefix parse

1. Try parse full string
2. If success, return result
3. For i from len-1 down to 1:
   a. Try parse prefix[0..i]
   b. If success, return result
4. Return empty object
```

## 5. Error Codes

```zig
pub const Error = error{
    OutOfMemory,
    HttpRequestFailed,
    InvalidJson,
    SseParseError,
    ProviderNotFound,
    StreamClosed,
    InvalidState,
};
```

## 6. State Management

### 6.1 Registry Lifecycle
```
init() → register() → get() → clear()
```

### 6.2 Stream Lifecycle
```
init() → [push() | next()]* → end() → deinit()
```

### 6.3 HTTP Request Lifecycle
```
init() → request() → deinit(response) → deinit()
```

## 7. Memory Layout

### 7.1 EventStream
```
0x00: allocator (8 bytes)
0x08: queue (ArrayList, 24 bytes)
0x20: waiting (ArrayList, 24 bytes)
0x38: done (1 byte)
0x39: padding (7 bytes)
0x40: final_result (16 bytes, optional)
0x50: mutex (std.Io.Mutex, 4 bytes)
0x54: io (std.Io, 16 bytes)
0x64: is_complete_fn (8 bytes)
0x6C: extract_result_fn (8 bytes)
Total: ~116 bytes
```

### 7.2 AssistantMessage
```
0x00: role (16 bytes, slice)
0x10: content (16 bytes, slice)
0x20: tool_calls (16 bytes, optional slice)
0x30: api (16 bytes, slice)
0x40: provider (16 bytes, slice)
0x50: model (16 bytes, slice)
0x60: usage (20 bytes)
0x74: stop_reason (4 bytes)
0x78: error_message (16 bytes, optional)
0x88: timestamp (8 bytes)
Total: ~144 bytes
```

## 8. Build Configuration

```zig
// build.zig
const exe = b.addExecutable(.{
    .name = "pi",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

**Build Targets**:
- `zig build` - Debug build
- `zig build -Doptimize=ReleaseFast` - Optimized build
- `zig build test` - Run all tests
- `zig build run` - Build and run

## 9. Testing Matrix

| Component | Unit Tests | Integration | Property |
|-----------|-----------|-------------|----------|
| types | ✓ | - | - |
| api_registry | ✓ | - | - |
| event_stream | ✓ | - | - |
| http_client | ✓ | - | - |
| json_parse | ✓ | ✓ | Phase 2 |
| openai | ✓ | ✓ | - |

## 10. Migration Checklist

- [x] Phase 1: Core types
- [x] Phase 2: JSON parser
- [x] Phase 3: HTTP client
- [x] Phase 4: Event stream
- [x] Phase 5: Provider registry
- [ ] Phase 6: OpenAI streaming (partial)
- [ ] Phase 7: CLI entry
- [ ] Phase 8: Configuration
- [ ] Phase 9: Additional providers
