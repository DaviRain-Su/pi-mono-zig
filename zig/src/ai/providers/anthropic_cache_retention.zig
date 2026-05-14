//! `PI_CACHE_RETENTION` and stream option resolution for Anthropic prompt cache.

const std = @import("std");
const types = @import("../types.zig");

pub fn processCacheRetentionEnv() ?[]const u8 {
    const value = std.c.getenv("PI_CACHE_RETENTION") orelse return null;
    return std.mem.span(value);
}

pub fn resolveCacheRetention(cache_retention: types.CacheRetention, pi_cache_retention_env: ?[]const u8) types.CacheRetention {
    return switch (cache_retention) {
        .unset => if (pi_cache_retention_env) |value|
            if (std.mem.eql(u8, value, "long")) .long else .short
        else
            .short,
        .none, .short, .long => cache_retention,
    };
}

pub fn resolveOptionsCacheRetention(options: ?types.StreamOptions) types.CacheRetention {
    return resolveCacheRetention(if (options) |stream_options| stream_options.cache_retention else .unset, processCacheRetentionEnv());
}
