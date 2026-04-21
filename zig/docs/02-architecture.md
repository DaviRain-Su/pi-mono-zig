# Architecture Design - Zig Native Implementation

## 1. System Overview

```
┌─────────────────────────────────────────┐
│           CLI Entry (main.zig)          │
├─────────────────────────────────────────┤
│         AI Module (src/ai/)             │
│  ┌─────────┐ ┌─────────┐ ┌──────────┐ │
│  │  Types  │ │ Registry│ │ Providers│ │
│  └────┬────┘ └────┬────┘ └────┬─────┘ │
│       │           │           │       │
│  ┌────┴────┐ ┌────┴────┐ ┌────┴────┐ │
│  │Event    │ │HTTP     │ │JSON     │ │
│  │Stream   │ │Client   │ │Parse    │ │
│  └─────────┘ └─────────┘ └─────────┘ │
└─────────────────────────────────────────┘
```

## 2. Module Structure

```
zig/
├── build.zig              # Build configuration
├── src/
│   ├── main.zig           # CLI entry point
│   └── ai/
│       ├── root.zig       # Module exports
│       ├── types.zig      # Core data types
│       ├── api_registry.zig   # Provider registry
│       ├── event_stream.zig   # Async event delivery
│       ├── http_client.zig    # HTTP + SSE
│       ├── json_parse.zig     # JSON parsing
│       └── providers/
│           └── openai.zig     # OpenAI implementation
├── test/
│   └── compare-json-parse.sh  # Comparison tests
└── docs/
    ├── 01-prd.md
    ├── 02-architecture.md
    └── 03-technical-spec.md
```

## 3. Module Responsibilities

### 3.1 types.zig
- **Purpose**: Define all data structures matching TypeScript interfaces
- **Key Types**: Model, Message, Context, StreamOptions, AssistantMessage, EventType
- **Constraints**: Must be binary-compatible with JSON serialization

### 3.2 api_registry.zig
- **Purpose**: Runtime provider registration and lookup
- **Pattern**: StringHashMap-based registry
- **Lifecycle**: Init → Register → Get → Clear

### 3.3 event_stream.zig
- **Purpose**: Producer-consumer queue for streaming events
- **Pattern**: Mutex-protected ArrayList with busy-wait polling
- **Thread Safety**: Single-producer, single-consumer

### 3.4 http_client.zig
- **Purpose**: HTTP requests with SSE stream parsing
- **Dependencies**: std.http.Client, std.Io.Threaded
- **Limitations**: Blocking I/O only (no async)

### 3.5 json_parse.zig
- **Purpose**: JSON parsing with partial fallback
- **Algorithm**: Try full parse → binary search for longest valid prefix
- **Output**: std.json.Value tree

### 3.6 providers/openai.zig
- **Purpose**: OpenAI API integration
- **Components**: Request builder, SSE parser, chunk handler
- **Future**: Add Anthropic, Google, etc.

## 4. Data Flow

```
User Input
    ↓
CLI Parser (main.zig)
    ↓
Provider Lookup (api_registry.zig)
    ↓
Request Building (providers/openai.zig)
    ↓
HTTP Request (http_client.zig)
    ↓
SSE Stream Parsing
    ↓
Event Stream Push (event_stream.zig)
    ↓
Consumer Loop
    ↓
Output Display
```

## 5. Interface Contracts

### 5.1 Provider Interface
```zig
const Provider = struct {
    api: []const u8,
    stream: *const fn (
        allocator: Allocator,
        model: Model,
        context: Context,
        options: ?StreamOptions,
    ) anyerror!void,
};
```

### 5.2 Event Stream Interface
```zig
const EventStream = struct {
    push: fn (event: AssistantMessageEvent) void,
    next: fn () ?AssistantMessageEvent,
    result: fn () ?AssistantMessage,
};
```

## 6. Error Handling Strategy

- **Allocator failures**: Propagate as error.OutOfMemory
- **HTTP errors**: Return error.HttpRequestFailed with status code
- **JSON parse errors**: Return partial parse or empty object
- **Network timeouts**: Retry with exponential backoff (Phase 2)

## 7. Testing Strategy

- **Unit tests**: Each module has inline tests
- **Integration tests**: Compare TS vs Zig output
- **Property tests**: Random JSON generation for parser (Phase 2)

## 8. Performance Considerations

- **Memory**: Use ArenaAllocator for request/response lifecycle
- **Zero-copy**: Slice into response buffer where possible
- **Buffer reuse**: Fixed-size buffers for SSE line parsing
