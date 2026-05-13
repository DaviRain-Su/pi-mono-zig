const common = @import("common.zig");
const std = common.std;
const readFile = common.readFile;
const expectContains = common.expectContains;
const expectNotContains = common.expectNotContains;

test "VAL-CROSS-030 CI matrix keeps aggregate native runtime boundaries explicit" {
    const allocator = std.testing.allocator;
    const zig_ci = try readFile(allocator, "../.github/workflows/zig-ci.yml");
    defer allocator.free(zig_ci);
    const node_ci = try readFile(allocator, "../.github/workflows/ci.yml");
    defer allocator.free(node_ci);

    try expectContains(zig_ci, "os: [ubuntu-latest, macos-latest, windows-latest]");
    try expectContains(zig_ci, "ZIG_VERSION=0.16.0");
    try expectContains(zig_ci, "Linux Zig smoke");
    try expectContains(zig_ci, "zig build check-external-tools --summary all");
    try expectContains(zig_ci, "Skipping Linux zig build/test because Zig 0.16.0 SIGSEGVs");
    try expectContains(zig_ci, "if: runner.os == 'Windows'");
    try expectContains(zig_ci, "if: runner.os == 'macOS'");
    try expectContains(zig_ci, "zig build test --summary all");
    try expectContains(zig_ci, "Zig CI Test Summary");
    try expectContains(node_ci, "npm run check");
    try expectNotContains(zig_ci, "Web Simulator");
    try expectNotContains(zig_ci, "marketplace");
    try expectNotContains(zig_ci, "signing");
}
