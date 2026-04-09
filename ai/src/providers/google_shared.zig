const std = @import("std");
const ai = @import("../root.zig");

pub fn sanitizeSurrogates(text: []const u8) []const u8 {
    return text;
}

pub fn isGemini3ProModel(model_id: []const u8) bool {
    const lower = std.asciiLowerStringStack(model_id);
    return std.mem.startsWith(u8, lower, "gemini-3") and std.mem.indexOf(u8, lower, "-pro") != null;
}

pub fn isGemini3FlashModel(model_id: []const u8) bool {
    const lower = std.asciiLowerStringStack(model_id);
    return std.mem.startsWith(u8, lower, "gemini-3") and std.mem.indexOf(u8, lower, "-flash") != null;
}

pub fn requiresToolCallId(model_id: []const u8) bool {
    return std.mem.startsWith(u8, model_id, "claude-") or std.mem.startsWith(u8, model_id, "gpt-oss-");
}

pub fn getGeminiMajorVersion(model_id: []const u8) ?u32 {
    const prefix = "gemini-";
    if (!std.mem.startsWith(u8, std.asciiLowerStringStack(model_id), prefix)) return null;
    const rest = model_id[prefix.len..];
    var i: usize = 0;
    while (i < rest.len and !std.ascii.isDigit(rest[i])) i += 1;
    if (i >= rest.len) return null;
    var num: u32 = 0;
    while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) {
        num = num * 10 + (rest[i] - '0');
    }
    return num;
}

pub fn supportsMultimodalFunctionResponse(model_id: []const u8) bool {
    const major = getGeminiMajorVersion(model_id);
    if (major) |m| return m >= 3;
    return true;
}

pub fn normalizeToolCallId(gpa: std.mem.Allocator, id: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(gpa);
    defer buf.deinit();
    for (id) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            try buf.append(c);
        } else {
            try buf.append('_');
        }
    }
    var result = try buf.toOwnedSlice();
    if (result.len > 64) {
        const truncated = try gpa.dupe(u8, result[0..64]);
        gpa.free(result);
        result = truncated;
    }
    return result;
}

pub fn resolveThoughtSignature(is_same: bool, signature: ?[]const u8) ?[]const u8 {
    if (!is_same) return null;
    if (signature) |s| {
        if (s.len % 4 != 0) return null;
        for (s) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=')) return null;
        }
        return s;
    }
    return null;
}

pub fn isThinkingPart(part_obj: std.json.ObjectMap) bool {
    if (part_obj.get("thought")) |tv| {
        if (tv == .bool) return tv.bool;
    }
    return false;
}

pub fn mapToolChoice(choice: []const u8) []const u8 {
    if (std.mem.eql(u8, choice, "none")) return "NONE";
    if (std.mem.eql(u8, choice, "any")) return "ANY";
    return "AUTO";
}

pub fn mapStopReason(reason: []const u8) ai.StopReason {
    if (std.mem.eql(u8, reason, "STOP")) return .stop;
    if (std.mem.eql(u8, reason, "MAX_TOKENS")) return .length;
    return .err;
}

pub fn mapStopReasonString(reason: []const u8) ai.StopReason {
    return mapStopReason(reason);
}

fn jsonStringifyValue(gpa: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var list = std.ArrayList(u8).init(gpa);
    defer list.deinit();
    try std.json.stringify(value, .{}, list.writer());
    return list.toOwnedSlice();
}

