const std = @import("std");

/// PKCE code verifier and challenge pair
pub const PKCEPair = struct {
    verifier: []const u8,
    challenge: []const u8,
    
    pub fn deinit(self: *const PKCEPair, allocator: std.mem.Allocator) void {
        allocator.free(self.verifier);
        allocator.free(self.challenge);
    }
};

/// Generate PKCE code verifier and challenge using S256 method
pub fn generatePKCE(allocator: std.mem.Allocator) !PKCEPair {
    // Generate random verifier (32 bytes = 43 chars base64url)
    var verifier_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&verifier_bytes);
    
    const verifier = try base64urlEncode(allocator, &verifier_bytes);
    errdefer allocator.free(verifier);
    
    // Compute SHA-256 challenge
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &hash, .{});
    
    const challenge = try base64urlEncode(allocator, &hash);
    errdefer allocator.free(challenge);
    
    return PKCEPair{
        .verifier = verifier,
        .challenge = challenge,
    };
}

/// Base64url encode bytes (no padding)
fn base64urlEncode(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const base64_len = std.base64.standard.Encoder.calcSize(bytes.len);
    // base64url uses same length but without padding
    const result = try allocator.alloc(u8, base64_len);
    errdefer allocator.free(result);
    
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(result, bytes);
    // The encoder may have written fewer bytes than allocated if no padding
    // We need to trim to actual length
    const actual_len = encoded.len;
    if (actual_len < base64_len) {
        const trimmed = try allocator.alloc(u8, actual_len);
        @memcpy(trimmed, encoded);
        allocator.free(result);
        return trimmed;
    }
    
    return result;
}

test "PKCE generation" {
    const allocator = std.testing.allocator;
    
    const pkce = try generatePKCE(allocator);
    defer pkce.deinit(allocator);
    
    // Verifier should be 43 characters (32 bytes base64url encoded)
    try std.testing.expectEqual(@as(usize, 43), pkce.verifier.len);
    
    // Challenge should also be 43 characters (32 bytes SHA-256 base64url encoded)
    try std.testing.expectEqual(@as(usize, 43), pkce.challenge.len);
    
    // Verifier and challenge should be different
    try std.testing.expect(!std.mem.eql(u8, pkce.verifier, pkce.challenge));
}

test "PKCE deterministic challenge" {
    const allocator = std.testing.allocator;
    
    // Generate two different PKCE pairs
    const pkce1 = try generatePKCE(allocator);
    defer pkce1.deinit(allocator);
    
    const pkce2 = try generatePKCE(allocator);
    defer pkce2.deinit(allocator);
    
    // They should be different (random)
    try std.testing.expect(!std.mem.eql(u8, pkce1.verifier, pkce2.verifier));
    try std.testing.expect(!std.mem.eql(u8, pkce1.challenge, pkce2.challenge));
}
