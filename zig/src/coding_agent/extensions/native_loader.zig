const std = @import("std");
const native_runtime = @import("native_runtime.zig");
const builtin = @import("builtin");

/// Cross-platform dynamic library wrapper for native extension loading.
/// Uses std.DynLib (POSIX dlopen / Windows LoadLibrary) under the hood.
/// On Windows, std.DynLib is not supported in Zig 0.16, so we provide a stub.
pub const NativeLibrary = if (builtin.os.tag == .windows) struct {
    pub const Error = error{ UnsupportedPlatform, FileNotFound };

    pub fn open(_: []const u8) Error!NativeLibrary {
        return error.UnsupportedPlatform;
    }

    pub fn close(_: *NativeLibrary) void {}

    pub fn lookupDescriptor(_: *NativeLibrary) ?*const native_runtime.NativeDescriptor {
        return null;
    }

    pub fn lookupStartFn(_: *NativeLibrary) ?native_runtime.NativeStartFn {
        return null;
    }
} else struct {
    dyn_lib: std.DynLib,

    pub const Error = std.DynLib.Error;

    /// Open the shared library at `path`. The path must be absolute.
    pub fn open(path: []const u8) Error!NativeLibrary {
        return .{ .dyn_lib = try std.DynLib.open(path) };
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
    if (builtin.os.tag == .windows) {
        try std.testing.expectError(error.UnsupportedPlatform, NativeLibrary.open("/nonexistent/library.so"));
    } else {
        try std.testing.expectError(error.FileNotFound, NativeLibrary.open("/nonexistent/library.so"));
    }
}
