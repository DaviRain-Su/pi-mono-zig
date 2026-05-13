comptime {
    _ = @import("author_workflow_e2e_tests/package_lifecycle.zig");
    _ = @import("author_workflow_e2e_tests/aggregate_runtime.zig");
    _ = @import("author_workflow_e2e_tests/ci_boundary.zig");
    _ = @import("author_workflow_e2e_tests/runtime_construction.zig");
    _ = @import("author_workflow_e2e_tests/trust_policy.zig");
}
