# pi (Zig Implementation)

Native Zig implementation of the pi coding agent.

## Prerequisites

- Zig 0.16.x
- ripgrep (`rg`) - for the grep tool
- `fd` - for the find tool

Install on macOS:
```bash
brew install ripgrep fd
```

## Build

```bash
cd zig
zig build
```

The binary is installed to `zig-out/bin/pi`.

## Run

```bash
# Interactive mode
./zig-out/bin/pi

# Print mode
./zig-out/bin/pi -p "your prompt"

# With specific model
./zig-out/bin/pi --model anthropic/claude-sonnet-4-20250514 "your prompt"
```

## Development

```bash
cd zig
zig build -Doptimize=Debug  # Debug build
zig build -Doptimize=ReleaseSmall  # Optimized release build
zig build test             # Run tests
zig build run             # Build and run
```

## Testing

```bash
cd zig
zig build test           # Run unit tests

# Run specific parity tests
zig build test-ts-rpc-parity
zig build test-openai-chat-parity
zig build test-openai-responses-parity
```

## Release Process

1. **Build release binary:**
   ```bash
   zig build -Doptimize=ReleaseSmall
   ```

2. **Verify binary works:**
   ```bash
   ./zig-out/bin/pi --version
   ```

3. **Create distribution archive:**
   ```bash
   tar -czf pi-x.x.x-macos-arm64.tar.gz -C zig-out bin/pi
   ```

The release binary will be at `zig-out/bin/pi`.