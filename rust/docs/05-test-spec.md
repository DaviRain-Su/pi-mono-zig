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
- `prompt_with_tools("bash: ...")` appends user, assistant tool-call, tool result, and final assistant messages.

### Boundary

- Empty prompt is accepted and passed through to provider.

### Error

- Provider error is propagated and user message remains recorded.

## `pi-session`

### Happy Path

- Appending messages writes JSONL entries that can be loaded back into `Message` values.
- Reopening a session continues sequence numbering.

### Boundary

- Missing session file loads as an empty transcript.

### Error

- Malformed JSONL returns an invalid-data IO error.

## `pi-tools`

### Happy Path

- Reading an existing file returns its contents.
- Running `printf hello` returns stdout and status `0`.
- Built-in tool definitions include Zig-reflected schemas.
- `execute_builtin_tool("read", json)` returns file contents.
- `execute_builtin_tool("bash", json)` returns formatted status/stdout/stderr.
- `execute_builtin_tool("write", json)` creates parent directories and writes content.
- `execute_builtin_tool("edit", json)` performs exact unique replacements.
- Tool execution uses `pi_zig_codegen::GeneratedToolArgs` rather than hand-written duplicate argument structs.

### Boundary

- Empty command returns shell failure or empty execution according to platform shell behavior.

### Error

- Missing file returns IO error.
- Unknown tool returns `UnknownTool`.
- Reflected but unimplemented tool returns `UnsupportedTool`.
- Edit with missing or duplicated `old_text` returns a typed replacement error.

## `pi-zig-codegen`

### Happy Path

- Zig codegen emits a Rust table containing `read`, `bash`, `edit`, and `write`.
- Zig comptime reflection emits Rust argument structs, nested parameter schemas, and the generated argument enum from typed parameter structs.
- Rust macro wrappers expose the generated count and names.

### Boundary

- Host codegen runs during `cargo test` without requiring final target execution.

### Error

- Zig codegen failure fails the Rust crate build.

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
- `pi-rs -p hello --session <path>` appends user and assistant entries.
- `pi-rs --list-zig-generated-tools` prints the Zig comptime generated registry.
- `pi-rs --list-zig-generated-tool-schemas` prints reflected JSON schemas.
- `pi-rs --list-tools` prints registry definitions and schemas.
- `pi-rs --tool bash '{"command":"printf hello"}'` executes through the registry.
- `pi-rs --tool-demo 'bash: printf hello'` exercises the agent tool loop.
- `pi-rs -p 'bash: printf hello' --provider tool-demo --session <path>` persists all tool-loop messages.

### Boundary

- `pi-rs --print ""` exits success.

### Error

- No print flag exits non-zero with usage text.
