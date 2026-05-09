const std = @import("std");

/// Returns true when `path` is within `root`, disallowing path traversal
/// via `..`, `.`, or empty components. Both paths must use the platform's
/// native path separator.
pub fn isPathWithinSandbox(root: []const u8, path: []const u8) bool {
    if (root.len == 0) return false;
    if (std.mem.eql(u8, root, path)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    const suffix_start = if (root[root.len - 1] == std.fs.path.sep)
        root.len
    else blk: {
        if (path.len <= root.len or path[root.len] != std.fs.path.sep) return false;
        break :blk root.len + 1;
    };
    return isSafeRelativePathSuffix(path[suffix_start..]);
}

fn isSafeRelativePathSuffix(suffix: []const u8) bool {
    var components = std.mem.splitScalar(u8, suffix, std.fs.path.sep);
    while (components.next()) |component| {
        if (component.len == 0) return false;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

test "isPathWithinSandbox accepts direct match and children" {
    try std.testing.expect(isPathWithinSandbox("/tmp/native-sandbox", "/tmp/native-sandbox"));
    try std.testing.expect(isPathWithinSandbox("/tmp/native-sandbox", "/tmp/native-sandbox/read.txt"));
    try std.testing.expect(isPathWithinSandbox("/tmp/native-sandbox/", "/tmp/native-sandbox/read.txt"));
}

test "isPathWithinSandbox rejects traversal and siblings" {
    try std.testing.expect(!isPathWithinSandbox("/tmp/native-sandbox", "/tmp/native-sandbox/../outside.txt"));
    try std.testing.expect(!isPathWithinSandbox("/tmp/native-sandbox", "/tmp/native-sandbox/sub/../../outside.txt"));
    try std.testing.expect(!isPathWithinSandbox("/tmp/native-sandbox", "/tmp/native-sandbox/./inside.txt"));
    try std.testing.expect(!isPathWithinSandbox("/tmp/native-sandbox", "/tmp/native-sandbox-sibling/read.txt"));
    try std.testing.expect(!isPathWithinSandbox("", "/tmp/native-sandbox/read.txt"));
}
