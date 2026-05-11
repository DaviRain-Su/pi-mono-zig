const common = @import("../common.zig");
pub const descriptor = common.descriptor("i18n", "utils/i18n.ts", .util);

pub fn fallback(locale_key: []const u8) []const u8 {
    return locale_key;
}
