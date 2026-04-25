const std = @import("std");
const component = @import("component.zig");

pub const LineList = component.LineList;

pub const DisplayCluster = struct {
    end: usize,
    width: usize,
};

pub const RgbColor = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub fn visibleWidth(text: []const u8) usize {
    var index: usize = 0;
    var width: usize = 0;
    while (index < text.len) {
        if (ansiSequenceLength(text, index)) |len| {
            index += len;
            continue;
        }

        const cluster = nextDisplayCluster(text, index);
        index = cluster.end;
        width += cluster.width;
    }
    return width;
}

pub fn nextDisplayCluster(text: []const u8, start: usize) DisplayCluster {
    if (start >= text.len) return .{ .end = start, .width = 0 };

    var first_index = start;
    const first = decodeNextCodepoint(text, &first_index);

    var end = first_index;
    const width = codepointDisplayWidth(first.codepoint);
    var has_visible = width > 0;
    var has_emoji = isEmojiCodepoint(first.codepoint);
    var has_joiner = false;
    var regional_indicators: usize = if (isRegionalIndicator(first.codepoint)) 1 else 0;

    while (end < text.len) {
        var next_index = end;
        const next = decodeNextCodepoint(text, &next_index);

        if (next.codepoint == 0x200D) {
            has_joiner = true;
            has_emoji = true;
            end = next_index;
            if (end >= text.len) break;

            next_index = end;
            const joined = decodeNextCodepoint(text, &next_index);
            end = next_index;
            has_visible = has_visible or codepointDisplayWidth(joined.codepoint) > 0;
            has_emoji = true;
            regional_indicators = 0;
            continue;
        }

        if (isClusterExtend(next.codepoint)) {
            end = next_index;
            has_emoji = has_emoji or isEmojiRelated(next.codepoint);
            continue;
        }

        if (regional_indicators == 1 and isRegionalIndicator(next.codepoint)) {
            end = next_index;
            regional_indicators = 2;
            has_visible = true;
            has_emoji = true;
        }

        break;
    }

    return .{
        .end = end,
        .width = if (!has_visible)
            0
        else if (has_joiner or regional_indicators == 2 or has_emoji)
            2
        else
            width,
    };
}

pub fn padRightVisibleAlloc(allocator: std.mem.Allocator, line: []const u8, width: usize) std.mem.Allocator.Error![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, line);

    const current_width = visibleWidth(line);
    if (current_width < width) {
        try buffer.appendNTimes(allocator, ' ', width - current_width);
    }

    return buffer.toOwnedSlice(allocator);
}

pub fn parseHexColor(text: []const u8) ?RgbColor {
    if (text.len != 7 or text[0] != '#') return null;
    return .{
        .r = std.fmt.parseInt(u8, text[1..3], 16) catch return null,
        .g = std.fmt.parseInt(u8, text[3..5], 16) catch return null,
        .b = std.fmt.parseInt(u8, text[5..7], 16) catch return null,
    };
}

pub fn applyHorizontalGradientAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    start: RgbColor,
    end: RgbColor,
) std.mem.Allocator.Error![]u8 {
    const visible_clusters = countVisibleClusters(text);
    if (visible_clusters == 0) return allocator.dupe(u8, text);

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    var cluster_index: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (ansiSequenceLength(text, index)) |len| {
            try builder.appendSlice(allocator, text[index .. index + len]);
            index += len;
            continue;
        }

        const cluster = nextDisplayCluster(text, index);
        if (cluster.width == 0) {
            try builder.appendSlice(allocator, text[index..cluster.end]);
            index = cluster.end;
            continue;
        }

        const color = interpolateGradientColor(start, end, cluster_index, visible_clusters);
        const color_code = try std.fmt.allocPrint(allocator, "\x1b[38;2;{d};{d};{d}m", .{ color.r, color.g, color.b });
        defer allocator.free(color_code);
        try builder.appendSlice(allocator, color_code);
        try builder.appendSlice(allocator, text[index..cluster.end]);
        cluster_index += 1;
        index = cluster.end;
    }

    try builder.appendSlice(allocator, "\x1b[0m");
    return builder.toOwnedSlice(allocator);
}

