const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const mem = std.mem;
const Io = std.Io;
const is_unix = builtin.os.tag != .windows;

const AsyncType = @import("tardy").AsyncType;
const Dir = @import("tardy").Dir;
const options = @import("options");
const Runtime = @import("tardy").Runtime;
const Task = @import("tardy").Task;
const Timer = @import("tardy").Timer;

const First = @import("first.zig");
const Second = @import("second.zig");
const SharedParams = @import("lib.zig").SharedParams;

const log = std.log.scoped(.@"tardy/e2e");

const backend: AsyncType = switch (options.async_option) {
    .auto => .auto,
    .kqueue => .kqueue,
    .io_uring => .io_uring,
    .epoll => .epoll,
    .poll => .poll,
    .custom => unreachable,
};
const Tardy = @import("tardy").Tardy(backend);

pub const std_options: std.Options = .{ .log_level = .debug };

const max_stderr_output = 9 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();

    _ = args.next().?;

    // max u64 is 21 characters long :p
    var maybe_seed_buffer: [21]u8 = undefined;
    const seed_string = args.next() orelse blk: {
        var stdin_r = Io.File.stdin().reader(io, &.{});
        const bytes = try stdin_r.interface.allocRemaining(gpa, .limited(max_stderr_output));
        defer gpa.free(bytes);

        var iter = mem.splitScalar(u8, bytes, '\n');
        const not_passed_in = "seed not passed in: ./e2e [seed]";
        const pre_new = iter.next() orelse @panic(not_passed_in);
        const length = pre_new.len;

        if (length <= 1) @panic(not_passed_in);
        if (length >= maybe_seed_buffer.len) @panic("seed too long to be a u64");

        assert(length < maybe_seed_buffer.len);
        @memcpy(maybe_seed_buffer[0..length], pre_new);
        maybe_seed_buffer[length] = 0;
        break :blk maybe_seed_buffer[0..length :0];
    };

    const seed = std.fmt.parseUnsigned(u64, seed_string, 10) catch @panic("seed passed in is not u64");
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();

    const shared: SharedParams = blk: {
        var p: SharedParams = undefined;
        p.seed_string = seed_string;
        p.seed = seed;

        p.size_tasks_initial = rand.intRangeAtMost(usize, 1, 64);
        p.size_aio_reap_max = rand.intRangeAtMost(usize, 1, p.size_tasks_initial * 2);
        break :blk p;
    };
    log.debug("{f}", .{std.json.fmt(shared, .{ .whitespace = .indent_1 })});

    var tardy: Tardy = try .init(gpa, io, .{
        .threading = .{ .multi = 2 },
        .pooling = .grow,
        .size_tasks_initial = shared.size_tasks_initial,
        .size_aio_reap_max = shared.size_aio_reap_max,
    });
    defer tardy.deinit();

    const EntryParams = struct {
        runtime: ?*Runtime,
        shared: *const SharedParams,
    };

    var params: EntryParams = .{
        .runtime = null,
        .shared = &shared,
    };

    try tardy.entry(
        &params,
        struct {
            fn start(rt: *Runtime, p: *EntryParams) !void {
                switch (rt.id) {
                    0 => {
                        p.runtime = rt;
                        try rt.spawn(
                            First.start_frame,
                            .{ rt, p.shared },
                            if (is_unix) .KiB(28) else .MiB(2), // 1.32
                        );
                        try rt.spawn(Second.start_frame, .{ rt, p.shared }, .@"32KiB");
                    },
                    1 => try rt.spawn(timeout_task, .{ rt, &p.runtime }, .@"32KiB"),
                    else => unreachable,
                }
            }
        }.start,
    );

    log.info("seed={d} passed", .{seed});
}

fn timeout_task(rt: *Runtime, other: *const ?*Runtime) !void {
    const TIMEOUT_LENGTH_S = std.time.s_per_min;

    // Checks every second to see if the other Runtime is done.
    for (0..TIMEOUT_LENGTH_S) |_| {
        try Timer.delay(rt, .{ .nanoseconds = 1 * std.time.ns_per_s });
        if (other.*) |o| if (!o.running) break;
    }

    // If it isn't, it'll panic and stop the CI.
    if (other.*) |o| {
        if (o.running) @panic("e2e test failed! | timed out");
    } else @panic("e2e test failed | test runtime didn't start");
}
