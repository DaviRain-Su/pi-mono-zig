const common = @import("../common.zig");
pub const descriptor = common.descriptor("types", "tools/types.ts", .tool);

pub const ToolRenderStatus = enum {
    pending,
    running,
    complete,
    @"error",
};
