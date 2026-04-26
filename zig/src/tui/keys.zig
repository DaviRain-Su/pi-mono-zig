const std = @import("std");
const vaxis = @import("vaxis");

pub const PrintableKey = struct {
    bytes: [4]u8 = [_]u8{0} ** 4,
    len: u3 = 0,

    pub fn fromSlice(input: []const u8) PrintableKey {
        var key = PrintableKey{
            .len = @intCast(input.len),
        };
        @memcpy(key.bytes[0..input.len], input);
        return key;
    }

    pub fn slice(self: *const PrintableKey) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Key = union(enum) {
    printable: PrintableKey,
    ctrl: u8,
    tab,
    enter,
    backspace,
    escape,
    shift_tab,
    up,
    down,
    left,
    right,
    ctrl_left,
    ctrl_right,
    home,
    end,
    insert,
    delete,
    page_up,
    page_down,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    bracketed_paste_start,
    bracketed_paste_end,
    unknown_escape,
};

pub const KeyModifiers = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    _reserved: u4 = 0,

    pub fn hasAny(self: KeyModifiers) bool {
        return self.shift or self.alt or self.ctrl or self.super;
    }

    pub fn fromCsiModifierParameter(parameter: u16) KeyModifiers {
        const bits = if (parameter > 0) parameter - 1 else 0;
        return .{
            .shift = (bits & 1) != 0,
            .alt = (bits & 2) != 0,
            .ctrl = (bits & 4) != 0,
            .super = (bits & 8) != 0,
        };
    }
};

pub const KeyEventType = enum {
    press,
    repeat,
    release,
};

pub const ParsedKey = struct {
    key: Key,
    consumed: usize,
    modifiers: KeyModifiers = .{},
    event_type: KeyEventType = .press,
};

pub const ProtocolEvent = union(enum) {
    kitty_keyboard: u16,
};

pub const InputEvent = union(enum) {
    key: Key,
    paste: []const u8,
    protocol: ProtocolEvent,
};

pub const ParsedInput = struct {
    event: InputEvent,
    consumed: usize,
    modifiers: KeyModifiers = .{},
    event_type: KeyEventType = .press,
};

pub const ParseResult = union(enum) {
    parsed: ParsedKey,
    need_more_bytes,
};

pub const InputParseResult = union(enum) {
    parsed: ParsedInput,
    need_more_bytes,
};

const ParseMode = enum {
    buffering,
    flush,
};

const BRACKETED_PASTE_START = "\x1b[200~";
const BRACKETED_PASTE_END = "\x1b[201~";
const KITTY_PROTOCOL_RESPONSE_PREFIX = "\x1b[?";

pub fn parseInputEvent(input: []const u8) ?InputParseResult {
    return parseInputEventWithMode(input, .buffering);
}

pub fn flushInputEvent(input: []const u8) ?ParsedInput {
    const result = parseInputEventWithMode(input, .flush) orelse return null;
    return switch (result) {
        .parsed => |parsed_input| parsed_input,
        .need_more_bytes => null,
    };
}

pub fn parseKey(input: []const u8) ?ParseResult {
    return parseKeyWithMode(input, .buffering);
}

pub fn flushKey(input: []const u8) ?ParsedKey {
    const result = parseKeyWithMode(input, .flush) orelse return null;
    return switch (result) {
        .parsed => |parsed_key| parsed_key,
        .need_more_bytes => null,
    };
}

fn parseKeyWithMode(input: []const u8, mode: ParseMode) ?ParseResult {
    if (input.len == 0) return null;

    const first = input[0];
    if (first == '\r' or first == '\n') {
        return parsed(.enter, 1);
    }

    switch (first) {
        0x09 => return parsed(.tab, 1),
        0x7f, 0x08 => return parsed(.backspace, 1),
        0x1b => return parseEscapeSequence(input, mode),
        0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a, 0x1c...0x1f => return parsed(.{ .ctrl = @as(u8, 'a') + first - 1 }, 1),
        else => {},
    }

    if (first < 0x20) return null;

    const sequence_len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    if (input.len < sequence_len) {
        return .need_more_bytes;
    }

    return parsed(.{ .printable = PrintableKey.fromSlice(input[0..sequence_len]) }, sequence_len);
}

