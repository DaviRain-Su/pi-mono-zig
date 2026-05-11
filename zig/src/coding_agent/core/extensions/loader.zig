pub const runtime = @import("../../extensions/extension_runtime.zig");
pub const manifest = @import("../../extensions/extension_manifest.zig");
pub const native_loader = @import("../../extensions/native_loader.zig");
pub const process_runtime_adapter = @import("../../extensions/process_runtime_adapter.zig");
pub const locked_wasm_runtime = @import("../../extensions/locked_wasm_runtime.zig");
pub const locked_native_runtime = @import("../../extensions/locked_native_runtime.zig");

pub const RuntimeHandle = runtime.RuntimeHandle;
pub const RuntimeSetupErrorEvent = runtime.RuntimeSetupErrorEvent;
pub const RuntimeSetupResult = runtime.RuntimeSetupResult;
pub const startRuntime = runtime.startRuntime;
pub const streamRuntimeSetup = runtime.streamRuntimeSetup;
pub const startRuntimeAdapter = runtime.startRuntimeAdapter;

test "extension loader facade exposes runtime setup entry points" {
    _ = startRuntime;
    _ = streamRuntimeSetup;
    _ = startRuntimeAdapter;
}
