# pi-mono-zig

A Zig 0.16 monorepo for AI agents, providers, and terminal UI utilities.

## Structure

| Directory | Description |
|-----------|-------------|
| `shared/` | Common utilities (HTTP client, JSON helpers, event stream primitives) |
| `ai/`     | AI provider registry, models, message transforms, validation |
| `agent/`  | Agent loop, proxy, and runtime types |
| `tui/`    | Terminal UI components |
| `coding-agent/` | CLI entry point (`pi`) |
| `mom/`    | Placeholder executable (`pi-mom`) |
| `pods/`   | Placeholder executable (`pi-pods`) |

## Build & Test

```bash
# Run all tests from the workspace root
zig build test

# Run integration tests
zig build test-ai
zig build test-anthropic

# Build the main CLI
zig build
./zig-out/bin/pi
```

Each sub-module can also be built independently:

```bash
cd shared && zig build test
cd ai     && zig build test
cd agent  && zig build test
```

## Critical API Lessons (Zig 0.16)

### 1. Never `defer parsed.deinit()` inside SSE loops
Using `std.json.parseFromSlice` + `defer deinit` in an SSE event loop frees memory
while string slices are still referenced by the `EventStream` queue, causing
segfaults.

**Always use the shared helpers:**

```zig
const shared = @import("shared");
const data = shared.http.parseSseData(line) orelse continue;
const chunk = shared.http.parseSseJsonLine(data, arena_gpa) catch continue;
```

`parseSseJsonLine` intentionally leaks the `std.json.Parsed` wrapper into the
arena and returns only the `std.json.Value`, eliminating the dangling-pointer
risk.

### 2. `SimpleStreamOptions` field access
`SimpleStreamOptions` is `{ base: StreamOptions, reasoning, thinking_budgets }`.
`streamSimple*` implementations must use `ai.simple_options.buildBaseOptions`
to obtain the real `StreamOptions`, not read `options.field` directly.

### 3. `std.json.ObjectMap` API changes
- `remove()` → `swapRemove()`
- `std.json.stringifyAlloc` is removed; use `std.fmt.allocPrint(gpa, "{f}", .{std.json.fmt(value, .{})})`

See [`LEARNINGS.md`](./LEARNINGS.md) for the full details.

## License

MIT
