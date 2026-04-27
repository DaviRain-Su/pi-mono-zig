const theme_mod = @import("../theme.zig");

pub fn palette() theme_mod.PaletteTemplate {
    return .{
        .primary = "#3451b2",
        .secondary = "#6f42c1",
        .success = "#2f8f4e",
        .warning = "#a05a00",
        .@"error" = "#c1392b",
        .background = "#f6f8fa",
        .foreground = "#1f2328",
        .border = "#afb8c1",
        .muted = "#57606a",
    };
}
