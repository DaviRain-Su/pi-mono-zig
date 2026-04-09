const std = @import("std");
const types = @import("types.zig");

pub const ValidationError = error{
    MissingRequiredProperty,
    WrongType,
    UnknownProperty,
    ValidationFailed,
};

/// Validates that `arguments` conforms to the JSON schema represented by `tool.parameters`.
/// This is a minimal implementation supporting:
/// - object root with required/properties
/// - string, number, integer, boolean, array, object types
/// - minLength, maxLength, minimum, maximum, minItems, maxItems
/// - optional properties
pub fn validateToolArguments(tool: types.Tool, arguments: std.json.Value) ValidationError!void {
    const schema = tool.parameters;
    if (schema != .object) return error.ValidationFailed;
    const schema_obj = schema.object;

    // Must be object
    if (arguments != .object) return error.WrongType;
    const args_obj = arguments.object;

    const required = schema_obj.get("required") orelse null;
    const properties = schema_obj.get("properties") orelse null;

    if (required) |req| {
        if (req != .array) return error.ValidationFailed;
        for (req.array.items) |item| {
            if (item != .string) return error.ValidationFailed;
            if (!args_obj.contains(item.string)) return error.MissingRequiredProperty;
        }
    }

    if (properties) |props| {
        if (props != .object) return error.ValidationFailed;
        var it = args_obj.iterator();
        while (it.next()) |entry| {
            const prop_schema = props.object.get(entry.key_ptr.*) orelse {
                // if additionalProperties is false, reject unknown keys
                const additional = schema_obj.get("additionalProperties") orelse null;
                if (additional) |ap| {
                    if (ap == .bool and !ap.bool) return error.UnknownProperty;
                }
                continue;
            };
            try validateValue(entry.value_ptr.*, prop_schema);
        }
    }
}

fn validateValue(value: std.json.Value, schema: std.json.Value) ValidationError!void {
    if (schema != .object) return;
    const schema_obj = schema.object;
    const type_val = schema_obj.get("type") orelse return;
    if (type_val != .string) return error.ValidationFailed;
    const t = type_val.string;

    const valid = switch (value) {
        .string => std.mem.eql(u8, t, "string"),
        .float, .integer => std.mem.eql(u8, t, "number") or std.mem.eql(u8, t, "integer"),
        .bool => std.mem.eql(u8, t, "boolean"),
        .array => std.mem.eql(u8, t, "array"),
        .object => std.mem.eql(u8, t, "object"),
        .null => std.mem.eql(u8, t, "null"),
        else => false,
    };
    if (!valid) return error.WrongType;

    // integer check
    if (std.mem.eql(u8, t, "integer") and value == .float) {
        const f = value.float;
        if (@ceil(f) != f) return error.WrongType;
    }

    // string constraints
    if (value == .string) {
        if (schema_obj.get("minLength")) |min_len| {
            if (min_len == .integer and value.string.len < @as(usize, @intCast(min_len.integer))) return error.ValidationFailed;
            if (min_len == .float and value.string.len < @as(usize, @intFromFloat(min_len.float))) return error.ValidationFailed;
        }
        if (schema_obj.get("maxLength")) |max_len| {
            if (max_len == .integer and value.string.len > @as(usize, @intCast(max_len.integer))) return error.ValidationFailed;
            if (max_len == .float and value.string.len > @as(usize, @intFromFloat(max_len.float))) return error.ValidationFailed;
        }
    }

    // number constraints
    if (value == .float or value == .integer) {
        const f = if (value == .float) value.float else @as(f64, @floatFromInt(value.integer));
        if (schema_obj.get("minimum")) |min_v| {
            const min_f = if (min_v == .float) min_v.float else @as(f64, @floatFromInt(min_v.integer));
            if (f < min_f) return error.ValidationFailed;
        }
        if (schema_obj.get("maximum")) |max_v| {
            const max_f = if (max_v == .float) max_v.float else @as(f64, @floatFromInt(max_v.integer));
            if (f > max_f) return error.ValidationFailed;
        }
    }

    // array constraints
    if (value == .array) {
        if (schema_obj.get("minItems")) |min_items| {
            const mi = if (min_items == .integer) @as(usize, @intCast(min_items.integer)) else @as(usize, @intFromFloat(min_items.float));
            if (value.array.items.len < mi) return error.ValidationFailed;
        }
        if (schema_obj.get("maxItems")) |max_items| {
            const ma = if (max_items == .integer) @as(usize, @intCast(max_items.integer)) else @as(usize, @intFromFloat(max_items.float));
            if (value.array.items.len > ma) return error.ValidationFailed;
        }
        const item_schema = schema_obj.get("items") orelse null;
        if (item_schema) |is| {
            for (value.array.items) |item| {
                try validateValue(item, is);
            }
        }
    }

    // object recursive constraints
    if (value == .object) {
        var it = value.object.iterator();
        while (it.next()) |entry| {
            const props = schema_obj.get("properties") orelse continue;
            if (props != .object) continue;
            const prop_schema = props.object.get(entry.key_ptr.*) orelse continue;
            try validateValue(entry.value_ptr.*, prop_schema);
        }
    }
}

