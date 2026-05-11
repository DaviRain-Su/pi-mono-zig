const std = @import("std");
const common = @import("common.zig");

/// Validation constraint applied to integer fields parsed from JSON.
/// Tools can override the default (`.non_negative`) per-field via
/// `pub const json_int_constraints = .{ .field_name = .positive };`.
pub const IntConstraint = enum {
    /// Accept any non-negative integer that fits in the field type.
    non_negative,
    /// Require the integer to be strictly greater than zero.
    positive,
};

/// Comptime, reflection-driven JSON-to-Args parser shared by all built-in tools.
///
/// Supported field types: `[]const u8`, `bool`, signed/unsigned integers,
/// and `?T` of any of those. Required fields are bare (no default); optional
/// fields are either `?T` or carry a default value in the struct declaration.
///
/// Per-field metadata declared as struct decls on `T` (optional):
///   * `pub const json_aliases = .{ .field_name = .{ "alias1", "alias2", ... } };`
///     The first alias that resolves in the JSON object wins.
///   * `pub const json_int_constraints = .{ .field_name = .positive };`
pub fn parseArgsFromJson(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !T {
    _ = allocator; // borrowed strings reference the JSON tree; reserved for future use
    if (value != .object) return error.InvalidToolArguments;
    const object = value.object;

    const fields = @typeInfo(T).@"struct".fields;
    var result: T = undefined;
    inline for (fields) |field| {
        const FieldT = field.type;
        const constraint = comptime fieldIntConstraint(T, field.name);

        var raw: ?std.json.Value = null;
        if (comptime hasAliasDecl(T, field.name)) {
            const aliases_tuple = @field(T.json_aliases, field.name);
            inline for (@typeInfo(@TypeOf(aliases_tuple)).@"struct".fields) |alias_f| {
                if (raw == null) {
                    const alias_value = @field(aliases_tuple, alias_f.name);
                    if (object.get(alias_value)) |v| {
                        if (v != .null) raw = v;
                    }
                }
            }
        } else if (object.get(field.name)) |v| {
            if (v != .null) raw = v;
        }

        if (raw) |raw_val| {
            @field(result, field.name) = try extractField(FieldT, raw_val, constraint);
        } else if (comptime field.defaultValue() != null) {
            @field(result, field.name) = comptime field.defaultValue().?;
        } else if (comptime @typeInfo(FieldT) == .optional) {
            @field(result, field.name) = null;
        } else {
            return error.InvalidToolArguments;
        }
    }
    return result;
}

fn hasAliasDecl(comptime T: type, comptime name: [:0]const u8) bool {
    if (!@hasDecl(T, "json_aliases")) return false;
    return @hasField(@TypeOf(T.json_aliases), name);
}

fn fieldIntConstraint(comptime T: type, comptime name: [:0]const u8) IntConstraint {
    if (!@hasDecl(T, "json_int_constraints")) return .non_negative;
    const decls = T.json_int_constraints;
    if (!@hasField(@TypeOf(decls), name)) return .non_negative;
    return @field(decls, name);
}

fn extractField(comptime FieldT: type, value: std.json.Value, constraint: IntConstraint) !FieldT {
    switch (@typeInfo(FieldT)) {
        .optional => |opt| return try extractField(opt.child, value, constraint),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                if (value != .string) return error.InvalidToolArguments;
                return value.string;
            }
            @compileError("parseArgsFromJson: unsupported pointer field type " ++ @typeName(FieldT));
        },
        .bool => {
            if (value != .bool) return error.InvalidToolArguments;
            return value.bool;
        },
        .int => {
            if (value != .integer) return error.InvalidToolArguments;
            switch (constraint) {
                .positive => if (value.integer <= 0) return error.InvalidToolArguments,
                .non_negative => if (value.integer < 0) return error.InvalidToolArguments,
            }
            return std.math.cast(FieldT, value.integer) orelse error.InvalidToolArguments;
        },
        else => @compileError("parseArgsFromJson: unsupported field type " ++ @typeName(FieldT)),
    }
}

// ---- Tests ----

