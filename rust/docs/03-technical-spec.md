# Technical Spec: Rust pi MVP

## Data Structures

### `pi_ai::Message`

```rust
pub struct Message {
    pub role: Role,
    pub content: String,
}

pub enum Role {
    User,
    Assistant,
    Tool,
}
```

Constraints:

- `content` must be valid UTF-8.
- MVP stores plain text only.

### `pi_ai::Provider`

```rust
pub trait Provider {
    fn complete(&self, messages: &[Message]) -> Result<Message, ProviderError>;
}
```

Preconditions:

- `messages` contains at least one user message.

Postconditions:

- Returns an assistant message or a typed error.

### `pi_core::AgentSession`

```rust
pub struct AgentSession<P: Provider> {
    provider: P,
    messages: Vec<Message>,
}
```

### `pi_session::SessionEntry`

```rust
pub struct SessionEntry {
    pub sequence: u64,
    pub timestamp_ms: u128,
    pub message: Message,
}
```

Persistence format:

- UTF-8 JSONL.
- One `SessionEntry` per line.
- `sequence` is monotonically increasing per file.

State machine:

```text
Idle + prompt(text) -> Running -> Idle
```

Side effects:

- Appends user message before provider call.
- Appends assistant message after successful provider call.

### `pi_zig::FuzzyItem`

```rust
pub struct FuzzyItem {
    pub id: String,
    pub text: String,
}
```

### `pi_zig::FuzzyMatch`

```rust
pub struct FuzzyMatch {
    pub id: String,
    pub score: u32,
}
```

Ordering:

- Higher `score` first.
- Stable enough for MVP deterministic tests.

### `pi_zig_codegen` generated table

Zig source of truth:

```zig
const EditBlock = struct {
    old_text: []const u8,
    new_text: []const u8,

    pub const json_field_docs = .{
        .old_text = "Exact text to replace.",
        .new_text = "Replacement text.",
    };
};

const EditParams = struct {
    path: []const u8,
    edits: []const EditBlock,

    pub const json_field_docs = .{
        .path = "File path to edit.",
        .edits = "Batch of exact text replacements.",
    };
};

const generated_tools = [_]GeneratedTool{
    .{ .name = "edit", .label = "Edit File", .mutates = true, .Params = EditParams },
};
```

Zig reflects `Params` with `@typeInfo(T).@"struct".fields`, unwraps optionals, detects slice-of-struct nested arrays, and emits both Rust metadata and JSON schema. Missing `json_field_docs` is a compile error.

Rust generated shape:

```rust
pub const ZIG_GENERATED_TOOL_COUNT: usize = 4;
pub const ZIG_GENERATED_TOOL_NAMES: &[&str] = &["read", "bash", "edit", "write"];
pub const ZIG_GENERATED_TOOLS: &[GeneratedTool] = &[/* includes reflected parameters_json */];
```

Rust macro shell:

```rust
pi_zig_codegen::zig_generated_tool_names!()
pi_zig_codegen::zig_generated_tool_count!()
```

## Zig FFI Interface

```zig
export fn pi_fuzzy_filter_batch(
    query_ptr: [*]const u8,
    query_len: usize,
    items_json_ptr: [*]const u8,
    items_json_len: usize,
    out_len: *usize,
) ?[*]u8;

export fn pi_zig_free(ptr: ?[*]u8, len: usize) void;
```

Input JSON:

```json
[{"id":"file-1","text":"src/main.rs"}]
```

Output JSON:

```json
[{"id":"file-1","score":7}]
```

Error behavior:

- Invalid UTF-8 or invalid JSON returns null and sets `out_len` to `0`.
- Allocation failure returns null and sets `out_len` to `0`.

## Constants

- `FUZZY_MATCH_BONUS`: `2`
- `FUZZY_CASE_INSENSITIVE`: `true`

## Algorithms

### Fuzzy scoring

For every item:

1. Lowercase query and text.
2. Walk query chars in order.
3. Find each char in text after the previous match.
4. If all chars match, score = query length + contiguous adjacency bonuses.
5. Exclude non-matching items.
6. Sort by descending score.

### Zig comptime Rust codegen

At Cargo build time:

1. `pi-zig-codegen/build.rs` invokes `zig run rust/zig-codegen/tool_registry.zig`.
2. Zig validates and iterates `generated_tools` with `inline for`.
3. For each tool's `Params` type, Zig uses `@typeInfo` reflection to walk fields, required/default state, optionals, and nested structs.
4. Zig prints Rust source and reflected JSON schemas to stdout.
5. `build.rs` writes stdout to `OUT_DIR/zig_tools.rs`.
6. `pi-zig-codegen` includes that file and exposes macro-style Rust APIs.

## Boundary Cases

1. Empty query returns all items with score `0`.
2. Empty item list returns `[]`.
3. Non-matching query returns `[]`.
4. Unicode input must not crash.
5. Invalid JSON returns an FFI error.
6. Zig null pointer maps to Rust error.
7. Zig allocated output always frees through `Drop`.
8. Bash non-zero exit returns captured output and status.
9. Read missing file returns typed IO error.
10. CLI without `-p` returns usage error for MVP.
11. Missing session file loads as an empty transcript.
12. Existing session file appends only newly generated messages.
13. Zig comptime generated tool names are available through Rust macro wrappers.
14. Codegen runs on the host and is not linked into the final binary.
