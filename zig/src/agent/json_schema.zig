const std = @import("std");

pub const SchemaValidationIssue = struct {
    code: []const u8,
    message: []const u8,
    path: []const u8,

    pub fn deinit(self: SchemaValidationIssue, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.message);
        allocator.free(self.path);
    }
};

pub fn validateToolArguments(
    allocator: std.mem.Allocator,
    schema: std.json.Value,
    args: std.json.Value,
) std.mem.Allocator.Error!?SchemaValidationIssue {
    var path = std.ArrayList(u8).empty;
    defer path.deinit(allocator);
    try path.appendSlice(allocator, "$");
    return try validateJsonSchemaValueDetailed(allocator, schema, args, &path);
}

fn validateJsonSchemaValue(schema: std.json.Value, value: std.json.Value) anyerror!void {
    if (schema != .object) return;
    if (schema.object.get("type")) |type_value| {
        switch (type_value) {
            .string => |type_name| try validateJsonSchemaType(type_name, schema, value),
            else => {},
        }
    }
}

fn validateJsonSchemaValueDetailed(
    allocator: std.mem.Allocator,
    schema: std.json.Value,
    value: std.json.Value,
    path: *std.ArrayList(u8),
) std.mem.Allocator.Error!?SchemaValidationIssue {
    if (schema != .object) return null;
    if (schema.object.get("type")) |type_value| {
        if (type_value == .string) {
            return try validateJsonSchemaTypeDetailed(allocator, type_value.string, schema, value, path);
        }
    }
    return null;
}

fn validateJsonSchemaType(type_name: []const u8, schema: std.json.Value, value: std.json.Value) anyerror!void {
    if (std.mem.eql(u8, type_name, "object")) {
        if (value != .object) return error.InvalidToolArguments;
        if (schema.object.get("required")) |required| {
            if (required == .array) {
                for (required.array.items) |required_item| {
                    if (required_item != .string) continue;
                    if (!value.object.contains(required_item.string)) return error.InvalidToolArguments;
                }
            }
        }
        const properties = if (schema.object.get("properties")) |properties_value| switch (properties_value) {
            .object => |properties_object| properties_object,
            else => null,
        } else null;
        if (properties) |properties_object| {
            var property_iterator = properties_object.iterator();
            while (property_iterator.next()) |entry| {
                if (value.object.get(entry.key_ptr.*)) |property_value| {
                    try validateJsonSchemaValue(entry.value_ptr.*, property_value);
                }
            }
            if (schema.object.get("additionalProperties")) |additional_properties| {
                if (additional_properties == .bool and !additional_properties.bool) {
                    var value_iterator = value.object.iterator();
                    while (value_iterator.next()) |entry| {
                        if (!properties_object.contains(entry.key_ptr.*)) return error.InvalidToolArguments;
                    }
                }
            }
        }
        return;
    }
    if (std.mem.eql(u8, type_name, "string")) {
        if (value != .string) return error.InvalidToolArguments;
        return;
    }
    if (std.mem.eql(u8, type_name, "boolean")) {
        if (value != .bool) return error.InvalidToolArguments;
        return;
    }
    if (std.mem.eql(u8, type_name, "integer")) {
        if (value != .integer) return error.InvalidToolArguments;
        return;
    }
    if (std.mem.eql(u8, type_name, "number")) {
        if (value != .integer and value != .float and value != .number_string) return error.InvalidToolArguments;
        return;
    }
    if (std.mem.eql(u8, type_name, "array")) {
        if (value != .array) return error.InvalidToolArguments;
        if (schema.object.get("items")) |items_schema| {
            for (value.array.items) |item| try validateJsonSchemaValue(items_schema, item);
        }
    }
}

