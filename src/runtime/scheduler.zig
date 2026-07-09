const std = @import("std");
const assert = std.debug.assert;

pub const AsyncSubmission = @import("../aio/lib.zig").AsyncSubmission;
const AtomicDynamicBitSet = @import("../core/atomic_bitset.zig").AtomicDynamicBitSet;
const Pool = @import("../core/pool.zig").Pool;
const PoolKind = @import("../core/pool.zig").PoolKind;
const Queue = @import("../core/queue.zig").Queue;
const frame = @import("../frame/lib.zig");
const Frame = frame.Frame;
const Runtime = @import("lib.zig").Runtime;
const Task = @import("task.zig").Task;

const TaskWithJob = struct {
    task: Task,
    job: ?AsyncSubmission = null,
};

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    tasks: Pool(Task),
    runnable: usize,
    released: std.ArrayList(usize),
    triggers: AtomicDynamicBitSet,

    pub fn init(allocator: std.mem.Allocator, size: usize, pooling: PoolKind) !Scheduler {
        var tasks: Pool(Task) = try .init(allocator, size, pooling);
        errdefer tasks.deinit();

        var released: std.ArrayList(usize) = try .initCapacity(allocator, size);
        errdefer released.deinit(allocator);

        const triggers: AtomicDynamicBitSet = try .init(allocator, size, false);
        errdefer triggers.deinit(allocator);

        return .{
            .allocator = allocator,
            .tasks = tasks,
            .runnable = 0,
            .released = released,
            .triggers = triggers,
        };
    }

    pub fn deinit(sched: *Scheduler, io: std.Io) void {
        var iter = sched.tasks.iterator();
        while (iter.next_ptr()) |task| {
            task.frame.deinit(sched.allocator);
        }
        sched.tasks.deinit();
        sched.released.deinit(sched.allocator);
        sched.triggers.deinit(sched.allocator, io);
    }

    pub fn set_runnable(self: *Scheduler, index: usize) !void {
        const task = self.tasks.get_ptr(index);
        assert(task.state != .runnable);
        task.state = .runnable;
        self.runnable += 1;
    }

    pub fn trigger_await(self: *Scheduler) !void {
        const rt: *Runtime = @fieldParentPtr("scheduler", self);
        const index = rt.current_task.?;
        const task = self.tasks.get_ptr(index);

        // To waiting...
        task.state = .wait_for_trigger;
        self.runnable -= 1;

        Frame.yield();
    }

    // NOTE: This can spuriously trigger a Task later in the Run Loop.
    /// Safe to call from a different Runtime.
    pub fn trigger(self: *Scheduler, index: usize) !void {
        const rt: *Runtime = @fieldParentPtr("scheduler", self);
        try self.triggers.set(rt.io, index);
    }

    // This is only safe to call from the Runtime that the Frame is running on.
    pub fn io_await(self: *Scheduler, job: AsyncSubmission) !void {
        const rt: *Runtime = @fieldParentPtr("scheduler", self);
        const index = rt.current_task.?;
        const task = self.tasks.get_ptr(index);

        // To waiting...
        task.state = .wait_for_io;
        self.runnable -= 1;

        // Queue the related I/O job.
        try rt.aio.queue_job(index, job);
        Frame.yield();
    }

    pub fn spawn(
        self: *Scheduler,
        comptime coroutine_fn: anytype,
        args: anytype,
        stack_size: ?Frame.Stack,
    ) !void {
        const index = blk: {
            if (self.released.pop()) |index| {
                break :blk self.tasks.borrow_assume_unset(index);
            } else {
                break :blk try self.tasks.borrow();
            }
        };

        const frame_ptr: *Frame = .init(
            self.allocator,
            coroutine_fn,
            args,
            stack_size,
        );

        const item: Task = .{
            .index = index,
            .frame = frame_ptr,
            .state = .dead,
        };
        const item_ptr = self.tasks.get_ptr(index);
        item_ptr.* = item;
        try self.set_runnable(index);
    }

    pub fn release(self: *Scheduler, index: usize) !void {
        // must be runnable to set?
        const task = self.tasks.get_ptr(index);
        assert(task.state == .runnable);
        task.state = .dead;
        self.runnable -= 1;

        self.tasks.release(index);
        try self.released.append(self.allocator, index);
    }
};
