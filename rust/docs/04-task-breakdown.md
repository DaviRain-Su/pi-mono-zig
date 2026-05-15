# Task Breakdown: Rust pi MVP

## Task 1: Workspace and lifecycle docs

Type: Commit

- Create `rust/` workspace.
- Add lifecycle documents.
- Keep changes isolated from existing TS/Zig implementations.

## Task 2: Zig kernel and FFI crate

Type: Commit

- Add `rust/zig-kernel/build.zig`.
- Add `rust/zig-kernel/src/ffi.zig`.
- Add `pi-zig-sys` with `build.rs` and raw bindings.

## Task 3: Safe Zig wrapper

Type: Commit

- Add `pi-zig` crate.
- Implement `fuzzy_filter` safe API.
- Add wrapper tests.

## Task 4: Rust core and tools

Type: Commit

- Add `pi-ai` faux provider.
- Add `pi-core` session.
- Add `pi-tools` read/bash helpers.
- Add unit tests.

## Task 5: CLI MVP

Type: Commit

- Add `pi-cli` binary.
- Support `-p/--print`.
- Wire faux provider and session.
- Add CLI smoke test where practical.

## Task 6: Validation

Type: Commit

- Run `cargo test` from `rust/`.
- Run repository-required checks.
- Record limitations and next steps.