fn parseInputEventWithMode(input: []const u8, mode: ParseMode) ?InputParseResult {
    if (input.len == 0) return null;

    if (parseKittyProtocolResponse(input, mode)) |protocol_result| {
        return protocol_result;
    }

    if (matchesBracketedPastePrefix(input)) {
        return .need_more_bytes;
    }

    if (std.mem.startsWith(u8, input, BRACKETED_PASTE_START)) {
        const content_start = BRACKETED_PASTE_START.len;
        const end_relative = std.mem.indexOf(u8, input[content_start..], BRACKETED_PASTE_END) orelse return .need_more_bytes;
        const content_end = content_start + end_relative;
        return .{
            .parsed = .{
                .event = .{ .paste = input[content_start..content_end] },
                .consumed = content_end + BRACKETED_PASTE_END.len,
            },
        };
    }

    const result = parseKeyWithMode(input, mode) orelse return null;
    return switch (result) {
        .parsed => |parsed_key| .{
            .parsed = .{
                .event = .{ .key = parsed_key.key },
                .consumed = parsed_key.consumed,
                .modifiers = parsed_key.modifiers,
                .event_type = parsed_key.event_type,
            },
        },
        .need_more_bytes => .need_more_bytes,
    };
}

fn matchesBracketedPastePrefix(input: []const u8) bool {
    return input.len < BRACKETED_PASTE_START.len and std.mem.startsWith(u8, BRACKETED_PASTE_START, input);
}

fn parseKittyProtocolResponse(input: []const u8, mode: ParseMode) ?InputParseResult {
    if (!std.mem.startsWith(u8, input, KITTY_PROTOCOL_RESPONSE_PREFIX)) return null;

    const sequence_len = findCsiSequenceLength(input) orelse {
        return switch (mode) {
            .buffering => .need_more_bytes,
            .flush => null,
        };
    };

    const sequence = input[0..sequence_len];
    if (sequence[sequence.len - 1] != 'u') return null;
    if (sequence.len <= KITTY_PROTOCOL_RESPONSE_PREFIX.len + 1) return null;

    for (sequence[KITTY_PROTOCOL_RESPONSE_PREFIX.len .. sequence.len - 1]) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }

    const flags = std.fmt.parseInt(u16, sequence[KITTY_PROTOCOL_RESPONSE_PREFIX.len .. sequence.len - 1], 10) catch return null;
    return .{
        .parsed = .{
            .event = .{ .protocol = .{ .kitty_keyboard = flags } },
            .consumed = sequence.len,
        },
    };
}

fn parsed(key: Key, consumed: usize) ParseResult {
    return parsedWithDetails(key, consumed, .{}, .press);
}

fn parsedWithDetails(key: Key, consumed: usize, modifiers: KeyModifiers, event_type: KeyEventType) ParseResult {
    return .{
        .parsed = .{
            .key = key,
            .consumed = consumed,
            .modifiers = modifiers,
            .event_type = event_type,
        },
    };
}

pub fn parsedInputFromParsedKey(parsed_key: ParsedKey) ParsedInput {
    return .{
        .event = .{ .key = parsed_key.key },
        .consumed = parsed_key.consumed,
        .modifiers = parsed_key.modifiers,
        .event_type = parsed_key.event_type,
    };
}

pub fn parsedPasteInput(paste: []const u8) ParsedInput {
    return .{
        .event = .{ .paste = paste },
        .consumed = 0,
    };
}

pub fn parsedKeyFromVaxisKey(vaxis_key: vaxis.Key, event_type: KeyEventType) ?ParsedKey {
    const modifiers = keyModifiersFromVaxis(vaxis_key.mods);
    if (ctrlShortcutFromVaxisKey(vaxis_key, modifiers)) |ctrl| {
        return .{
            .key = .{ .ctrl = ctrl },
            .consumed = 0,
            .event_type = event_type,
        };
    }

    const result = buildParsedKeyFromCodepoint(
        preferredVaxisCodepoint(vaxis_key, modifiers),
        if (vaxis_key.shifted_codepoint) |shifted_codepoint|
            @as(u32, shifted_codepoint)
        else
            null,
        modifiers,
        event_type,
        0,
    ) orelse return null;
    return switch (result) {
        .parsed => |parsed_key| canonicalizeVaxisParsedKey(parsed_key),
        .need_more_bytes => unreachable,
    };
}

pub fn parsedInputFromVaxisKey(vaxis_key: vaxis.Key, event_type: KeyEventType) ?ParsedInput {
    const parsed_key = parsedKeyFromVaxisKey(vaxis_key, event_type) orelse return null;
    return parsedInputFromParsedKey(parsed_key);
}

fn preferredVaxisCodepoint(vaxis_key: vaxis.Key, modifiers: KeyModifiers) u32 {
    if (modifiers.ctrl or modifiers.alt or modifiers.super) {
        if (vaxis_key.base_layout_codepoint) |base_layout_codepoint| {
            return base_layout_codepoint;
        }
    }
    return vaxis_key.codepoint;
}

