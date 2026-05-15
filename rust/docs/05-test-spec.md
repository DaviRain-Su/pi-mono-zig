# Test Spec: Rust pi MVP

## `pi-ai`

### Happy Path

- Faux provider returns assistant message containing the latest user prompt.

### Boundary

- Empty message list returns provider error.

### Error

- Last message not user returns provider error.

## `pi-core`

### Happy Path

- `prompt("hello")` appends user and assistant messages.

### Boundary

- Empty prompt is accepted and passed through to provider.

### Error

- Provider error is propagated and user message remains recorded.

## `pi-tools`

### Happy Path

- Reading an existing file returns its contents.
- Running `printf hello` returns stdout and status `0`.

### Boundary

- Empty command returns shell failure or empty execution according to platform shell behavior.

### Error

- Missing file returns IO error.

## `pi-zig`

### Happy Path

- `fuzzy_filter("mn", ["main.rs", "lib.rs"])` returns `main.rs`.

### Boundary

- Empty query returns all items.
- Empty items returns empty matches.

### Error

- Invalid FFI result maps to `ZigError`.

## `pi-cli`

### Happy Path

- `pi-rs -p hello` prints faux assistant output.

### Boundary

- `pi-rs --print ""` exits success.

### Error

- No print flag exits non-zero with usage text.