pub fn wrapTextWithAnsi(allocator: std.mem.Allocator, text: []const u8, width: usize, lines: *LineList) std.mem.Allocator.Error!void {
    const effective_width = @max(width, 1);
    var current_line = std.ArrayList(u8).empty;
    defer current_line.deinit(allocator);

    var active_sgr = std.ArrayList(u8).empty;
    defer active_sgr.deinit(allocator);

    var current_width: usize = 0;
    var index: usize = 0;

    while (index < text.len) {
        const byte = text[index];
        if (byte == '\n') {
            try appendWrappedLine(allocator, lines, &current_line, &active_sgr);
            current_width = 0;
            index += 1;
            continue;
        }

        if (ansiSequenceLength(text, index)) |len| {
            const sequence = text[index .. index + len];
            try current_line.appendSlice(allocator, sequence);
            updateActiveSgr(allocator, sequence, &active_sgr);
            index += len;
            continue;
        }

        const cluster = nextDisplayCluster(text, index);
        if (current_width > 0 and current_width + cluster.width > effective_width) {
            try appendWrappedLine(allocator, lines, &current_line, &active_sgr);
            current_width = 0;
        }

        try current_line.appendSlice(allocator, text[index..cluster.end]);
        current_width += cluster.width;
        index = cluster.end;
    }

    if (current_line.items.len > 0 or text.len == 0) {
        try appendWrappedLine(allocator, lines, &current_line, &active_sgr);
    }
}

pub fn sliceVisibleAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    start_col: usize,
    width: usize,
) std.mem.Allocator.Error![]u8 {
    if (width == 0) return allocator.dupe(u8, "");

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    var active_sgr = std.ArrayList(u8).empty;
    defer active_sgr.deinit(allocator);

    const end_col = start_col + width;
    var column: usize = 0;
    var index: usize = 0;
    var started = false;

    while (index < text.len and column < end_col) {
        if (ansiSequenceLength(text, index)) |len| {
            const sequence = text[index .. index + len];
            updateActiveSgr(allocator, sequence, &active_sgr);
            if (started) {
                try builder.appendSlice(allocator, sequence);
            }
            index += len;
            continue;
        }

        const cluster = nextDisplayCluster(text, index);

        if (column >= start_col and column + cluster.width <= end_col) {
            if (!started) {
                started = true;
                if (active_sgr.items.len > 0) {
                    try builder.appendSlice(allocator, active_sgr.items);
                }
            }
            try builder.appendSlice(allocator, text[index..cluster.end]);
        }

        column += cluster.width;
        index = cluster.end;
    }

    if (started and active_sgr.items.len > 0) {
        try builder.appendSlice(allocator, "\x1b[0m");
    }

    return builder.toOwnedSlice(allocator);
}

fn appendWrappedLine(
    allocator: std.mem.Allocator,
    lines: *LineList,
    current_line: *std.ArrayList(u8),
    active_sgr: *std.ArrayList(u8),
) std.mem.Allocator.Error!void {
    var line = std.ArrayList(u8).empty;
    errdefer line.deinit(allocator);

    try line.appendSlice(allocator, current_line.items);
    if (active_sgr.items.len > 0) {
        try line.appendSlice(allocator, "\x1b[0m");
    }

    try lines.append(allocator, try line.toOwnedSlice(allocator));

    current_line.clearRetainingCapacity();
    if (active_sgr.items.len > 0) {
        try current_line.appendSlice(allocator, active_sgr.items);
    }
}

fn countVisibleClusters(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (ansiSequenceLength(text, index)) |len| {
            index += len;
            continue;
        }

        const cluster = nextDisplayCluster(text, index);
        if (cluster.width > 0) count += 1;
        index = cluster.end;
    }
    return count;
}

