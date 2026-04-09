const std = @import("std");

// Public exports for shared utilities
pub const EventStream = @import("event_stream.zig").EventStream;
pub const json_mod = @import("json.zig");

// Re-export common JSON helpers at root for convenience
pub const Value = json_mod.Value;
pub const ObjectMap = json_mod.ObjectMap;
pub const Array = json_mod.Array;
pub const parseValue = json_mod.parseValue;
pub const stringifyValue = json_mod.stringifyValue;

pub const HttpClient = @import("http.zig").HttpClient;

test "basic add" {
    const std_testing = @import("std").testing;
    try std_testing.expectEqual(3, 1 + 2);
}
