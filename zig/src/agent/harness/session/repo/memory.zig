const shared = @import("shared.zig");

pub const MemorySessionRepo = struct {
    sessions: []const shared.SessionRecord = &.{},
};
