const std = @import("std");
const assert = std.debug.assert;

const Async = @import("../aio/lib.zig").Async;
const PoolKind = @import("../core/pool.zig").PoolKind;
const Queue = @import("../core/queue.zig").Queue;
const Frame = @import("../frame/lib.zig").Frame;
const Timespec = @import("../lib.zig").Timespec;
const Scheduler = @import("./scheduler.zig").Scheduler;
const Storage = @import("storage.zig").Storage;
const Task = @import("task.zig").Task;

const log = std.log.scoped(.@"tardy/runtime");

const RuntimeOptions = struct {
    id: usize,
    pooling: PoolKind,
    size_tasks_initial: usize,
    size_aio_reap_max: usize,
};

/// A runtime is what runs tasks and handles the Async I/O.
/// Every thread should have an independent Runtime.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    storage: Storage,
    scheduler: Scheduler,
    // TODO: audit if this is needed, or all request can go through `aio`
    io: std.Io,
    aio: Async,
    id: usize,
    running: bool,

    // The currently running Task's index.
    current_task: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, aio: Async, options: RuntimeOptions) !Runtime {
        const scheduler: Scheduler = try .init(
            allocator,
            options.size_tasks_initial,
            options.pooling,
        );
        const storage: Storage = .init(allocator);

        return .{
            .allocator = allocator,
            .storage = storage,
            .scheduler = scheduler,
            .aio = aio,
            .io = io,
            .id = options.id,
            .current_task = null,
            .running = false,
        };
    }

    pub fn deinit(rt: *Runtime) void {
        rt.storage.deinit();
        rt.scheduler.deinit(rt.io);
        rt.allocator.free(rt.aio.completions);
        rt.aio.deinit(rt.allocator, rt.io);
    }

    /// Wake the given Runtime.
    /// Safe to call from a different Runtime.
    pub fn wake(rt: *Runtime) !void {
        if (rt.running) try rt.aio.wake(rt.io);
    }

    /// Trigger a waiting (`.wait_for_trigger`) Task.
    /// Safe to call from a different Runtime.
    pub fn trigger(rt: *Runtime, index: usize) !void {
        if (rt.running) {
            log.debug("{d} - triggering {d}", .{ rt.id, index });
            try rt.scheduler.trigger(index);
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
        frame_ctx: anytype,
        comptime frame_fn: anytype,
        stack_size: usize,
    ) !void {
        try rt.scheduler.spawn(frame_ctx, frame_fn, stack_size);
    }

    fn run_task(rt: *Runtime, task: *Task) !void {
        rt.current_task = task.index;

        const frame = task.frame;
        frame.proceed();

        switch (frame.status) {
            else => {},
            .done => {
                // remember: task is invalid IF it resizes.
                // so we only hit that condition sometimes in here.
                const index = rt.current_task.?;
                // If the frame is done, clean it up.
                try rt.scheduler.release(index);
                // frees the heap-allocated stack.
                //
                // this should be evaluted as it does have a perf impact but
                // if frames are long lived (as they should be) and most data is
                // stack allocated within that context, i think it should be ok?
                frame.deinit(rt.allocator);

                // if we have no more tasks, we are done and can set our running status to false.
                if (rt.scheduler.tasks.empty()) rt.running = false;
            },
            .errored => {
                const index = rt.current_task.?;
                log.warn("cleaning up failed frame...", .{});
                try rt.scheduler.release(index);
                frame.deinit(rt.allocator);
            },
        }
    }

    pub fn run(rt: *Runtime) !void {
        defer rt.running = false;
        rt.running = true;

        while (true) {
            var force_woken = false;

            // Processing Section
            var iter = rt.scheduler.tasks.dirty.iterator(.{ .kind = .set });
            while (iter.next()) |index| {
                log.debug("{d} - processing index={d}", .{ rt.id, index });
                const task = rt.scheduler.tasks.get_ptr(index);
                switch (task.state) {
                    .runnable => {
                        log.debug("{d} - running index={d}", .{ rt.id, index });
                        try rt.run_task(task);
                        rt.current_task = null;
                    },
                    .wait_for_trigger => if (rt.scheduler.triggers.is_set(rt.io, index)) {
                        log.debug("{d} - trigger={d} | state={t}", .{
                            rt.id,
                            index,
                            task.state,
                        });

                        rt.scheduler.triggers.unset(rt.io, index);
                        try rt.scheduler.set_runnable(index);
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

            // If we don't have any runnable tasks, we just want to wait for an Async I/O.
            // Otherwise, we want to just reap whatever completion we have and continue running.
            const wait_for_io = rt.scheduler.runnable == 0;
            log.debug("{d} - Wait for I/O: {}", .{ rt.id, wait_for_io });

            const completions = try rt.aio.reap(wait_for_io);
            for (completions) |completion| {
                if (completion.result == .wake) {
                    force_woken = true;
                    log.debug("{d} - waking up", .{rt.id});
                    if (!rt.running) return;
                    continue;
                }

                const index = completion.task;
                log.debug("{d} - completion={d}", .{ rt.id, index });
                const task = rt.scheduler.tasks.get_ptr(index);
                assert(task.state == .wait_for_io);
                task.result = completion.result;
                try rt.scheduler.set_runnable(index);
            }

            if (rt.scheduler.runnable == 0 and !force_woken) {
                log.warn("no more runnable tasks", .{});
                break;
            }
        }
    }
};
