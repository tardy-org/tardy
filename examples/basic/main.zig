const std = @import("std");

const Runtime = @import("tardy").Runtime;
const Task = @import("tardy").Task;
const Timer = @import("tardy").Timer;

const Tardy = @import("tardy").Tardy(.auto);
const log = std.log.scoped(.@"tardy/example/basic");

fn log_frame(rt: *Runtime) !void {
    var count: usize = 0;

    while (count < 10) : (count += 1) {
        log.debug("{d} - tardy example | {d}", .{ std.time.milliTimestamp(), count });
        try Timer.delay(rt, .{ .seconds = 1 });
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var tardy: Tardy = try .init(allocator, .{
        .threading = .single,
        .pooling = .static,
        .size_tasks_initial = 2,
        .size_aio_reap_max = 2,
    });
    defer tardy.deinit();

    try tardy.entry(
        {},
        struct {
            fn init(rt: *Runtime, _: void) !void {
                try rt.spawn(.{rt}, log_frame, 1024 * 16);
            }
        }.init,
    );
}
