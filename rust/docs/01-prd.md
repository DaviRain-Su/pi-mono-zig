# PRD: Rust pi MVP

Date: 2026-05-15
Branch: zig-implementation
Commit: ee3cd1d3

## Goal

Create a minimal Rust implementation of pi that proves the Rust + Zig collaboration model:

- Rust owns the application/runtime layer.
- Zig owns a small native kernel compiled as a static library.
- Rust calls Zig through a narrow safe wrapper.
- `cargo` and `cargo-zigbuild` can build the Rust binary while `build.rs` compiles and links the Zig kernel.

## In Scope

- New `rust/` workspace isolated from existing TypeScript and Zig implementations.
- `pi-cli` binary with print mode: `pi-rs -p "message"`.
- Faux provider that streams a deterministic assistant response.
- Basic in-memory agent loop.
- Built-in `read` and `bash` tool implementations as library APIs.
- Zig FFI module for batched fuzzy filtering.
- Safe Rust wrapper around the Zig FFI boundary.
- Unit tests for Rust core/tool/Zig wrapper behavior.

## Out of Scope

- Full interactive TUI.
- Real LLM providers.
- Session persistence.
- Extension host.
- Procedural macros implemented in Zig.
- Replacing the existing TypeScript or Zig implementations.

## Users

- pi maintainers evaluating a Rust-native runtime direction.
- Future implementation agents needing a stable skeleton for incremental porting.

## Success Criteria

- `cd rust && cargo test` passes.
- `cd rust && cargo run -p pi-cli -- -p "hello"` prints a deterministic assistant response.
- The Rust binary links a Zig-built static library through `pi-zig-sys`.
- FFI ownership is explicit: Zig allocations are freed through Rust `Drop`.
