comptime {
    _ = @import("tests/local_paths.zig");
    _ = @import("tests/wasm_policy.zig");
    _ = @import("tests/native_dynamic.zig");
    _ = @import("tests/npm_sources.zig");
    _ = @import("tests/self_update.zig");
    _ = @import("tests/update_flags.zig");
    _ = @import("tests/config_selector.zig");
}
