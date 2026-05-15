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