fn interpolateGradientColor(start: RgbColor, end: RgbColor, index: usize, total: usize) RgbColor {
    if (total <= 1) return start;
    return .{
        .r = interpolateChannel(start.r, end.r, index, total),
        .g = interpolateChannel(start.g, end.g, index, total),
        .b = interpolateChannel(start.b, end.b, index, total),
    };
}

fn interpolateChannel(start: u8, end: u8, index: usize, total: usize) u8 {
    if (total <= 1) return start;
    const start_weight = total - 1 - index;
    const end_weight = index;
    const numerator = @as(usize, start) * start_weight + @as(usize, end) * end_weight;
    return @intCast(numerator / (total - 1));
}

fn updateActiveSgr(allocator: std.mem.Allocator, sequence: []const u8, active_sgr: *std.ArrayList(u8)) void {
    if (sequence.len < 3) return;
    if (sequence[0] != 0x1b or sequence[1] != '[' or sequence[sequence.len - 1] != 'm') return;

    const params = sequence[2 .. sequence.len - 1];
    if (params.len == 0 or std.mem.eql(u8, params, "0")) {
        active_sgr.clearRetainingCapacity();
        return;
    }

    active_sgr.appendSlice(allocator, sequence) catch return;
}

fn ansiSequenceLength(text: []const u8, start: usize) ?usize {
    if (start + 1 >= text.len or text[start] != 0x1b) return null;

    const kind = text[start + 1];
    switch (kind) {
        '[' => {
            var index = start + 2;
            while (index < text.len) : (index += 1) {
                const byte = text[index];
                if (byte >= 0x40 and byte <= 0x7e) {
                    return index - start + 1;
                }
            }
            return text.len - start;
        },
        ']' => {
            var index = start + 2;
            while (index < text.len) : (index += 1) {
                if (text[index] == 0x07) return index - start + 1;
                if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '\\') {
                    return index - start + 2;
                }
            }
            return text.len - start;
        },
        else => return if (kind >= 0x40 and kind <= 0x5f) 2 else null,
    }
}

const DecodedCodepoint = struct {
    codepoint: u21,
};

fn decodeNextCodepoint(text: []const u8, index: *usize) DecodedCodepoint {
    const start = index.*;
    if (start >= text.len) return .{ .codepoint = 0 };

    const sequence_len = std.unicode.utf8ByteSequenceLength(text[start]) catch 1;
    const actual_len = @min(sequence_len, text.len - start);
    const slice = text[start .. start + actual_len];
    const codepoint = std.unicode.utf8Decode(slice) catch {
        index.* = start + 1;
        return .{ .codepoint = slice[0] };
    };
    index.* = start + actual_len;
    return .{ .codepoint = codepoint };
}

fn codepointDisplayWidth(codepoint: u21) usize {
    if (codepoint == 0) return 0;
    if (isZeroWidthCodepoint(codepoint)) return 0;
    if (isEmojiCodepoint(codepoint) or isRegionalIndicator(codepoint) or isWideCodepoint(codepoint)) return 2;
    return 1;
}

fn isClusterExtend(codepoint: u21) bool {
    return isCombiningMark(codepoint) or isVariationSelector(codepoint) or isEmojiModifier(codepoint);
}

fn isEmojiRelated(codepoint: u21) bool {
    return isEmojiCodepoint(codepoint) or isEmojiModifier(codepoint) or isRegionalIndicator(codepoint) or isVariationSelector(codepoint);
}

fn isEmojiCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x1F000 and codepoint <= 0x1FAFF) or
        (codepoint >= 0x2600 and codepoint <= 0x27BF) or
        (codepoint >= 0x2300 and codepoint <= 0x23FF) or
        (codepoint >= 0x2B50 and codepoint <= 0x2B55);
}

