const std = @import("std");
const Runtime = @import("lib.zig").Runtime;

pub const Timer = struct {
    pub fn delay(rt: *Runtime, duration: std.Io.Duration) !void {
        try rt.scheduler.io_await(.{ .timer = duration });
    }
};