fn putString(object: *std.json.ObjectMap, key: []const u8, val: []const u8) !void {
    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, key), .{ .string = try std.testing.allocator.dupe(u8, val) });
}

fn putBool(object: *std.json.ObjectMap, key: []const u8, val: bool) !void {
    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, key), .{ .bool = val });
}

fn putInt(object: *std.json.ObjectMap, key: []const u8, val: i64) !void {
    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, key), .{ .integer = val });
}

fn freeObject(object: std.json.ObjectMap) void {
    const value = std.json.Value{ .object = object };
    common.deinitJsonValue(std.testing.allocator, value);
}

test "parseArgsFromJson required string + optional positive integers" {
    const Args = struct {
        path: []const u8,
        offset: ?usize = null,
        limit: ?usize = null,

        pub const json_int_constraints = .{
            .offset = .positive,
            .limit = .positive,
        };
    };

    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    try putString(&object, "path", "file.txt");
    try putInt(&object, "limit", 5);
    defer freeObject(object);

    const parsed = try parseArgsFromJson(Args, std.testing.allocator, .{ .object = object });
    try std.testing.expectEqualStrings("file.txt", parsed.path);
    try std.testing.expectEqual(@as(?usize, null), parsed.offset);
    try std.testing.expectEqual(@as(?usize, 5), parsed.limit);
}

test "parseArgsFromJson rejects missing required field" {
    const Args = struct { path: []const u8 };
    const object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    defer freeObject(object);
    try std.testing.expectError(error.InvalidToolArguments, parseArgsFromJson(Args, std.testing.allocator, .{ .object = object }));
}

test "parseArgsFromJson rejects non-positive integer when constraint is .positive" {
    const Args = struct {
        offset: ?usize = null,
        pub const json_int_constraints = .{ .offset = .positive };
    };
    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    try putInt(&object, "offset", 0);
    defer freeObject(object);
    try std.testing.expectError(error.InvalidToolArguments, parseArgsFromJson(Args, std.testing.allocator, .{ .object = object }));
}

test "parseArgsFromJson rejects negative integer" {
    const Args = struct {
        context: usize = 0,
    };
    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    try putInt(&object, "context", -1);
    defer freeObject(object);
    try std.testing.expectError(error.InvalidToolArguments, parseArgsFromJson(Args, std.testing.allocator, .{ .object = object }));
}

test "parseArgsFromJson resolves aliases in declaration order" {
    const Args = struct {
        glob: ?[]const u8 = null,
        ignore_case: bool = false,

        pub const json_aliases = .{
            .glob = .{ "glob", "glob_pattern" },
            .ignore_case = .{ "ignoreCase", "ignore_case" },
        };
    };

    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    try putString(&object, "glob_pattern", "*.zig");
    try putBool(&object, "ignoreCase", true);
    defer freeObject(object);

    const parsed = try parseArgsFromJson(Args, std.testing.allocator, .{ .object = object });
    try std.testing.expectEqualStrings("*.zig", parsed.glob.?);
    try std.testing.expectEqual(true, parsed.ignore_case);
}

test "parseArgsFromJson alias resolves first match" {
    const Args = struct {
        glob: ?[]const u8 = null,
        pub const json_aliases = .{ .glob = .{ "glob", "glob_pattern" } };
    };
    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    try putString(&object, "glob", "first");
    try putString(&object, "glob_pattern", "second");
    defer freeObject(object);

    const parsed = try parseArgsFromJson(Args, std.testing.allocator, .{ .object = object });
    try std.testing.expectEqualStrings("first", parsed.glob.?);
}

test "parseArgsFromJson rejects non-object input" {
    const Args = struct { path: []const u8 };
    try std.testing.expectError(error.InvalidToolArguments, parseArgsFromJson(Args, std.testing.allocator, .{ .integer = 1 }));
}

test "parseArgsFromJson rejects type mismatch" {
    const Args = struct { path: []const u8 };
    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    defer freeObject(object);
    try putInt(&object, "path", 42);
    try std.testing.expectError(error.InvalidToolArguments, parseArgsFromJson(Args, std.testing.allocator, .{ .object = object }));
}