fn ctrlShortcutFromVaxisKey(vaxis_key: vaxis.Key, modifiers: KeyModifiers) ?u8 {
    if (!modifiers.ctrl or modifiers.alt or modifiers.shift or modifiers.super) return null;

    if (vaxis_key.codepoint == vaxis.Key.delete) return 'd';

    const shortcut_modifiers: vaxis.Key.Modifiers = .{ .ctrl = true };

    inline for ('a'..('z' + 1)) |letter| {
        if (vaxis_key.matchShortcut(letter, shortcut_modifiers)) return @intCast(letter);
    }
    inline for ('0'..('9' + 1)) |digit| {
        if (vaxis_key.matchShortcut(digit, shortcut_modifiers)) return @intCast(digit);
    }

    return null;
}

fn keyModifiersFromVaxis(modifiers: vaxis.Key.Modifiers) KeyModifiers {
    return .{
        .shift = modifiers.shift,
        .alt = modifiers.alt,
        .ctrl = modifiers.ctrl,
        .super = modifiers.super,
    };
}

fn canonicalizeVaxisParsedKey(parsed_key: ParsedKey) ParsedKey {
    var canonical = parsed_key;
    canonical.key = canonicalizeLegacyVaxisAltNavigation(canonical.key, canonical.modifiers);
    switch (canonical.key) {
        .ctrl, .ctrl_left, .ctrl_right => canonical.modifiers.ctrl = false,
        .shift_tab => canonical.modifiers.shift = false,
        else => {},
    }
    return canonical;
}

fn canonicalizeLegacyVaxisAltNavigation(key: Key, modifiers: KeyModifiers) Key {
    if (!modifiers.alt or modifiers.shift or modifiers.ctrl or modifiers.super) return key;
    switch (key) {
        .printable => |printable| {
            const text = printable.slice();
            if (std.mem.eql(u8, text, "b") or std.mem.eql(u8, text, "B")) return .left;
            if (std.mem.eql(u8, text, "f") or std.mem.eql(u8, text, "F")) return .right;
            if (std.mem.eql(u8, text, "p") or std.mem.eql(u8, text, "P")) return .up;
            if (std.mem.eql(u8, text, "n") or std.mem.eql(u8, text, "N")) return .down;
            return key;
        },
        else => return key,
    }
}

fn parseEscapeSequence(input: []const u8, mode: ParseMode) ParseResult {
    if (input.len == 1) {
        return switch (mode) {
            .buffering => .need_more_bytes,
            .flush => parsed(.escape, 1),
        };
    }

    return switch (input[1]) {
        '[' => parseCsiSequence(input, mode),
        'O' => parseSs3Sequence(input, mode),
        else => parseMetaEscapeSequence(input, mode),
    };
}

fn parseCsiSequence(input: []const u8, mode: ParseMode) ParseResult {
    const sequence_len = findCsiSequenceLength(input) orelse {
        return switch (mode) {
            .buffering => .need_more_bytes,
            .flush => parsed(.unknown_escape, input.len),
        };
    };

    return parseCompleteCsiSequence(input[0..sequence_len]);
}

fn findCsiSequenceLength(input: []const u8) ?usize {
    var index: usize = 2;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (byte >= 0x40 and byte <= 0x7e) return index + 1;
    }
    return null;
}

