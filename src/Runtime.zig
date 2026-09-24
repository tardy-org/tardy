/// A runtime is what runs tasks and handles the Async I/O.
/// Every thread should have an independent Runtime.
pub const Runtime = @This();

gpa: mem.Allocator,
storage: Storage,
scheduler: Scheduler,
// TODO: audit if this is needed, or all request can go through `aio`
io: std.Io,
aio: AsyncIO,
id: usize,
running: bool,

// The currently running Task's index.
current_task: ?usize,

pub fn init(
    gpa: mem.Allocator,
    io: std.Io,
    aio: AsyncIO,
    options: Options,
) !Runtime {
    const scheduler: Scheduler = try .init(
        gpa,
        options.initial_tasks_size,
        options.pooling,
    );

    return .{
        .gpa = gpa,
        .storage = .init,
        .scheduler = scheduler,
        .aio = aio,
        .io = io,
        .id = options.id,
        .current_task = null,
        .running = false,
    };
}

pub fn deinit(rt: *Runtime) void {
    rt.storage.deinit(rt.gpa);
    rt.scheduler.deinit(rt.gpa, rt.io);
    rt.gpa.free(rt.aio.completions);
    rt.aio.deinit(rt.gpa, rt.io);
}

/// Wake the given Runtime.
/// Safe to call from a different Runtime.
pub fn wake(rt: *Runtime) !void {
    if (rt.running) try rt.aio.wake(rt.io);
}

/// Trigger a waiting (`.wait_for_trigger`) Task.
/// Safe to call from a different Runtime.
pub fn trigger(rt: *Runtime, task_index: usize) !void {
    if (rt.running) {
        const task = rt.scheduler.tasks.get_ptr(task_index);
        log.debug("{d} - triggering task={t} at index={d}", .{
            rt.id,
            task.result,
            task_index,
        });

        try rt.scheduler.trigger(rt.gpa, rt.io, task_index);
        try rt.wake();
    }
}

/// Stop the given Runtime.
/// Safe to call from a different Runtime.
pub fn stop(rt: *Runtime) void {
    if (rt.running) {
        rt.running = false;
        rt.aio.wake(rt.io) catch unreachable;
    }
}

/// Spawns a new Frame. This creates a new heap-allocated stack for the Frame to run.
pub fn spawn(
    rt: *Runtime,
    comptime coroutine_fn: anytype,
    args: meta.ArgsTuple(@TypeOf(coroutine_fn)),
    stack_size: ?Coroutine.Stack,
) !void {
    try rt.scheduler.spawn(
        rt.gpa,
        coroutine_fn,
        args,
        stack_size,
    );
}

fn run_task(rt: *Runtime, task: *Task) !void {
    rt.current_task = task.index;

    const frame = task.frame;
    frame.proceed();

    switch (frame.status) {
        .done => {
            // remember: `task_index` is invalid IF it resizes.
            // so we only hit that condition sometimes in here.
            const task_index = rt.current_task.?;
            // If the frame is done, clean it up.
            try rt.scheduler.release(rt.gpa, task_index);
            // frees the heap-allocated stack.
            //
            // this should be evaluted as it does have a perf impact but
            // if frames are long lived (as they should be) and most data is
            // stack allocated within that context, i think it should be ok?
            frame.deinit(rt.gpa);

            // if we have no more tasks, we are done and can set our running
            // status to false.
            if (rt.scheduler.tasks.empty()) rt.running = false;
        },
        .errored => {
            const task_index = rt.current_task.?;
            log.warn("cleaning up failed frame...", .{});
            try rt.scheduler.release(rt.gpa, task_index);
            frame.deinit(rt.gpa);
        },
        else => {},
    }
}

pub fn run(rt: *Runtime) !void {
    rt.running = true;
    defer rt.running = false;

    while (true) {
        var force_woken = false;

        // Processing Section
        var iter = rt.scheduler.tasks.dirty.iterator(.{
            .kind = .set,
        });
        while (iter.next()) |task_index| {
            const task = rt.scheduler.tasks.get_ptr(task_index);
            log.debug("{d} - processing task={t} at index={d}", .{
                rt.id,
                task.result,
                task_index,
            });

            switch (task.state) {
                .runnable => {
                    log.debug("{d} - running task={t} at index={d}", .{
                        rt.id,
                        task.result,
                        task_index,
                    });
                    try rt.run_task(task);
                    rt.current_task = null;
                },
                .wait_for_trigger => if (rt.scheduler.triggers.is_set(
                    rt.io,
                    task_index,
                )) {
                    log.debug("{d} - trigger={t} at index={d} | state={t}", .{
                        rt.id,
                        task.result,
                        task_index,
                        task.state,
                    });

                    rt.scheduler.triggers.unset(rt.io, task_index);
                    rt.scheduler.set_runnable(task_index);
                },
                .wait_for_io => continue,
                .dead => unreachable,
            }
        }

        if (!rt.running) break;
        // If we have no tasks, we might as well exit.
        if (rt.scheduler.tasks.empty()) break;

        // I/O Section
        try rt.aio.submit();

        const wait_for_io = rt.scheduler.runnable == 0;
        log.debug("{d} - Wait for I/O: {}", .{ rt.id, wait_for_io });

        // If we don't have any runnable tasks, then we wait for an Async I/O,
        // reap the completed task and continue running.
        const completions = try rt.aio.reap(
            rt.gpa,
            wait_for_io,
        );
        for (completions) |completion| {
            if (completion.result == .wake) {
                force_woken = true;
                log.debug("{d} - waking up", .{rt.id});
                if (!rt.running) return;
                continue;
            }

            const task_index = completion.task_index;
            const task = rt.scheduler.tasks.get_ptr(task_index);

            log.debug("{d} - completed task={t} I/O at index {d}", .{
                rt.id,
                task.result,
                task_index,
            });

            // task should have been waiting for I/O which has now completed
            // and was retreived with `reap`
            debug.assert(task.state == .wait_for_io);
            task.result = completion.result;

            // let task continue to run to completion after it was yielded in `ioAwait`
            rt.scheduler.set_runnable(task_index);
        }

        if (rt.scheduler.runnable == 0 and !force_woken) {
            log.warn("no more runnable tasks", .{});
            break;
        }
    }
}

const log = std.log.scoped(.@"tardy/Runtime");

const Options = struct {
    id: usize,
    pooling: pool.Kind,
    initial_tasks_size: usize,
    aio_reap_size_max: usize,
};

const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const debug = std.debug;

pub const Scheduler = @import("runtime/Scheduler.zig");
pub const Storage = @import("runtime/Storage.zig");
pub const Task = @import("runtime/Task.zig");
pub const Timer = @import("runtime/Timer.zig");
const tardy = @import("root.zig");
const Coroutine = tardy.Coroutine;
const AsyncIO = tardy.AsyncIO;
const pool = tardy.core.pool;
