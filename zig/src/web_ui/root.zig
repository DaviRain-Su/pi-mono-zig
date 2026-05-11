pub const common = @import("common.zig");
pub const web_ui = @import("index.zig");

pub const ModuleDescriptor = common.ModuleDescriptor;
pub const RuntimeSurface = common.RuntimeSurface;

test {
    _ = common;
    _ = web_ui;
}