fn parseCompleteCsiSequence(sequence: []const u8) ParseResult {
    if (parseKittyCsiUSequence(sequence)) |result| return result;
    if (parseModifyOtherKeysSequence(sequence)) |result| return result;
    if (parseParameterizedSpecialSequence(sequence)) |result| return result;

    if (std.mem.eql(u8, sequence, "\x1b[A")) return parsed(.up, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[B")) return parsed(.down, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[C")) return parsed(.right, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[D")) return parsed(.left, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[1;5C") or std.mem.eql(u8, sequence, "\x1b[5C")) return parsed(.ctrl_right, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[1;5D") or std.mem.eql(u8, sequence, "\x1b[5D")) return parsed(.ctrl_left, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[H") or std.mem.eql(u8, sequence, "\x1b[1~") or std.mem.eql(u8, sequence, "\x1b[7~")) {
        return parsed(.home, sequence.len);
    }
    if (std.mem.eql(u8, sequence, "\x1b[F") or std.mem.eql(u8, sequence, "\x1b[4~") or std.mem.eql(u8, sequence, "\x1b[8~")) {
        return parsed(.end, sequence.len);
    }
    if (std.mem.eql(u8, sequence, "\x1b[Z")) return parsed(.shift_tab, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[2~")) return parsed(.insert, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[3~")) return parsed(.delete, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[5~") or std.mem.eql(u8, sequence, "\x1b[[5~")) return parsed(.page_up, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[6~") or std.mem.eql(u8, sequence, "\x1b[[6~")) return parsed(.page_down, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[200~")) return parsed(.bracketed_paste_start, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[201~")) return parsed(.bracketed_paste_end, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[11~") or std.mem.eql(u8, sequence, "\x1b[[A")) return parsed(.f1, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[12~") or std.mem.eql(u8, sequence, "\x1b[[B")) return parsed(.f2, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[13~") or std.mem.eql(u8, sequence, "\x1b[[C")) return parsed(.f3, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[14~") or std.mem.eql(u8, sequence, "\x1b[[D")) return parsed(.f4, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[15~") or std.mem.eql(u8, sequence, "\x1b[[E")) return parsed(.f5, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[17~")) return parsed(.f6, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[18~")) return parsed(.f7, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[19~")) return parsed(.f8, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[20~")) return parsed(.f9, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[21~")) return parsed(.f10, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[23~")) return parsed(.f11, sequence.len);
    if (std.mem.eql(u8, sequence, "\x1b[24~")) return parsed(.f12, sequence.len);
    return parsed(.unknown_escape, sequence.len);
}

const ParsedNumber = struct {
    value: u32,
    end: usize,
};

fn parseUnsignedDecimal(input: []const u8, start: usize) ?ParsedNumber {
    if (start >= input.len or !std.ascii.isDigit(input[start])) return null;

    var end = start;
    while (end < input.len and std.ascii.isDigit(input[end])) : (end += 1) {}

    const value = std.fmt.parseInt(u32, input[start..end], 10) catch return null;
    return .{ .value = value, .end = end };
}

fn parseEventType(value: u32) KeyEventType {
    return switch (value) {
        2 => .repeat,
        3 => .release,
        else => .press,
    };
}

fn parseKittyCsiUSequence(sequence: []const u8) ?ParseResult {
    if (sequence.len < 4 or sequence[sequence.len - 1] != 'u') return null;
    if (!std.mem.startsWith(u8, sequence, "\x1b[")) return null;
    if (sequence[2] == '?') return null;

    var index: usize = 2;
    const codepoint = parseUnsignedDecimal(sequence, index) orelse return null;
    index = codepoint.end;

    var shifted_codepoint: ?u32 = null;
    if (index < sequence.len and sequence[index] == ':') {
        index += 1;
        if (parseUnsignedDecimal(sequence, index)) |shifted| {
            shifted_codepoint = shifted.value;
            index = shifted.end;
        }

        if (index < sequence.len and sequence[index] == ':') {
            index += 1;
            if (parseUnsignedDecimal(sequence, index)) |base_layout| {
                index = base_layout.end;
            }
        }
    }

    var modifier_parameter: u16 = 1;
    var event_type: KeyEventType = .press;
    if (index < sequence.len and sequence[index] == ';') {
        const modifier = parseUnsignedDecimal(sequence, index + 1) orelse return null;
        modifier_parameter = std.math.cast(u16, modifier.value) orelse return null;
        index = modifier.end;

        if (index < sequence.len and sequence[index] == ':') {
            const event_value = parseUnsignedDecimal(sequence, index + 1) orelse return null;
            event_type = parseEventType(event_value.value);
            index = event_value.end;
        }
    }

    if (index != sequence.len - 1) return null;
    return buildParsedKeyFromCodepoint(
        codepoint.value,
        shifted_codepoint,
        KeyModifiers.fromCsiModifierParameter(modifier_parameter),
        event_type,
        sequence.len,
    );
}

fn parseModifyOtherKeysSequence(sequence: []const u8) ?ParseResult {
    if (sequence.len < 8 or sequence[sequence.len - 1] != '~') return null;
    if (!std.mem.startsWith(u8, sequence, "\x1b[27;")) return null;

    var index: usize = 5;
    const modifier = parseUnsignedDecimal(sequence, index) orelse return null;
    index = modifier.end;
    if (index >= sequence.len or sequence[index] != ';') return null;

    const codepoint = parseUnsignedDecimal(sequence, index + 1) orelse return null;
    index = codepoint.end;
    if (index != sequence.len - 1) return null;

    return buildParsedKeyFromCodepoint(
        codepoint.value,
        null,
        KeyModifiers.fromCsiModifierParameter(std.math.cast(u16, modifier.value) orelse return null),
        .press,
        sequence.len,
    );
}

fn parseParameterizedSpecialSequence(sequence: []const u8) ?ParseResult {
    if (!std.mem.startsWith(u8, sequence, "\x1b[")) return null;

    const final = sequence[sequence.len - 1];
    if (final != 'A' and final != 'B' and final != 'C' and final != 'D' and final != 'H' and final != 'F' and final != '~')
        return null;

    var index: usize = 2;
    const first = parseUnsignedDecimal(sequence, index) orelse return null;
    index = first.end;
    if (index >= sequence.len or sequence[index] != ';') return null;

    const modifier = parseUnsignedDecimal(sequence, index + 1) orelse return null;
    index = modifier.end;

    var event_type: KeyEventType = .press;
    if (index < sequence.len - 1 and sequence[index] == ':') {
        const event_value = parseUnsignedDecimal(sequence, index + 1) orelse return null;
        event_type = parseEventType(event_value.value);
        index = event_value.end;
    }

    if (index != sequence.len - 1) return null;

    const modifiers = KeyModifiers.fromCsiModifierParameter(std.math.cast(u16, modifier.value) orelse return null);
    const key: Key = switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => if (modifiers.ctrl and !modifiers.alt and !modifiers.shift and !modifiers.super) .ctrl_right else .right,
        'D' => if (modifiers.ctrl and !modifiers.alt and !modifiers.shift and !modifiers.super) .ctrl_left else .left,
        'H' => .home,
        'F' => .end,
        '~' => switch (first.value) {
            2 => .insert,
            3 => .delete,
            5 => .page_up,
            6 => .page_down,
            7 => .home,
            8 => .end,
            11 => .f1,
            12 => .f2,
            13 => .f3,
            14 => .f4,
            15 => .f5,
            17 => .f6,
            18 => .f7,
            19 => .f8,
            20 => .f9,
            21 => .f10,
            23 => .f11,
            24 => .f12,
            else => return null,
        },
        else => return null,
    };

    return parsedWithDetails(key, sequence.len, modifiers, event_type);
}

fn buildParsedKeyFromCodepoint(
    codepoint: u32,
    shifted_codepoint: ?u32,
    modifiers: KeyModifiers,
    event_type: KeyEventType,
    consumed: usize,
) ?ParseResult {
    const effective_codepoint = normalizeFunctionalCodepoint(if (modifiers.shift and shifted_codepoint != null) shifted_codepoint.? else codepoint);

    const key: Key = switch (effective_codepoint) {
        9 => if (modifiers.shift and !modifiers.alt and !modifiers.ctrl and !modifiers.super) .shift_tab else .tab,
        13, 57414 => .enter,
        27 => .escape,
        127 => .backspace,
        vaxis.Key.insert => .insert,
        vaxis.Key.delete => .delete,
        vaxis.Key.left => if (modifiers.ctrl and !modifiers.alt and !modifiers.shift and !modifiers.super) .ctrl_left else .left,
        vaxis.Key.right => if (modifiers.ctrl and !modifiers.alt and !modifiers.shift and !modifiers.super) .ctrl_right else .right,
        vaxis.Key.up => .up,
        vaxis.Key.down => .down,
        vaxis.Key.page_up => .page_up,
        vaxis.Key.page_down => .page_down,
        vaxis.Key.home => .home,
        vaxis.Key.end => .end,
        vaxis.Key.f1 => .f1,
        vaxis.Key.f2 => .f2,
        vaxis.Key.f3 => .f3,
        vaxis.Key.f4 => .f4,
        vaxis.Key.f5 => .f5,
        vaxis.Key.f6 => .f6,
        vaxis.Key.f7 => .f7,
        vaxis.Key.f8 => .f8,
        vaxis.Key.f9 => .f9,
        vaxis.Key.f10 => .f10,
        vaxis.Key.f11 => .f11,
        vaxis.Key.f12 => .f12,
        57399...57413, 57415, 57416 => printableKeyFromCodepoint(effective_codepoint) orelse return null,
        57417 => if (modifiers.ctrl and !modifiers.alt and !modifiers.shift and !modifiers.super) .ctrl_left else .left,
        57418 => if (modifiers.ctrl and !modifiers.alt and !modifiers.shift and !modifiers.super) .ctrl_right else .right,
        57419 => .up,
        57420 => .down,
        57421 => .page_up,
        57422 => .page_down,
        57423 => .home,
        57424 => .end,
        57425 => .insert,
        57426 => .delete,
        else => keyFromCodepoint(effective_codepoint, modifiers) orelse return null,
    };

    return parsedWithDetails(key, consumed, modifiers, event_type);
}

fn keyFromCodepoint(codepoint: u32, modifiers: KeyModifiers) ?Key {
    if (asciiControlKeyFromCodepoint(codepoint)) |ctrl| {
        return .{ .ctrl = ctrl };
    }

    switch (codepoint) {
        9 => return .tab,
        13 => return .enter,
        27 => return .escape,
        127 => return .backspace,
        32 => return .{ .printable = PrintableKey.fromSlice(" ") },
        else => {},
    }

    if (modifiers.ctrl and !modifiers.alt and !modifiers.shift and !modifiers.super and isAsciiCtrlMappable(codepoint)) {
        return .{ .ctrl = asciiCtrlValue(codepoint) };
    }

    return printableKeyFromCodepoint(codepoint);
}

fn asciiControlKeyFromCodepoint(codepoint: u32) ?u8 {
    return switch (codepoint) {
        0x01...0x07 => @intCast('a' + (codepoint - 1)),
        0x0B, 0x0C => @intCast('a' + (codepoint - 1)),
        0x0E...0x1A => @intCast('a' + (codepoint - 1)),
        0x1C...0x1F => @intCast('a' + (codepoint - 1)),
        else => null,
    };
}

fn printableKeyFromCodepoint(codepoint: u32) ?Key {
    var utf8: [4]u8 = undefined;
    const scalar = std.math.cast(u21, codepoint) orelse return null;
    const length = std.unicode.utf8Encode(scalar, &utf8) catch return null;
    return .{ .printable = PrintableKey.fromSlice(utf8[0..length]) };
}

fn isAsciiCtrlMappable(codepoint: u32) bool {
    return (codepoint >= 'a' and codepoint <= 'z') or (codepoint >= 'A' and codepoint <= 'Z');
}

fn asciiCtrlValue(codepoint: u32) u8 {
    return @intCast(std.ascii.toLower(@as(u8, @intCast(codepoint))));
}

fn normalizeFunctionalCodepoint(codepoint: u32) u32 {
    return switch (codepoint) {
        57399 => '0',
        57400 => '1',
        57401 => '2',
        57402 => '3',
        57403 => '4',
        57404 => '5',
        57405 => '6',
        57406 => '7',
        57407 => '8',
        57408 => '9',
        57409 => '.',
        57410 => '/',
        57411 => '*',
        57412 => '-',
        57413 => '+',
        57415 => '=',
        57416 => ',',
        else => codepoint,
    };
}

fn parseSs3Sequence(input: []const u8, mode: ParseMode) ParseResult {
    if (input.len < 3) {
        return switch (mode) {
            .buffering => .need_more_bytes,
            .flush => parsed(.unknown_escape, input.len),
        };
    }

    return switch (input[2]) {
        'A' => parsed(.up, 3),
        'B' => parsed(.down, 3),
        'C' => parsed(.right, 3),
        'D' => parsed(.left, 3),
        'c' => parsed(.ctrl_right, 3),
        'd' => parsed(.ctrl_left, 3),
        'H' => parsed(.home, 3),
        'F' => parsed(.end, 3),
        'P' => parsed(.f1, 3),
        'Q' => parsed(.f2, 3),
        'R' => parsed(.f3, 3),
        'S' => parsed(.f4, 3),
        else => parsed(.unknown_escape, 3),
    };
}

fn parseMetaEscapeSequence(input: []const u8, mode: ParseMode) ParseResult {
    const sequence_len = 1 + (std.unicode.utf8ByteSequenceLength(input[1]) catch 1);
    if (input.len < sequence_len) {
        return switch (mode) {
            .buffering => .need_more_bytes,
            .flush => parsed(.unknown_escape, input.len),
        };
    }
    return parsed(.unknown_escape, sequence_len);
}

test "parse printable keys" {
    const ascii = parseKey("a").?;
    try std.testing.expectEqualDeep(ParseResult{
        .parsed = .{
            .key = .{ .printable = PrintableKey.fromSlice("a") },
            .consumed = 1,
        },
    }, ascii);

    const utf8 = parseKey("é").?;
    try std.testing.expectEqualDeep(ParseResult{
        .parsed = .{
            .key = .{ .printable = PrintableKey.fromSlice("é") },
            .consumed = 2,
        },
    }, utf8);
}

test "parse arrow keys from escape sequences" {
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .up, .consumed = 3 } }, parseKey("\x1b[A").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .down, .consumed = 3 } }, parseKey("\x1bOB").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .right, .consumed = 3 } }, parseKey("\x1b[C").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .left, .consumed = 3 } }, parseKey("\x1bOD").?);
}

test "parse enter backspace and ctrl sequences" {
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .enter, .consumed = 1 } }, parseKey("\r").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .tab, .consumed = 1 } }, parseKey("\t").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .backspace, .consumed = 1 } }, parseKey("\x7f").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .{ .ctrl = 'c' }, .consumed = 1 } }, parseKey("\x03").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .{ .ctrl = 'd' }, .consumed = 1 } }, parseKey("\x04").?);
}

