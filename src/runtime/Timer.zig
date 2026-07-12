pub const Timer = @This();

pub fn delay(rt: *Runtime, duration: std.Io.Duration) !void {
    try rt.scheduler.io_await(.{ .timer = duration });
}

const std = @import("std");

const tardy = @import("../root.zig");
const Runtime = tardy.Runtime;
