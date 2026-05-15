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
cargo run -p pi-cli -- -p "hello" --session /tmp/pi-rs-session.jsonl
```

## Cross compilation

`pi-zig-sys` compiles `zig-kernel` from `build.rs`, then Rust links the generated static library. Use `cargo-zigbuild` for final target linking once the desired target toolchain is installed:

```bash
cd rust
cargo zigbuild --target x86_64-unknown-linux-gnu
```