test "split escape sequences request more bytes before parsing" {
    try std.testing.expectEqualDeep(ParseResult.need_more_bytes, parseKey("\x1b").?);
    try std.testing.expectEqualDeep(ParseResult.need_more_bytes, parseKey("\x1b[").?);
    try std.testing.expectEqualDeep(ParseResult.need_more_bytes, parseKey("\x1b[20").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .f9, .consumed = 5 } }, parseKey("\x1b[20~").?);
}

test "flushKey resolves standalone escape and discards incomplete escape sequences" {
    try std.testing.expectEqualDeep(ParsedKey{ .key = .escape, .consumed = 1 }, flushKey("\x1b").?);
    try std.testing.expectEqualDeep(ParsedKey{ .key = .unknown_escape, .consumed = 2 }, flushKey("\x1b[").?);
}

test "flushKey keeps incomplete UTF-8 buffered until the sequence is complete" {
    try std.testing.expectEqualDeep(ParseResult.need_more_bytes, parseKey("\xc3").?);
    try std.testing.expect(flushKey("\xc3") == null);
    try std.testing.expectEqualDeep(ParsedKey{
        .key = .{ .printable = PrintableKey.fromSlice("é") },
        .consumed = 2,
    }, flushKey("é").?);
}

test "parse home end function and bracketed paste sequences" {
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .home, .consumed = 3 } }, parseKey("\x1bOH").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .end, .consumed = 3 } }, parseKey("\x1bOF").?);
    try std.testing.expectEqualDeep(ParseResult{
        .parsed = .{
            .key = .ctrl_left,
            .consumed = 6,
            .modifiers = .{ .ctrl = true },
        },
    }, parseKey("\x1b[1;5D").?);
    try std.testing.expectEqualDeep(ParseResult{
        .parsed = .{
            .key = .ctrl_right,
            .consumed = 6,
            .modifiers = .{ .ctrl = true },
        },
    }, parseKey("\x1b[1;5C").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .ctrl_left, .consumed = 3 } }, parseKey("\x1bOd").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .ctrl_right, .consumed = 3 } }, parseKey("\x1bOc").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .page_up, .consumed = 4 } }, parseKey("\x1b[5~").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .f1, .consumed = 3 } }, parseKey("\x1bOP").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .f12, .consumed = 5 } }, parseKey("\x1b[24~").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .bracketed_paste_start, .consumed = 6 } }, parseKey("\x1b[200~").?);
    try std.testing.expectEqualDeep(ParseResult{ .parsed = .{ .key = .bracketed_paste_end, .consumed = 6 } }, parseKey("\x1b[201~").?);
}

