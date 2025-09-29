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
    aio: Async,
    id: usize,
    running: bool,

    // The currently running Task's index.
    current_task: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, aio: Async, options: RuntimeOptions) !Runtime {
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
            .id = options.id,
            .current_task = null,
            .running = false,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.storage.deinit();
        self.scheduler.deinit();
        self.allocator.free(self.aio.completions);
        self.aio.deinit(self.allocator);
    }

    /// Wake the given Runtime.
    /// Safe to call from a different Runtime.
    pub fn wake(self: *Runtime) !void {
        if (self.running) try self.aio.wake();
    }

    /// Trigger a waiting (`.wait_for_trigger`) Task.
    /// Safe to call from a different Runtime.
    pub fn trigger(self: *Runtime, index: usize) !void {
        if (self.running) {
            log.debug("{d} - triggering {d}", .{ self.id, index });
            try self.scheduler.trigger(index);
            try self.wake();
        }
    }

    /// Stop the given Runtime.
    /// Safe to call from a different Runtime.
    pub fn stop(self: *Runtime) void {
        if (self.running) {
            self.running = false;
            self.aio.wake() catch unreachable;
        }
    }

    /// Spawns a new Frame. This creates a new heap-allocated stack for the Frame to run.
    pub fn spawn(
        self: *Runtime,
        frame_ctx: anytype,
        comptime frame_fn: anytype,
        stack_size: usize,
    ) !void {
        try self.scheduler.spawn(frame_ctx, frame_fn, stack_size);
    }

    fn run_task(self: *Runtime, task: *Task) !void {
        self.current_task = task.index;

        const frame = task.frame;
        frame.proceed();

        switch (frame.status) {
            else => {},
            .done => {
                // remember: task is invalid IF it resizes.
                // so we only hit that condition sometimes in here.
                const index = self.current_task.?;
                // If the frame is done, clean it up.
                try self.scheduler.release(index);
                // frees the heap-allocated stack.
                //
                // this should be evaluted as it does have a perf impact but
                // if frames are long lived (as they should be) and most data is
                // stack allocated within that context, i think it should be ok?
                frame.deinit(self.allocator);

                // if we have no more tasks, we are done and can set our running status to false.
                if (self.scheduler.tasks.empty()) self.running = false;
            },
            .errored => {
                const index = self.current_task.?;
                log.warn("cleaning up failed frame...", .{});
                try self.scheduler.release(index);
                frame.deinit(self.allocator);
            },
        }
    }

    pub fn run(self: *Runtime) !void {
        defer self.running = false;
        self.running = true;

        while (true) {
            var force_woken = false;

            // Processing Section
            var iter = self.scheduler.tasks.dirty.iterator(.{ .kind = .set });
            while (iter.next()) |index| {
                log.debug("{d} - processing index={d}", .{ self.id, index });
                const task = self.scheduler.tasks.get_ptr(index);
                switch (task.state) {
                    .runnable => {
                        log.debug("{d} - running index={d}", .{ self.id, index });
                        try self.run_task(task);
                        self.current_task = null;
                    },
                    .wait_for_trigger => if (self.scheduler.triggers.is_set(index)) {
                        log.debug("{d} - trigger={d} | state={t}", .{
                            self.id,
                            index,
                            task.state,
                        });

                        self.scheduler.triggers.unset(index);
                        try self.scheduler.set_runnable(index);
                    },
                    .wait_for_io => continue,
                    .dead => unreachable,
                }
            }

            if (!self.running) break;
            // If we have no tasks, we might as well exit.
            if (self.scheduler.tasks.empty()) break;

            // I/O Section
            try self.aio.submit();

            // If we don't have any runnable tasks, we just want to wait for an Async I/O.
            // Otherwise, we want to just reap whatever completion we have and continue running.
            const wait_for_io = self.scheduler.runnable == 0;
            log.debug("{d} - Wait for I/O: {}", .{ self.id, wait_for_io });

            const completions = try self.aio.reap(wait_for_io);
            for (completions) |completion| {
                if (completion.result == .wake) {
                    force_woken = true;
                    log.debug("{d} - waking up", .{self.id});
                    if (!self.running) return;
                    continue;
                }

                const index = completion.task;
                log.debug("{d} - completion={d}", .{ self.id, index });
                const task = self.scheduler.tasks.get_ptr(index);
                assert(task.state == .wait_for_io);
                task.result = completion.result;
                try self.scheduler.set_runnable(index);
            }

            if (self.scheduler.runnable == 0 and !force_woken) {
                log.warn("no more runnable tasks", .{});
                break;
            }
        }
    }
};
