const std = @import("std");

// Fixed memory layout:
// 0x0000 - 0xFFFF (64KB): reserved for WASM runtime stack/data
// 0x10000 - 0x1FFFF (64KB): input buffer
// 0x20000 - 0x2FFFF (64KB): output buffer
const INPUT_OFFSET = 0x10000;
const OUTPUT_OFFSET = 0x20000;
const MAX_SIZE = 0x10000; // 64KB max

/// Copy input to WASM memory and parse it.
/// Returns pointer to result in output buffer, or 0 on error.
export fn parseJson(inputPtr: [*]const u8, inputLen: usize) usize {
    // Read input from shared memory
    const input = inputPtr[0..inputLen];

    // Try standard JSON parse first
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.wasm_allocator, input, .{}) catch {
        // If standard parse fails, try to parse as partial/incomplete JSON
        var end_idx: usize = input.len;
        while (end_idx > 0) : (end_idx -= 1) {
            const prefix = input[0..end_idx];
            if (std.json.parseFromSlice(std.json.Value, std.heap.wasm_allocator, prefix, .{})) |result| {
                defer result.deinit();
                return serializeValue(result.value);
            } else |_| {
                continue;
            }
        }
        // All parsing failed, return empty object
        return serializeString("{}");
    };
    defer parsed.deinit();

    return serializeValue(parsed.value);
}

/// Get the length of a string at given pointer.
export fn stringLen(ptr: usize) usize {
    if (ptr == 0) return 0;
    const base_ptr = @as([*]u8, @ptrFromInt(ptr - @sizeOf(usize)));
    const len_ptr: *usize = @ptrCast(@alignCast(base_ptr));
    return len_ptr.*;
}

fn serializeValue(value: std.json.Value) usize {
    // Use a fixed buffer on the stack, then copy to output buffer
    var buf: [MAX_SIZE]u8 = undefined;
    var end: usize = 0;

    // Simple custom JSON serializer to avoid heap allocation
    serializeValueToBuffer(value, &buf, &end);

    return serializeString(buf[0..end]);
}

fn serializeValueToBuffer(value: std.json.Value, buf: []u8, end: *usize) void {
    switch (value) {
        .null => appendString(buf, end, "null"),
        .bool => |b| appendString(buf, end, if (b) "true" else "false"),
        .integer => |i| {
            const str = std.fmt.bufPrint(buf[end.*..], "{d}", .{i}) catch return;
            end.* += str.len;
        },
        .float => |f| {
            const str = std.fmt.bufPrint(buf[end.*..], "{d}", .{f}) catch return;
            end.* += str.len;
        },
        .number_string => |s| appendString(buf, end, s),
        .string => |s| {
            appendString(buf, end, "\"");
            appendString(buf, end, s);
            appendString(buf, end, "\"");
        },
        .array => |arr| {
            appendString(buf, end, "[");
            for (arr.items, 0..) |item, i| {
                if (i > 0) appendString(buf, end, ",");
                serializeValueToBuffer(item, buf, end);
            }
            appendString(buf, end, "]");
        },
        .object => |obj| {
            appendString(buf, end, "{");
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) appendString(buf, end, ",");
                first = false;
                appendString(buf, end, "\"");
                appendString(buf, end, entry.key_ptr.*);
                appendString(buf, end, "\":");
                serializeValueToBuffer(entry.value_ptr.*, buf, end);
            }
            appendString(buf, end, "}");
        },
    }
}

fn appendString(buf: []u8, end: *usize, str: []const u8) void {
    if (end.* + str.len > buf.len) return;
    @memcpy(buf[end.*..end.* + str.len], str);
    end.* += str.len;
}

fn serializeString(str: []const u8) usize {
    // Write to output buffer with length prefix
    const total_len = @sizeOf(usize) + str.len;
    if (total_len > MAX_SIZE) return 0;

    const mem = @as([*]u8, @ptrFromInt(OUTPUT_OFFSET));
    const len_ptr: *usize = @ptrCast(@alignCast(mem));
    len_ptr.* = str.len;

    const data_ptr = mem + @sizeOf(usize);
    @memcpy(data_ptr[0..str.len], str);

    return @intFromPtr(data_ptr);
}
