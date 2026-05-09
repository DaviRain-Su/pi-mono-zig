const std = @import("std");
const dynamic_library = @import("native_dynamic_library.zig");
const native_runtime = @import("native_runtime.zig");

/// Cross-platform dynamic library wrapper for native extension loading.
/// Uses std.DynLib on supported platforms and a compile-safe unsupported
/// handle on build-only platforms such as Windows.
pub const DynamicLibraryHandle = dynamic_library.Handle;

pub const NativeLibrary = struct {
    dyn_lib: DynamicLibraryHandle,

    pub const Error = dynamic_library.Error;

    /// Open the shared library at `path`. The path must be absolute.
    pub fn open(path: []const u8) Error!NativeLibrary {
        return .{ .dyn_lib = try dynamic_library.open(path) };
    }

    /// Release the library handle.
    pub fn close(self: *NativeLibrary) void {
        self.dyn_lib.close();
    }

    /// Lookup the canonical `pi_extension_descriptor` symbol exported by
    /// the extension. Returns a pointer to a static NativeDescriptor.
    pub fn lookupDescriptor(self: *NativeLibrary) ?*const native_runtime.NativeDescriptor {
        return self.dyn_lib.lookup(*const native_runtime.NativeDescriptor, "pi_extension_descriptor");
    }

    /// Lookup the legacy `pi_extension_start` symbol exported by the
    /// extension. Returns the start function pointer if present.
    pub fn lookupStartFn(self: *NativeLibrary) ?native_runtime.NativeStartFn {
        return self.dyn_lib.lookup(native_runtime.NativeStartFn, "pi_extension_start");
    }
};

test "NativeLibrary open nonexistent returns error" {
    const expected_error = if (dynamic_library.supported)
        error.FileNotFound
    else
        error.UnsupportedNativeRuntimePlatform;
    try std.testing.expectError(expected_error, NativeLibrary.open("/nonexistent/library.so"));
}