test "parseInputEvent returns bracketed paste content as a single event" {
    const input = "\x1b[200~hello\nworld\x1b[201~!";
    const result = parseInputEvent(input).?;
    try std.testing.expect(result == .parsed);
    try std.testing.expectEqual(@as(usize, 23), result.parsed.consumed);
    switch (result.parsed.event) {
        .paste => |content| try std.testing.expectEqualStrings("hello\nworld", content),
        else => return error.UnexpectedKey,
    }
}

test "parseInputEvent waits for a complete bracketed paste" {
    try std.testing.expectEqualDeep(InputParseResult.need_more_bytes, parseInputEvent("\x1b[20").?);
    try std.testing.expectEqualDeep(InputParseResult.need_more_bytes, parseInputEvent("\x1b[200~partial").?);
    try std.testing.expect(flushInputEvent("\x1b[200~partial") == null);
}

test "parseInputEvent assembles split UTF-8 codepoints across reads" {
    try std.testing.expectEqualDeep(InputParseResult.need_more_bytes, parseInputEvent("\xc3").?);
    try std.testing.expect(flushInputEvent("\xc3") == null);

    const two_byte = parseInputEvent("é").?;
    try std.testing.expect(two_byte == .parsed);
    try std.testing.expectEqual(@as(usize, 2), two_byte.parsed.consumed);
    switch (two_byte.parsed.event) {
        .key => |key| try std.testing.expectEqualDeep(Key{ .printable = PrintableKey.fromSlice("é") }, key),
        else => return error.UnexpectedPaste,
    }

    try std.testing.expectEqualDeep(InputParseResult.need_more_bytes, parseInputEvent("\xf0\x9f").?);
    try std.testing.expect(flushInputEvent("\xf0\x9f") == null);
    try std.testing.expectEqualDeep(InputParseResult.need_more_bytes, parseInputEvent("\xf0\x9f\x99").?);
    try std.testing.expect(flushInputEvent("\xf0\x9f\x99") == null);

    const four_byte = parseInputEvent("🙂").?;
    try std.testing.expect(four_byte == .parsed);
    try std.testing.expectEqual(@as(usize, 4), four_byte.parsed.consumed);
    switch (four_byte.parsed.event) {
        .key => |key| try std.testing.expectEqualDeep(Key{ .printable = PrintableKey.fromSlice("🙂") }, key),
        else => return error.UnexpectedPaste,
    }
}

