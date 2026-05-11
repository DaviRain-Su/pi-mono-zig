pub const protocol = @import("../../extensions/extension_protocol.zig");
pub const events = @import("../../extensions/extension_events.zig");
pub const flags = @import("../../extensions/extension_flags.zig");
pub const registry = @import("../../extensions/extension_registry.zig");
pub const runtime = @import("../../extensions/extension_runtime.zig");
pub const manifest = @import("../../extensions/extension_manifest.zig");
pub const readiness = @import("subagent_readiness.zig");

pub const ExtensionFrame = protocol.ExtensionFrame;
pub const ExtensionRequest = protocol.ExtensionRequest;
pub const ExtensionResponse = protocol.ExtensionResponse;
pub const ExtensionEvent = events.ExtensionEvent;
pub const ExtensionEventType = events.ExtensionEventType;
pub const EventBus = events.EventBus;
pub const Registry = registry.Registry;
pub const SubAgentReadinessEnvelopeKind = readiness.SubAgentReadinessEnvelopeKind;
pub const SubAgentReadinessValidation = readiness.SubAgentReadinessValidation;

test "extension type facade imports core runtime types" {
    _ = ExtensionEventType;
    _ = Registry;
    _ = SubAgentReadinessEnvelopeKind;
}
