const std = @import("std");

const options = @import("options");
const tardy = @import("tardy");
const Runtime = tardy.Runtime;
const Task = tardy.Task;
const Timer = tardy.Timer;
const AsyncIO = tardy.AsyncIO;

const backend: AsyncIO.Kind = .init(options.async_backend);
const Tardy = tardy.Tardy(backend);

const log = std.log.scoped(.@"tardy/example/basic");

fn log_frame(rt: *Runtime) !void {
    var count: usize = 0;

    const time: std.Io.Timestamp = .now(rt.io, .awake);
    while (count < 10) : (count += 1) {
        log.info("{f} - tardy example | {d}", .{ time.untilNow(rt.io, .awake), count });
        try Timer.delay(rt, .{ .nanoseconds = 1 * std.time.ns_per_ms });
    }
}

pub fn main(init: std.process.Init) !void {
    var td: Tardy = try .init(init.gpa, init.io, .{
        .threading = .single,
        .pooling = .static,
        .size_tasks_initial = 2,
        .size_aio_reap_max = 2,
    });
    defer td.deinit();

    try td.entry(
        {},
        struct {
            fn init_fn(rt: *Runtime, _: void) !void {
                try rt.spawn(log_frame, .{rt}, .@"16KiB");
            }
        }.init_fn,
    );
}