fn isEmojiModifier(codepoint: u21) bool {
    return codepoint >= 0x1F3FB and codepoint <= 0x1F3FF;
}

fn isRegionalIndicator(codepoint: u21) bool {
    return codepoint >= 0x1F1E6 and codepoint <= 0x1F1FF;
}

fn isVariationSelector(codepoint: u21) bool {
    return (codepoint >= 0xFE00 and codepoint <= 0xFE0F) or
        (codepoint >= 0xE0100 and codepoint <= 0xE01EF);
}

fn isZeroWidthCodepoint(codepoint: u21) bool {
    if (codepoint <= 0x1F) return true;
    if (codepoint >= 0x7F and codepoint <= 0x9F) return true;
    if (codepoint == 0x200D) return true;
    if (isVariationSelector(codepoint)) return true;
    if (isCombiningMark(codepoint)) return true;
    return (codepoint >= 0x200B and codepoint <= 0x200F) or
        (codepoint >= 0x202A and codepoint <= 0x202E) or
        (codepoint >= 0x2060 and codepoint <= 0x2064) or
        (codepoint >= 0x2066 and codepoint <= 0x206F) or
        (codepoint >= 0xFFF9 and codepoint <= 0xFFFB);
}

fn isCombiningMark(codepoint: u21) bool {
    return (codepoint >= 0x0300 and codepoint <= 0x036F) or
        (codepoint >= 0x0483 and codepoint <= 0x0489) or
        (codepoint >= 0x0591 and codepoint <= 0x05BD) or
        codepoint == 0x05BF or
        (codepoint >= 0x05C1 and codepoint <= 0x05C2) or
        (codepoint >= 0x05C4 and codepoint <= 0x05C5) or
        codepoint == 0x05C7 or
        (codepoint >= 0x0610 and codepoint <= 0x061A) or
        (codepoint >= 0x064B and codepoint <= 0x065F) or
        codepoint == 0x0670 or
        (codepoint >= 0x06D6 and codepoint <= 0x06DC) or
        (codepoint >= 0x06DF and codepoint <= 0x06E4) or
        (codepoint >= 0x06E7 and codepoint <= 0x06E8) or
        (codepoint >= 0x06EA and codepoint <= 0x06ED) or
        (codepoint >= 0x0711 and codepoint <= 0x0711) or
        (codepoint >= 0x0730 and codepoint <= 0x074A) or
        (codepoint >= 0x07A6 and codepoint <= 0x07B0) or
        (codepoint >= 0x07EB and codepoint <= 0x07F3) or
        (codepoint >= 0x0816 and codepoint <= 0x0819) or
        (codepoint >= 0x081B and codepoint <= 0x0823) or
        (codepoint >= 0x0825 and codepoint <= 0x0827) or
        (codepoint >= 0x0829 and codepoint <= 0x082D) or
        (codepoint >= 0x0859 and codepoint <= 0x085B) or
        (codepoint >= 0x08D3 and codepoint <= 0x08E1) or
        (codepoint >= 0x08E3 and codepoint <= 0x0902) or
        codepoint == 0x093A or
        codepoint == 0x093C or
        (codepoint >= 0x0941 and codepoint <= 0x0948) or
        codepoint == 0x094D or
        (codepoint >= 0x0951 and codepoint <= 0x0957) or
        (codepoint >= 0x0962 and codepoint <= 0x0963) or
        (codepoint >= 0x0981 and codepoint <= 0x0981) or
        codepoint == 0x09BC or
        codepoint == 0x09C1 or
        codepoint == 0x09C2 or
        codepoint == 0x09CD or
        (codepoint >= 0x09E2 and codepoint <= 0x09E3) or
        codepoint == 0x0A01 or
        codepoint == 0x0A02 or
        codepoint == 0x0A3C or
        codepoint == 0x0A41 or
        codepoint == 0x0A42 or
        (codepoint >= 0x0A47 and codepoint <= 0x0A48) or
        (codepoint >= 0x0A4B and codepoint <= 0x0A4D) or
        (codepoint >= 0x0A51 and codepoint <= 0x0A51) or
        (codepoint >= 0x0A70 and codepoint <= 0x0A71) or
        (codepoint >= 0x0A75 and codepoint <= 0x0A75) or
        (codepoint >= 0x0A81 and codepoint <= 0x0A82) or
        codepoint == 0x0ABC or
        (codepoint >= 0x0AC1 and codepoint <= 0x0AC5) or
        (codepoint >= 0x0AC7 and codepoint <= 0x0AC8) or
        codepoint == 0x0ACD or
        (codepoint >= 0x0AE2 and codepoint <= 0x0AE3) or
        codepoint == 0x0B01 or
        codepoint == 0x0B3C or
        codepoint == 0x0B3F or
        (codepoint >= 0x0B41 and codepoint <= 0x0B44) or
        codepoint == 0x0B4D or
        (codepoint >= 0x0B55 and codepoint <= 0x0B56) or
        (codepoint >= 0x0B62 and codepoint <= 0x0B63) or
        codepoint == 0x0B82 or
        codepoint == 0x0BC0 or
        codepoint == 0x0BCD or
        codepoint == 0x0C00 or
        codepoint == 0x0C3E or
        codepoint == 0x0C3F or
        (codepoint >= 0x0C46 and codepoint <= 0x0C48) or
        (codepoint >= 0x0C4A and codepoint <= 0x0C4D) or
        (codepoint >= 0x0C55 and codepoint <= 0x0C56) or
        (codepoint >= 0x0C62 and codepoint <= 0x0C63) or
        codepoint == 0x0C81 or
        codepoint == 0x0CBC or
        codepoint == 0x0CBF or
        codepoint == 0x0CC6 or
        (codepoint >= 0x0CCC and codepoint <= 0x0CCD) or
        (codepoint >= 0x0CE2 and codepoint <= 0x0CE3) or
        codepoint == 0x0D00 or
        (codepoint >= 0x0D3B and codepoint <= 0x0D3C) or
        (codepoint >= 0x0D41 and codepoint <= 0x0D44) or
        codepoint == 0x0D4D or
        (codepoint >= 0x0D62 and codepoint <= 0x0D63) or
        codepoint == 0x0D81 or
        codepoint == 0x0DCA or
        (codepoint >= 0x0DD2 and codepoint <= 0x0DD4) or
        codepoint == 0x0DD6 or
        codepoint == 0x0E31 or
        (codepoint >= 0x0E34 and codepoint <= 0x0E3A) or
        (codepoint >= 0x0E47 and codepoint <= 0x0E4E) or
        codepoint == 0x0EB1 or
        (codepoint >= 0x0EB4 and codepoint <= 0x0EBC) or
        (codepoint >= 0x0EC8 and codepoint <= 0x0ECE) or
        codepoint == 0x0F18 or
        codepoint == 0x0F19 or
        codepoint == 0x0F35 or
        codepoint == 0x0F37 or
        codepoint == 0x0F39 or
        (codepoint >= 0x0F71 and codepoint <= 0x0F7E) or
        (codepoint >= 0x0F80 and codepoint <= 0x0F84) or
        (codepoint >= 0x0F86 and codepoint <= 0x0F87) or
        (codepoint >= 0x0F8D and codepoint <= 0x0F97) or
        (codepoint >= 0x0F99 and codepoint <= 0x0FBC) or
        codepoint == 0x0FC6 or
        (codepoint >= 0x102D and codepoint <= 0x1030) or
        (codepoint >= 0x1032 and codepoint <= 0x1037) or
        codepoint == 0x1039 or
        codepoint == 0x103A or
        (codepoint >= 0x103D and codepoint <= 0x103E) or
        (codepoint >= 0x1058 and codepoint <= 0x1059) or
        (codepoint >= 0x105E and codepoint <= 0x1060) or
        (codepoint >= 0x1071 and codepoint <= 0x1074) or
        codepoint == 0x1082 or
        (codepoint >= 0x1085 and codepoint <= 0x1086) or
        codepoint == 0x108D or
        codepoint == 0x109D or
        (codepoint >= 0x135D and codepoint <= 0x135F) or
        (codepoint >= 0x1712 and codepoint <= 0x1714) or
        (codepoint >= 0x1732 and codepoint <= 0x1734) or
        (codepoint >= 0x1752 and codepoint <= 0x1753) or
        (codepoint >= 0x1772 and codepoint <= 0x1773) or
        (codepoint >= 0x17B4 and codepoint <= 0x17B5) or
        (codepoint >= 0x17B7 and codepoint <= 0x17BD) or
        codepoint == 0x17C6 or
        (codepoint >= 0x17C9 and codepoint <= 0x17D3) or
        codepoint == 0x17DD or
        (codepoint >= 0x180B and codepoint <= 0x180F) or
        (codepoint >= 0x1885 and codepoint <= 0x1886) or
        codepoint == 0x18A9 or
        (codepoint >= 0x1920 and codepoint <= 0x1922) or
        (codepoint >= 0x1927 and codepoint <= 0x1928) or
        codepoint == 0x1932 or
        (codepoint >= 0x1939 and codepoint <= 0x193B) or
        (codepoint >= 0x1A17 and codepoint <= 0x1A18) or
        codepoint == 0x1A1B or
        (codepoint >= 0x1A56 and codepoint <= 0x1A56) or
        (codepoint >= 0x1A58 and codepoint <= 0x1A5E) or
        codepoint == 0x1A60 or
        (codepoint >= 0x1A62 and codepoint <= 0x1A62) or
        (codepoint >= 0x1A65 and codepoint <= 0x1A6C) or
        (codepoint >= 0x1A73 and codepoint <= 0x1A7C) or
        codepoint == 0x1A7F or
        (codepoint >= 0x1AB0 and codepoint <= 0x1AFF) or
        (codepoint >= 0x1B00 and codepoint <= 0x1B03) or
        codepoint == 0x1B34 or
        (codepoint >= 0x1B36 and codepoint <= 0x1B3A) or
        codepoint == 0x1B3C or
        codepoint == 0x1B42 or
        (codepoint >= 0x1B6B and codepoint <= 0x1B73) or
        (codepoint >= 0x1B80 and codepoint <= 0x1B81) or
        (codepoint >= 0x1BA2 and codepoint <= 0x1BA5) or
        (codepoint >= 0x1BA8 and codepoint <= 0x1BA9) or
        (codepoint >= 0x1BAB and codepoint <= 0x1BAD) or
        codepoint == 0x1BE6 or
        (codepoint >= 0x1BE8 and codepoint <= 0x1BE9) or
        codepoint == 0x1BED or
        (codepoint >= 0x1BEF and codepoint <= 0x1BF1) or
        (codepoint >= 0x1C2C and codepoint <= 0x1C33) or
        (codepoint >= 0x1C36 and codepoint <= 0x1C37) or
        codepoint == 0x1CD0 or
        (codepoint >= 0x1CD2 and codepoint <= 0x1CD2) or
        (codepoint >= 0x1CD4 and codepoint <= 0x1CE0) or
        (codepoint >= 0x1CE2 and codepoint <= 0x1CE8) or
        codepoint == 0x1CED or
        codepoint == 0x1CF4 or
        codepoint == 0x1CF8 or
        codepoint == 0x1CF9 or
        (codepoint >= 0x1DC0 and codepoint <= 0x1DFF) or
        (codepoint >= 0x20D0 and codepoint <= 0x20FF) or
        (codepoint >= 0xFE20 and codepoint <= 0xFE2F);
}

