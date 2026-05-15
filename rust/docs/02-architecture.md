# Architecture: Rust pi MVP

## System Shape

```text
pi-cli
  -> pi-core
      -> pi-ai faux provider
      -> pi-tools
  -> pi-zig
      -> pi-zig-sys
          -> zig-kernel static library
```

## Crates

### `pi-cli`

CLI entry point. Parses minimal arguments and dispatches print mode.

### `pi-core`

Owns the minimal agent session abstraction. For MVP, a session accepts one user prompt and asks the configured provider for a response.

### `pi-ai`

Defines provider traits and a faux provider. Real providers are deferred.

### `pi-tools`

Provides Rust-native built-in tools. MVP includes `read_file` and `run_bash` APIs.

### `pi-zig-sys`

Unsafe FFI bindings and build integration. Its `build.rs` calls `zig build` in `zig-kernel/`, then emits Cargo link metadata.

### `pi-zig`

Safe wrapper over `pi-zig-sys`. Owns every Zig allocation via RAII and exposes typed Rust functions.

### `pi-zig-codegen`

Macro-style code generation bridge. Its `build.rs` runs the host Zig program in `zig-codegen/`; Zig uses `comptime` tool descriptors to emit Rust source into Cargo `OUT_DIR`. Rust exposes a small `macro_rules!` shell over the generated table.

### `zig-kernel`

Small Zig static library. Exports only C ABI functions. MVP exports batched fuzzy filtering plus buffer cleanup.

### `zig-codegen`

Host-only Zig code generation programs. These do not link into the final binary; they run at Rust compile time to generate Rust source from Zig `comptime` data.

## FFI Rules

- Zig exports stay small and stable.
- Calls are batch-oriented, not per-item.
- Any pointer returned by Zig is freed by a paired Zig free function.
- Rust safe wrappers hide all raw pointers.
- FFI payloads use UTF-8 JSON bytes for MVP simplicity.

## Build Flow

```text
cargo build / cargo zigbuild
  -> pi-zig-sys/build.rs
      -> zig build -Dtarget=<mapped target>
      -> libpi_zig_kernel.a
  -> pi-zig-codegen/build.rs
      -> zig run zig-codegen/tool_registry.zig
      -> OUT_DIR/zig_tools.rs
  -> rustc links static pi_zig_kernel and includes generated Rust source
```

## Future Expansion

- Add streaming provider abstraction.
- Port session JSONL tree.
- Port RPC mode.
- Port TUI after core/session semantics are stable.
- Move additional hot-path modules into Zig only when profiling justifies it.
