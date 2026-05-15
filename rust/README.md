# pi-rs MVP

Experimental Rust implementation of pi using Rust for the application/runtime layer and a small Zig kernel for native hot-path helpers.

## Build

```bash
cd rust
cargo build
```

## Test

```bash
cd rust
cargo test
```

## Run

```bash
cd rust
cargo run -p pi-cli -- -p "hello"
cargo run -p pi-cli -- -p "bash: printf hello" --provider tool-demo --session /tmp/pi-rs-session.jsonl
cargo run -p pi-cli -- --continue --session /tmp/pi-rs-session.jsonl --provider tool-demo
cargo run -p pi-cli -- --list-zig-generated-tools
cargo run -p pi-cli -- --list-zig-generated-tool-schemas
cargo run -p pi-cli -- --list-tools
cargo run -p pi-cli -- --tool bash '{"command":"printf hello"}'
cargo run -p pi-cli -- --tool-demo 'bash: printf hello-from-loop'
printf '%s\n' \
  '{"type":"new_session","path":"/tmp/pi-rs-rpc.jsonl"}' \
  '{"id":"1","type":"prompt","provider":"tool-demo","message":"bash: printf rpc"}' \
  '{"id":"2","type":"get_state"}' \
  | cargo run -p pi-cli -- --mode rpc
# RPC prompt writes the response first, followed by message/tool lifecycle event lines.
```

## Cross compilation

`pi-zig-sys` compiles `zig-kernel` from `build.rs`, then Rust links the generated static library. `pi-zig-codegen` also runs a host Zig program that uses `comptime` reflection over typed Zig parameter structs to generate Rust structs, enums, parsers, and schemas under Cargo `OUT_DIR`; Rust consumes those generated types directly.

Use `cargo-zigbuild` for final target linking once the desired target toolchain is installed:

```bash
cd rust
cargo zigbuild --target x86_64-unknown-linux-gnu
```
