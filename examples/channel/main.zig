const std = @import("std");

const options = @import("options");
const tardy = @import("tardy");
const Runtime = tardy.Runtime;
const Spsc = tardy.Spsc;
const Task = tardy.Task;
const Timer = tardy.Timer;
const AsyncIO = tardy.AsyncIO;

const backend: AsyncIO.Kind = .init(options.async_option);
const Tardy = tardy.Tardy(backend);

const log = std.log.scoped(.@"tardy/example/channel");
pub const std_options: std.Options = .{ .log_level = .debug };

const MAX_COUNT = 3;

fn producer_frame(rt: *Runtime, producer: Spsc(usize).Producer) !void {
    defer producer.close();

    var count: usize = 0;
    while (count <= MAX_COUNT) : (count += 1) {
        log.info("producer channel | sending '{d}' 3x", .{count});
        try producer.send(count);
        try producer.send(count);
        try producer.send(count);
        try Timer.delay(rt, .{ .nanoseconds = 1 * std.time.ns_per_s });
    }

    log.info("producer frame done running!", .{});
}

fn consumer_frame(rt: *Runtime, consumer: Spsc(usize).Consumer) !void {
    defer consumer.close();

    const time: std.Io.Timestamp = .now(rt.io, .awake);
    while (true) {
        const recvd = consumer.recv() catch break;
        log.info("{f} - consumer channel | received {d}", .{ time.untilNow(rt.io, .awake), recvd });
    }

    log.info("consumer frame done running!", .{});
}

pub fn main(init: std.process.Init) !void {
    var channel: Spsc(usize) = try .init(init.gpa, 2);
    defer channel.deinit();

    var td: Tardy = try .init(init.gpa, init.io, .{
        .threading = .{ .multi = 2 },
        .pooling = .static,
        .size_tasks_initial = 1,
        .size_aio_reap_max = 1,
    });
    defer td.deinit();

    try td.entry(
        &channel,
        struct {
            fn init_fn(rt: *Runtime, spsc: *Spsc(usize)) !void {
                switch (rt.id) {
                    0 => try rt.spawn(
                        producer_frame,
                        .{ rt, spsc.producer(rt) },
                        .@"32KiB",
                    ),
                    1 => try rt.spawn(
                        consumer_frame,
                        .{ rt, spsc.consumer(rt) },
                        .@"32KiB",
                    ),
                    else => unreachable,
                }
            }
        }.init_fn,
    );
}
