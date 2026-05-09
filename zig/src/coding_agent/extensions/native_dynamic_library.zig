const std = @import("std");
const builtin = @import("builtin");

pub const supported = switch (builtin.os.tag) {
    .macos, .linux, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
    else => false,
};

const UnsupportedHandle = struct {
    pub fn close(_: *UnsupportedHandle) void {}

    pub fn lookup(_: *UnsupportedHandle, comptime T: type, _: []const u8) ?T {
        return null;
    }
};

pub const Handle = if (supported) std.DynLib else UnsupportedHandle;
pub const Error = if (supported) std.DynLib.Error else error{UnsupportedNativeRuntimePlatform};

pub fn open(path: []const u8) Error!Handle {
    if (supported) {
        return std.DynLib.open(path);
    }
    return error.UnsupportedNativeRuntimePlatform;
}

test "dynamic library handle is platform-gated" {
    if (supported) {
        try std.testing.expectError(error.FileNotFound, open("/nonexistent/library.so"));
    } else {
        try std.testing.expectError(error.UnsupportedNativeRuntimePlatform, open("/nonexistent/library.so"));
    }
}