fn validateJsonSchemaTypeDetailed(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    schema: std.json.Value,
    value: std.json.Value,
    path: *std.ArrayList(u8),
) std.mem.Allocator.Error!?SchemaValidationIssue {
    if (std.mem.eql(u8, type_name, "object")) {
        if (value != .object) return try schemaIssue(allocator, path.items, "invalid_type", "expected object");
        if (schema.object.get("required")) |required| {
            if (required == .array) {
                for (required.array.items) |required_item| {
                    if (required_item != .string) continue;
                    if (!value.object.contains(required_item.string)) {
                        const original_len = path.items.len;
                        try appendPathProperty(allocator, path, required_item.string);
                        defer path.shrinkRetainingCapacity(original_len);
                        return try schemaIssue(allocator, path.items, "missing_required", "missing required field");
                    }
                }
            }
        }
        const properties = if (schema.object.get("properties")) |properties_value| switch (properties_value) {
            .object => |properties_object| properties_object,
            else => null,
        } else null;
        if (properties) |properties_object| {
            var property_iterator = properties_object.iterator();
            while (property_iterator.next()) |entry| {
                if (value.object.get(entry.key_ptr.*)) |property_value| {
                    const original_len = path.items.len;
                    try appendPathProperty(allocator, path, entry.key_ptr.*);
                    defer path.shrinkRetainingCapacity(original_len);
                    if (try validateJsonSchemaValueDetailed(allocator, entry.value_ptr.*, property_value, path)) |issue| return issue;
                }
            }
            if (schema.object.get("additionalProperties")) |additional_properties| {
                if (additional_properties == .bool and !additional_properties.bool) {
                    var value_iterator = value.object.iterator();
                    while (value_iterator.next()) |entry| {
                        if (!properties_object.contains(entry.key_ptr.*)) {
                            const original_len = path.items.len;
                            try appendPathProperty(allocator, path, entry.key_ptr.*);
                            defer path.shrinkRetainingCapacity(original_len);
                            return try schemaIssue(allocator, path.items, "additional_property", "unexpected field");
                        }
                    }
                }
            }
        }
        return null;
    }
    if (std.mem.eql(u8, type_name, "string")) {
        if (value != .string) return try schemaIssue(allocator, path.items, "invalid_type", "expected string");
        return null;
    }
    if (std.mem.eql(u8, type_name, "boolean")) {
        if (value != .bool) return try schemaIssue(allocator, path.items, "invalid_type", "expected boolean");
        return null;
    }
    if (std.mem.eql(u8, type_name, "integer")) {
        if (value != .integer) return try schemaIssue(allocator, path.items, "invalid_type", "expected integer");
        return null;
    }
    if (std.mem.eql(u8, type_name, "number")) {
        if (value != .integer and value != .float and value != .number_string) return try schemaIssue(allocator, path.items, "invalid_type", "expected number");
        return null;
    }
    if (std.mem.eql(u8, type_name, "array")) {
        if (value != .array) return try schemaIssue(allocator, path.items, "invalid_type", "expected array");
        if (schema.object.get("items")) |items_schema| {
            for (value.array.items, 0..) |item, index| {
                const original_len = path.items.len;
                try appendPathIndex(allocator, path, index);
                defer path.shrinkRetainingCapacity(original_len);
                if (try validateJsonSchemaValueDetailed(allocator, items_schema, item, path)) |issue| return issue;
            }
        }
    }
    return null;
}

fn appendPathProperty(allocator: std.mem.Allocator, path: *std.ArrayList(u8), property: []const u8) std.mem.Allocator.Error!void {
    try path.append(allocator, '.');
    try path.appendSlice(allocator, property);
}

fn appendPathIndex(allocator: std.mem.Allocator, path: *std.ArrayList(u8), index: usize) std.mem.Allocator.Error!void {
    var buffer: [32]u8 = undefined;
    const segment = std.fmt.bufPrint(&buffer, "[{d}]", .{index}) catch unreachable;
    try path.appendSlice(allocator, segment);
}

fn schemaIssue(
    allocator: std.mem.Allocator,
    path: []const u8,
    code: []const u8,
    message: []const u8,
) std.mem.Allocator.Error!SchemaValidationIssue {
    return .{
        .code = try allocator.dupe(u8, code),
        .message = try allocator.dupe(u8, message),
        .path = try allocator.dupe(u8, path),
    };
}
