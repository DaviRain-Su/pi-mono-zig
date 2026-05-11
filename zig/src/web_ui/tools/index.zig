pub const artifacts = @import("artifacts/index.zig");
pub const extract_document = @import("extract_document.zig");
pub const javascript_repl = @import("javascript_repl.zig");
pub const renderer_registry = @import("renderer_registry.zig");
pub const types = @import("types.zig");
pub const renderers = struct {
    pub const BashRenderer = @import("renderers/BashRenderer.zig");
    pub const CalculateRenderer = @import("renderers/CalculateRenderer.zig");
    pub const DefaultRenderer = @import("renderers/DefaultRenderer.zig");
    pub const GetCurrentTimeRenderer = @import("renderers/GetCurrentTimeRenderer.zig");
};

test {
    _ = artifacts;
    _ = extract_document;
    _ = javascript_repl;
    _ = renderer_registry;
    _ = types;
    _ = renderers.BashRenderer;
}
