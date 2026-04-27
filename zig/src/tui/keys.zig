const std = @import("std");
const vaxis = @import("vaxis");

const ESC = "\x1b";

pub const PrintableKey = struct {
    pub const max_bytes: usize = 32;

    bytes: [max_bytes]u8 = [_]u8{0} ** max_bytes,
    len: u8 = 0,

    pub fn fromSlice(input: []const u8) PrintableKey {
        std.debug.assert(input.len <= max_bytes);
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
};

pub const KeyEventType = enum {
    press,
    repeat,
    release,
};

pub const ProtocolEvent = union(enum) {
    kitty_keyboard: u16,
};

pub const MouseWheelDirection = enum {
    up,
    down,
};

pub const MouseWheelInput = struct {
    direction: MouseWheelDirection,
    row: i16,
    col: i16,
};

pub const InputEvent = union(enum) {
    key: Key,
    paste: []const u8,
    protocol: ProtocolEvent,
    mouse_wheel: MouseWheelInput,
};

pub const ParsedInput = struct {
    event: InputEvent,
    consumed: usize,
    modifiers: KeyModifiers = .{},
    event_type: KeyEventType = .press,
};

pub fn parsedPasteInput(paste: []const u8) ParsedInput {
    return .{
        .event = .{ .paste = paste },
        .consumed = 0,
    };
}

pub fn parsedMouseWheelInput(mouse: vaxis.Mouse) ?ParsedInput {
    if (mouse.type != .press) return null;
    const direction: MouseWheelDirection = switch (mouse.button) {
        .wheel_up => .up,
        .wheel_down => .down,
        else => return null,
    };
    return .{
        .event = .{ .mouse_wheel = .{
            .direction = direction,
            .row = mouse.row,
            .col = mouse.col,
        } },
        .consumed = 0,
    };
}

pub fn parsedInputFromVaxisKey(vaxis_key: vaxis.Key, event_type: KeyEventType) ?ParsedInput {
    var modifiers = keyModifiersFromVaxis(vaxis_key.mods);
    if (ctrlShortcutFromVaxisKey(vaxis_key, modifiers)) |ctrl| {
        return parsedKeyInput(.{ .ctrl = ctrl }, .{}, event_type);
    }

    if (printableKeyFromVaxisText(vaxis_key, modifiers)) |printable_key| {
        return parsedKeyInput(printable_key, modifiers, event_type);
    }

    var key = keyFromVaxisCodepoint(
        preferredVaxisCodepoint(vaxis_key, modifiers),
        if (vaxis_key.shifted_codepoint) |shifted_codepoint|
            @as(u32, shifted_codepoint)
        else
            null,
        modifiers,
    ) orelse return null;

    key = canonicalizeLegacyVaxisAltNavigation(key, modifiers);
    switch (key) {
        .ctrl, .ctrl_left, .ctrl_right => modifiers.ctrl = false,
        .shift_tab => modifiers.shift = false,
        else => {},
    }

    return parsedKeyInput(key, modifiers, event_type);
}

/// When vaxis provides a `text` field (kitty CSI u text-as-codepoints, or grapheme
/// cluster aggregation in legacy ground state), prefer it over the synthesized codepoint
/// for printable input. This is required for:
///   - IME-committed CJK text (Ghostty sends kitty CSI u with codepoint=0 + text)
///   - Multi-codepoint graphemes (ZWJ emoji, regional-indicator flags) where vaxis
///     reports `codepoint=Key.multicodepoint` (0x110001) plus the joined text.
fn printableKeyFromVaxisText(vaxis_key: vaxis.Key, modifiers: KeyModifiers) ?Key {
    const text = vaxis_key.text orelse return null;
    if (text.len == 0 or text.len > PrintableKey.max_bytes) return null;
    // Don't override ctrl/alt/super shortcuts (those are handled elsewhere).
    if (modifiers.ctrl or modifiers.alt or modifiers.super) return null;
    // Reject control bytes and pure ASCII whose codepoint path already yields the
    // correct mapping (printable ASCII, tab, enter, etc.).
    if (text.len == 1) {
        const b = text[0];
        if (b < 0x20 or b == 0x7F) return null;
    }
    return .{ .printable = PrintableKey.fromSlice(text) };
}

fn parsedKeyInput(key: Key, modifiers: KeyModifiers, event_type: KeyEventType) ParsedInput {
    return .{
        .event = .{ .key = key },
        .consumed = 0,
        .modifiers = modifiers,
        .event_type = event_type,
    };
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

fn keyFromVaxisCodepoint(
    codepoint: u32,
    shifted_codepoint: ?u32,
    modifiers: KeyModifiers,
) ?Key {
    const effective_codepoint = normalizeFunctionalCodepoint(if (modifiers.shift and shifted_codepoint != null) shifted_codepoint.? else codepoint);

    return switch (effective_codepoint) {
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
        57399...57413, 57415, 57416 => printableKeyFromCodepoint(effective_codepoint),
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
        else => keyFromCodepoint(effective_codepoint, modifiers),
    };
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

test "vaxis.Parser emits bracketed paste boundary events" {
    var parser: vaxis.Parser = .{};

    const start = try parser.parse(ESC ++ "[200~", std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), start.n);
    switch (start.event.?) {
        .paste_start => {},
        else => return error.ExpectedPasteStart,
    }

    const end = try parser.parse(ESC ++ "[201~", std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), end.n);
    switch (end.event.?) {
        .paste_end => {},
        else => return error.ExpectedPasteEnd,
    }
}

test "parsedInputFromVaxisKey maps key events emitted by vaxis.Parser" {
    var parser: vaxis.Parser = .{};
    const result = try parser.parse("a", std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.n);

    const key = switch (result.event.?) {
        .key_press => |key| key,
        else => return error.ExpectedKeyPress,
    };
    const parsed = parsedInputFromVaxisKey(key, .press).?;

    try std.testing.expectEqualDeep(ParsedInput{
        .event = .{ .key = .{ .printable = PrintableKey.fromSlice("a") } },
        .consumed = 0,
    }, parsed);
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

// Regressions for kitty-keyboard / IME text input. See AGENTS.md notes on
// Ghostty CJK breakage: vaxis emits a key event with `codepoint=0` (or
// `Key.multicodepoint`) plus the typed bytes in `text`. Without honouring
// `text` we drop or corrupt the input.
test "parsedInputFromVaxisKey honours vaxis text for kitty CJK codepoint" {
    // Ghostty kitty CSI u "你" (U+4F60) with text-as-codepoint set.
    const result = parsedInputFromVaxisKey(.{
        .codepoint = 0x4F60,
        .text = "你",
    }, .press).?;
    try std.testing.expectEqualDeep(ParsedInput{
        .event = .{ .key = .{ .printable = PrintableKey.fromSlice("你") } },
        .consumed = 0,
    }, result);
}

test "parsedInputFromVaxisKey honours IME text with zero codepoint" {
    // Ghostty IME commit: kitty CSI 0;;text u, i.e. cp=0 + multi-codepoint text.
    const result = parsedInputFromVaxisKey(.{
        .codepoint = 0,
        .text = "你好",
    }, .press).?;
    try std.testing.expectEqualDeep(ParsedInput{
        .event = .{ .key = .{ .printable = PrintableKey.fromSlice("你好") } },
        .consumed = 0,
    }, result);
}

test "parsedInputFromVaxisKey honours multicodepoint text for ZWJ emoji" {
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"; // 👨‍👩‍👧
    const result = parsedInputFromVaxisKey(.{
        .codepoint = vaxis.Key.multicodepoint,
        .text = family,
    }, .press).?;
    try std.testing.expectEqualDeep(ParsedInput{
        .event = .{ .key = .{ .printable = PrintableKey.fromSlice(family) } },
        .consumed = 0,
    }, result);
}

test "parsedInputFromVaxisKey honours multicodepoint text for regional flag" {
    const flag = "\u{1F1FA}\u{1F1F8}"; // 🇺🇸
    const result = parsedInputFromVaxisKey(.{
        .codepoint = vaxis.Key.multicodepoint,
        .text = flag,
    }, .press).?;
    try std.testing.expectEqualDeep(ParsedInput{
        .event = .{ .key = .{ .printable = PrintableKey.fromSlice(flag) } },
        .consumed = 0,
    }, result);
}

test "parsedInputFromVaxisKey ignores text for ascii control bytes" {
    // ascii ctrl path must not be hijacked by the text-preferring branch.
    const result = parsedInputFromVaxisKey(.{
        .codepoint = 0x04,
        .text = "\x04",
    }, .press).?;
    try std.testing.expectEqualDeep(ParsedInput{
        .event = .{ .key = .{ .ctrl = 'd' } },
        .consumed = 0,
    }, result);
}

test "parsedInputFromVaxisKey does not use text when ctrl/alt held" {
    // Alt+f must still map to .right via the alt-navigation canonicaliser even if
    // vaxis includes "f" in the text field.
    const result = parsedInputFromVaxisKey(.{
        .codepoint = 'f',
        .text = "f",
        .mods = .{ .alt = true },
    }, .press).?;
    try std.testing.expectEqualDeep(ParsedInput{
        .event = .{ .key = .right },
        .consumed = 0,
        .modifiers = .{ .alt = true },
    }, result);
}
