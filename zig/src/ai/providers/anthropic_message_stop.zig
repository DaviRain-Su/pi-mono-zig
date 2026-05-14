const std = @import("std");
const types = @import("../types.zig");
const stop_reason_mod = @import("../shared/stop_reason.zig");

pub fn mapStopReason(reason: []const u8) types.StopReason {
    return stop_reason_mod.mapStopReasonFromTable(&stop_reason_mod.anthropic_mappings, reason, .error_reason);
}

pub fn applyProviderStopReason(allocator: std.mem.Allocator, output: *types.AssistantMessage, reason: []const u8) !void {
    const mapped = mapStopReason(reason);
    output.stop_reason = mapped;
    if (mapped == .error_reason) {
        if (output.error_message) |existing| allocator.free(existing);
        output.error_message = try std.fmt.allocPrint(allocator, "Provider stop_reason: {s}", .{reason});
    } else if (output.error_message) |existing| {
        allocator.free(existing);
        output.error_message = null;
    }
}