test "parse kitty protocol response as a control event" {
    const result = parseInputEvent("\x1b[?31u").?;
    try std.testing.expect(result == .parsed);
    try std.testing.expectEqual(@as(usize, 6), result.parsed.consumed);

    switch (result.parsed.event) {
        .protocol => |protocol| switch (protocol) {
            .kitty_keyboard => |flags| try std.testing.expectEqual(@as(u16, 31), flags),
        },
        else => return error.ExpectedProtocolEvent,
    }
}

test "parse kitty CSI-u modifiers and release events" {
    const result = parseKey("\x1b[1;5:3D").?;
    try std.testing.expectEqualDeep(ParseResult{
        .parsed = .{
            .key = .ctrl_left,
            .consumed = 8,
            .modifiers = .{ .ctrl = true },
            .event_type = .release,
        },
    }, result);
}

test "parse kitty CSI-u printable keys with shifted alternate codepoints" {
    const result = parseKey("\x1b[97:65;2u").?;
    try std.testing.expectEqualDeep(ParseResult{
        .parsed = .{
            .key = .{ .printable = PrintableKey.fromSlice("A") },
            .consumed = 10,
            .modifiers = .{ .shift = true },
        },
    }, result);
}

test "parse modifyOtherKeys and kitty special-key modifiers" {
    try std.testing.expectEqualDeep(ParseResult{
        .parsed = .{
            .key = .enter,
            .consumed = 10,
            .modifiers = .{ .alt = true },
        },
    }, parseKey("\x1b[27;3;13~").?);

    try std.testing.expectEqualDeep(ParseResult{
        .parsed = .{
            .key = .page_up,
            .consumed = 8,
            .modifiers = .{ .super = true },
            .event_type = .repeat,
        },
    }, parseKey("\x1b[5;9:2~").?);
}