fn isWideCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x1100 and codepoint <= 0x115F) or
        codepoint == 0x2329 or
        codepoint == 0x232A or
        (codepoint >= 0x2E80 and codepoint <= 0x303E) or
        (codepoint >= 0x3040 and codepoint <= 0xA4CF) or
        (codepoint >= 0xAC00 and codepoint <= 0xD7A3) or
        (codepoint >= 0xF900 and codepoint <= 0xFAFF) or
        (codepoint >= 0xFE10 and codepoint <= 0xFE19) or
        (codepoint >= 0xFE30 and codepoint <= 0xFE6F) or
        (codepoint >= 0xFF00 and codepoint <= 0xFF60) or
        (codepoint >= 0xFFE0 and codepoint <= 0xFFE6) or
        (codepoint >= 0x20000 and codepoint <= 0x3FFFD);
}

test "visible width ignores ANSI escape sequences" {
    try std.testing.expectEqual(@as(usize, 8), visibleWidth("\x1b[31mred\x1b[0m blue"));
}

test "visible width counts CJK and emoji as wide graphemes" {
    try std.testing.expectEqual(@as(usize, 8), visibleWidth("ab你好🙂"));
    try std.testing.expectEqual(@as(usize, 2), visibleWidth("👩‍💻"));
}

test "wrap text preserves ANSI state across wrapped lines" {
    const allocator = std.testing.allocator;
    var lines = LineList.empty;
    defer component.freeLines(allocator, &lines);

    try wrapTextWithAnsi(allocator, "\x1b[31mhello world\x1b[0m", 5, &lines);

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("\x1b[31mhello\x1b[0m", lines.items[0]);
    try std.testing.expectEqualStrings("\x1b[31m worl\x1b[0m", lines.items[1]);
    try std.testing.expectEqualStrings("\x1b[31md\x1b[0m", lines.items[2]);
}

