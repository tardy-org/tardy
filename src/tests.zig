const std = @import("std");
const testing = std.testing;

const tardy = @import("root.zig");

test "tardy unit tests" {
    // Core
    _ = tardy.core.atomic.SpscRing;
    _ = tardy.core.pool;
    _ = tardy.core.Ring;
    _ = tardy.core.ZeroCopy;

    // Runtime
    _ = tardy.Runtime.Storage;
}