test "validateToolArguments basic object validation" {
    const gpa = std.heap.page_allocator;
    var schema = std.json.ObjectMap.init(gpa);
    try schema.put("type", .{ .string = "object" });
    var required = std.ArrayList(std.json.Value).init(gpa);
    try required.append(.{ .string = "name" });
    try schema.put("required", .{ .array = .{ .items = required, .capacity = required.items.len } });
    var properties = std.json.ObjectMap.init(gpa);
    var name_schema = std.json.ObjectMap.init(gpa);
    try name_schema.put("type", .{ .string = "string" });
    try properties.put("name", .{ .object = name_schema });
    try schema.put("properties", .{ .object = properties });

    const tool = types.Tool{ .name = "TestTool", .description = "D", .parameters = .{ .object = schema } };

    var valid_args = std.json.ObjectMap.init(gpa);
    try valid_args.put("name", .{ .string = "Alice" });
    try validateToolArguments(tool, .{ .object = valid_args });

    var invalid_args = std.json.ObjectMap.init(gpa);
    try invalid_args.put("age", .{ .integer = 30 });
    const result = validateToolArguments(tool, .{ .object = invalid_args });
    try std.testing.expectError(error.MissingRequiredProperty, result);
}

test "validateToolArguments string length constraints" {
    const gpa = std.heap.page_allocator;
    var schema = std.json.ObjectMap.init(gpa);
    try schema.put("type", .{ .string = "object" });
    var properties = std.json.ObjectMap.init(gpa);
    var s_schema = std.json.ObjectMap.init(gpa);
    try s_schema.put("type", .{ .string = "string" });
    try s_schema.put("minLength", .{ .integer = 2 });
    try s_schema.put("maxLength", .{ .integer = 5 });
    try properties.put("code", .{ .object = s_schema });
    try schema.put("properties", .{ .object = properties });

    const tool = types.Tool{ .name = "TestTool", .description = "D", .parameters = .{ .object = schema } };

    var args = std.json.ObjectMap.init(gpa);
    try args.put("code", .{ .string = "AB" });
    try validateToolArguments(tool, .{ .object = args });

    var args2 = std.json.ObjectMap.init(gpa);
    try args2.put("code", .{ .string = "ABCDEF" });
    const result = validateToolArguments(tool, .{ .object = args2 });
    try std.testing.expectError(error.ValidationFailed, result);
}

test "validateToolArguments number range" {
    const gpa = std.heap.page_allocator;
    var schema = std.json.ObjectMap.init(gpa);
    try schema.put("type", .{ .string = "object" });
    var properties = std.json.ObjectMap.init(gpa);
    var n_schema = std.json.ObjectMap.init(gpa);
    try n_schema.put("type", .{ .string = "integer" });
    try n_schema.put("minimum", .{ .integer = 0 });
    try n_schema.put("maximum", .{ .integer = 10 });
    try properties.put("count", .{ .object = n_schema });
    try schema.put("properties", .{ .object = properties });

    const tool = types.Tool{ .name = "TestTool", .description = "D", .parameters = .{ .object = schema } };

    var args = std.json.ObjectMap.init(gpa);
    try args.put("count", .{ .integer = 5 });
    try validateToolArguments(tool, .{ .object = args });

    var args2 = std.json.ObjectMap.init(gpa);
    try args2.put("count", .{ .integer = 11 });
    const result = validateToolArguments(tool, .{ .object = args2 });
    try std.testing.expectError(error.ValidationFailed, result);
}