test "wrap text uses display width for wide graphemes" {
    const allocator = std.testing.allocator;
    var lines = LineList.empty;
    defer component.freeLines(allocator, &lines);

    try wrapTextWithAnsi(allocator, "ab你好🙂", 4, &lines);

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("ab你", lines.items[0]);
    try std.testing.expectEqualStrings("好🙂", lines.items[1]);
}

test "slice visible range preserves active ANSI state" {
    const allocator = std.testing.allocator;

    const slice = try sliceVisibleAlloc(allocator, "\x1b[31mhello\x1b[0m world", 1, 3);
    defer allocator.free(slice);

    try std.testing.expectEqualStrings("\x1b[31mell\x1b[0m", slice);
}

test "slice visible range respects wide grapheme boundaries" {
    const allocator = std.testing.allocator;

    const slice = try sliceVisibleAlloc(allocator, "ab你好🙂", 2, 4);
    defer allocator.free(slice);

    try std.testing.expectEqualStrings("你好", slice);
}

test "parseHexColor parses rgb triplets" {
    const color = parseHexColor("#123abc").?;
    try std.testing.expectEqual(@as(u8, 0x12), color.r);
    try std.testing.expectEqual(@as(u8, 0x3a), color.g);
    try std.testing.expectEqual(@as(u8, 0xbc), color.b);
    try std.testing.expect(parseHexColor("abc") == null);
}

test "applyHorizontalGradientAlloc colors visible grapheme clusters" {
    const allocator = std.testing.allocator;

    const gradient = try applyHorizontalGradientAlloc(
        allocator,
        "A🙂B",
        .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 255 },
    );
    defer allocator.free(gradient);

    try std.testing.expect(std.mem.indexOf(u8, gradient, "\x1b[38;2;255;0;0mA") != null);
    try std.testing.expect(std.mem.indexOf(u8, gradient, "\x1b[38;2;127;0;127m🙂") != null);
    try std.testing.expect(std.mem.indexOf(u8, gradient, "\x1b[38;2;0;0;255mB") != null);
    try std.testing.expect(std.mem.endsWith(u8, gradient, "\x1b[0m"));
}
