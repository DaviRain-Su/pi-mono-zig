const common = @import("../../common.zig");
pub const descriptor = common.descriptor("RuntimeMessageRouter", "components/sandbox/RuntimeMessageRouter.ts", .component);

pub fn isTrustedRuntimeMessageOrigin(origin: []const u8) bool {
    const std = @import("std");
    return std.mem.eql(u8, origin, "pi-webview://bundle");
}
