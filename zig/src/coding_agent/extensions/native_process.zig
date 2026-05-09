const std = @import("std");

/// Options for spawning a child process from a native extension.
pub const ProcessOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
};

/// Result of waiting for a spawned process.
pub const ProcessResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: ProcessResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Spawn a child process and capture its stdout/stderr.
///
/// The caller owns the returned ProcessResult and must call deinit.
/// This is a synchronous/blocking operation suitable for tool execution
/// where the extension needs the full output before returning.
pub fn spawnAndCollect(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ProcessOptions,
) !ProcessResult {
    const run_result = try std.process.run(allocator, io, .{
        .argv = options.argv,
        .cwd = if (options.cwd) |path| .{ .path = path } else .inherit,
    });
    errdefer allocator.free(run_result.stdout);
    errdefer allocator.free(run_result.stderr);

    const exit_code: u8 = switch (run_result.term) {
        .exited => |code| code,
        .signal => |sig| @intCast(@intFromEnum(sig)),
        .stopped => |sig| @intCast(@intFromEnum(sig)),
        .unknown => |code| @intCast(code),
    };

    return .{
        .exit_code = exit_code,
        .stdout = run_result.stdout,
        .stderr = run_result.stderr,
    };
}