pub fn convertMessages(gpa: std.mem.Allocator, model: ai.Model, context: ai.Context) !std.json.Value {
    const norm_id = struct {
        fn f(id: []const u8, _m: ai.Model, _src: ai.AssistantMessage) []const u8 {
            _ = _m;
            _ = _src;
            return normalizeToolCallId(std.heap.page_allocator, id) catch id;
        }
    }.f;
    const msgs = try ai.transform_messages.transformMessages(gpa, context.messages, model, norm_id);
    defer gpa.free(msgs);

    var contents = std.ArrayList(std.json.Value).init(gpa);

    for (msgs) |msg| {
        switch (msg) {
            .user => |u| {
                switch (u.content) {
                    .text => |t| {
                        var obj = std.json.ObjectMap.init(gpa);
                        try obj.put("role", .{ .string = "user" });
                        var parts = std.ArrayList(std.json.Value).init(gpa);
                        var pt = std.json.ObjectMap.init(gpa);
                        try pt.put("text", .{ .string = sanitizeSurrogates(t.text) });
                        try parts.append(.{ .object = pt });
                        try obj.put("parts", .{ .array = .{ .items = parts, .capacity = parts.items.len } });
                        try contents.append(.{ .object = obj });
                    },
                    .blocks => |blocks| {
                        var parts = std.ArrayList(std.json.Value).init(gpa);
                        for (blocks) |block| {
                            switch (block) {
                                .text => |t| {
                                    var pt = std.json.ObjectMap.init(gpa);
                                    try pt.put("text", .{ .string = sanitizeSurrogates(t.text) });
                                    try parts.append(.{ .object = pt });
                                },
                                .image => |img| {
                                    if (!std.mem.containsAtLeast(u8, model.input, 1, "image")) continue;
                                    var pt = std.json.ObjectMap.init(gpa);
                                    try pt.put("inlineData", .{ .object = blk: {
                                        var o = std.json.ObjectMap.init(gpa);
                                        try o.put("mimeType", .{ .string = img.mime_type });
                                        try o.put("data", .{ .string = img.data });
                                        break :blk o;
                                    } });
                                    try parts.append(.{ .object = pt });
                                },
                                else => {},
                            }
                        }
                        if (parts.items.len > 0) {
                            var obj = std.json.ObjectMap.init(gpa);
                            try obj.put("role", .{ .string = "user" });
                            try obj.put("parts", .{ .array = .{ .items = parts, .capacity = parts.items.len } });
                            try contents.append(.{ .object = obj });
                        }
                        parts.deinit();
                    },
                }
            },
            .assistant => |a| {
                const is_same = std.mem.eql(u8, a.provider, model.provider) and std.mem.eql(u8, a.model, model.id);
                var parts = std.ArrayList(std.json.Value).init(gpa);
                for (a.content) |block| {
                    switch (block) {
                        .text => |t| {
                            if (t.text.len == 0 or std.mem.trim(u8, t.text, " \t\r\n").len == 0) continue;
                            var pt = std.json.ObjectMap.init(gpa);
                            try pt.put("text", .{ .string = sanitizeSurrogates(t.text) });
                            const sig = resolveThoughtSignature(is_same, t.text_signature);
                            if (sig) |s| try pt.put("thoughtSignature", .{ .string = s });
                            try parts.append(.{ .object = pt });
                        },
                        .thinking => |th| {
                            if (th.thinking.len == 0 or std.mem.trim(u8, th.thinking, " \t\r\n").len == 0) continue;
                            if (is_same) {
                                var pt = std.json.ObjectMap.init(gpa);
                                try pt.put("thought", .{ .bool = true });
                                try pt.put("text", .{ .string = sanitizeSurrogates(th.thinking) });
                                const sig = resolveThoughtSignature(is_same, th.thinking_signature);
                                if (sig) |s| try pt.put("thoughtSignature", .{ .string = s });
                                try parts.append(.{ .object = pt });
                            } else {
                                var pt = std.json.ObjectMap.init(gpa);
                                try pt.put("text", .{ .string = sanitizeSurrogates(th.thinking) });
                                try parts.append(.{ .object = pt });
                            }
                        },
                        .tool_call => |tc| {
                            const include_id = requiresToolCallId(model.id);
                            var pt = std.json.ObjectMap.init(gpa);
                            var fc = std.json.ObjectMap.init(gpa);
                            try fc.put("name", .{ .string = tc.name });
                            try fc.put("args", tc.arguments);
                            if (include_id) try fc.put("id", .{ .string = tc.id });
                            try pt.put("functionCall", .{ .object = fc });
                            const sig = resolveThoughtSignature(is_same, tc.thought_signature);
                            if (sig) |s| try pt.put("thoughtSignature", .{ .string = s });
                            try parts.append(.{ .object = pt });
                        },
                        else => {},
                    }
                }
                if (parts.items.len > 0) {
                    var obj = std.json.ObjectMap.init(gpa);
                    try obj.put("role", .{ .string = "model" });
                    try obj.put("parts", .{ .array = .{ .items = parts, .capacity = parts.items.len } });
                    try contents.append(.{ .object = obj });
                }
                parts.deinit();
            },
            .tool_result => |tr| {
                var text_parts = std.ArrayList([]const u8).init(gpa);
                var has_images = false;
                var image_parts = std.ArrayList(std.json.Value).init(gpa);
                for (tr.content) |block| {
                    switch (block) {
                        .text => |t| try text_parts.append(t.text),
                        .image => |img| {
                            has_images = true;
                            if (std.mem.containsAtLeast(u8, model.input, 1, "image")) {
                                var pt = std.json.ObjectMap.init(gpa);
                                try pt.put("inlineData", .{ .object = blk: {
                                    var o = std.json.ObjectMap.init(gpa);
                                    try o.put("mimeType", .{ .string = img.mime_type });
                                    try o.put("data", .{ .string = img.data });
                                    break :blk o;
                                } });
                                try image_parts.append(.{ .object = pt });
                            }
                        },
                        else => {},
                    }
                }
                const text_result = try std.mem.join(gpa, "\n", text_parts.items);
                text_parts.deinit();
                const has_text = text_result.len > 0;
                const mm_supported = supportsMultimodalFunctionResponse(model.id);

                const include_id = requiresToolCallId(model.id);
                var fr = std.json.ObjectMap.init(gpa);
                try fr.put("name", .{ .string = tr.tool_name });
                const response_val = if (tr.is_error)
                    std.json.Value{ .object = blk: { var o = std.json.ObjectMap.init(gpa); try o.put("error", .{ .string = if (has_text) sanitizeSurrogates(text_result) else "(see attached image)" }); break :blk o; } }
                else
                    std.json.Value{ .object = blk: { var o = std.json.ObjectMap.init(gpa); try o.put("output", .{ .string = if (has_text) sanitizeSurrogates(text_result) else "(see attached image)" }); break :blk o; } };
                try fr.put("response", response_val);
                if (has_images and mm_supported and image_parts.items.len > 0) {
                    try fr.put("parts", .{ .array = .{ .items = image_parts, .capacity = image_parts.items.len } });
                }
                if (include_id) try fr.put("id", .{ .string = tr.tool_call_id });

                var fcp = std.json.ObjectMap.init(gpa);
                try fcp.put("functionResponse", .{ .object = fr });

                if (contents.items.len > 0) {
                    if (contents.items[contents.items.len - 1].object.get("role")) |rv| {
                        if (rv == .string and std.mem.eql(u8, rv.string, "user")) {
                            if (contents.items[contents.items.len - 1].object.get("parts")) |pv| {
                                if (pv == .array) {
                                    var has_fr = false;
                                    for (pv.array.items) |p| {
                                        if (p.object.get("functionResponse") != null) {
                                            has_fr = true;
                                            break;
                                        }
                                    }
                                    if (has_fr) {
                                        var arr = pv.array;
                                        try arr.items.append(.{ .object = fcp });
                                        try contents.items[contents.items.len - 1].object.put("parts", .{ .array = arr });
                                        if (!mm_supported and has_images and image_parts.items.len > 0) {
                                            var extra = std.ArrayList(std.json.Value).init(gpa);
                                            var txt = std.json.ObjectMap.init(gpa);
                                            try txt.put("text", .{ .string = "Tool result image:" });
                                            try extra.append(.{ .object = txt });
                                            for (image_parts.items) |ip| try extra.append(ip);
                                            var extra_obj = std.json.ObjectMap.init(gpa);
                                            try extra_obj.put("role", .{ .string = "user" });
                                            try extra_obj.put("parts", .{ .array = .{ .items = extra, .capacity = extra.items.len } });
                                            try contents.append(.{ .object = extra_obj });
                                        }
                                        continue;
                                    }
                                }
                            }
                        }
                    }
                }

                var obj = std.json.ObjectMap.init(gpa);
                try obj.put("role", .{ .string = "user" });
                var arr = std.ArrayList(std.json.Value).init(gpa);
                try arr.append(.{ .object = fcp });
                try obj.put("parts", .{ .array = .{ .items = arr, .capacity = arr.items.len } });
                try contents.append(.{ .object = obj });

                if (!mm_supported and has_images and image_parts.items.len > 0) {
                    var extra = std.ArrayList(std.json.Value).init(gpa);
                    var txt = std.json.ObjectMap.init(gpa);
                    try txt.put("text", .{ .string = "Tool result image:" });
                    try extra.append(.{ .object = txt });
                    for (image_parts.items) |ip| try extra.append(ip);
                    var extra_obj = std.json.ObjectMap.init(gpa);
                    try extra_obj.put("role", .{ .string = "user" });
                    try extra_obj.put("parts", .{ .array = .{ .items = extra, .capacity = extra.items.len } });
                    try contents.append(.{ .object = extra_obj });
                }
            },
        }
    }

    return std.json.Value{ .array = .{ .items = contents, .capacity = contents.items.len } };
}

pub fn convertTools(gpa: std.mem.Allocator, tools: []const ai.Tool) !std.json.Value {
    var declarations = std.ArrayList(std.json.Value).init(gpa);
    for (tools) |tool| {
        var obj = std.json.ObjectMap.init(gpa);
        try obj.put("name", .{ .string = tool.name });
        try obj.put("description", .{ .string = tool.description });
        try obj.put("parameters", tool.parameters);
        try declarations.append(.{ .object = obj });
    }
    var outer = std.json.ObjectMap.init(gpa);
    try outer.put("functionDeclarations", .{ .array = .{ .items = declarations, .capacity = declarations.items.len } });
    var arr = std.ArrayList(std.json.Value).init(gpa);
    try arr.append(.{ .object = outer });
    return std.json.Value{ .array = .{ .items = arr, .capacity = arr.items.len } };
}