test "parsedInputFromVaxisKey preserves ctrl modifiers and release events" {
    const result = parsedInputFromVaxisKey(.{
        .codepoint = 'c',
        .mods = .{ .ctrl = true },
    }, .release).?;

    try std.testing.expectEqualDeep(ParsedInput{
        .event = .{ .key = .{ .ctrl = 'c' } },
        .consumed = 0,
        .event_type = .release,
    }, result);
}

test "parsedInputFromVaxisKey maps ascii control bytes to ctrl keys" {
    const result = parsedInputFromVaxisKey(.{
        .codepoint = 0x04,
    }, .press).?;

    try std.testing.expectEqualDeep(ParsedInput{
        .event = .{ .key = .{ .ctrl = 'd' } },
        .consumed = 0,
        .event_type = .press,
    }, result);
}

test "parsedInputFromVaxisKey prefers base layout codepoint for ctrl shortcuts" {
    const result = parsedInputFromVaxisKey(.{
        .codepoint = '\\',
        .base_layout_codepoint = 'd',
        .mods = .{ .ctrl = true },
    }, .press).?;

    try std.testing.expectEqualDeep(ParsedInput{
        .event = .{ .key = .{ .ctrl = 'd' } },
        .consumed = 0,
        .event_type = .press,
    }, result);
}

test "parsedInputFromVaxisKey maps ctrl shortcut matches from libvaxis special keys" {
    const result = parsedInputFromVaxisKey(.{
        .codepoint = vaxis.Key.delete,
        .base_layout_codepoint = 'd',
        .mods = .{ .ctrl = true },
    }, .press).?;

    try std.testing.expectEqualDeep(ParsedInput{
        .event = .{ .key = .{ .ctrl = 'd' } },
        .consumed = 0,
        .event_type = .press,
    }, result);
}

test "parsedInputFromVaxisKey maps special keys with modifiers" {
    const result = parsedInputFromVaxisKey(.{
        .codepoint = vaxis.Key.left,
        .mods = .{ .ctrl = true },
    }, .press).?;

    try std.testing.expectEqualDeep(ParsedInput{
        .event = .{ .key = .ctrl_left },
        .consumed = 0,
        .event_type = .press,
    }, result);
}

test "parsedInputFromVaxisKey maps legacy alt navigation aliases from libvaxis" {
    const up = parsedInputFromVaxisKey(.{
        .codepoint = 'p',
        .mods = .{ .alt = true },
    }, .press).?;
    try std.testing.expectEqualDeep(ParsedInput{
        .event = .{ .key = .up },
        .consumed = 0,
        .modifiers = .{ .alt = true },
        .event_type = .press,
    }, up);

    const left = parsedInputFromVaxisKey(.{
        .codepoint = 'b',
        .mods = .{ .alt = true },
    }, .press).?;
    try std.testing.expectEqualDeep(ParsedInput{
        .event = .{ .key = .left },
        .consumed = 0,
        .modifiers = .{ .alt = true },
        .event_type = .press,
    }, left);
}

test "parsedInputFromVaxisKey prefers shifted printable codepoints" {
    const result = parsedInputFromVaxisKey(.{
        .codepoint = 'a',
        .shifted_codepoint = 'A',
        .mods = .{ .shift = true },
    }, .press).?;

    try std.testing.expectEqualDeep(ParsedInput{
        .event = .{ .key = .{ .printable = PrintableKey.fromSlice("A") } },
        .consumed = 0,
        .modifiers = .{ .shift = true },
        .event_type = .press,
    }, result);
}
