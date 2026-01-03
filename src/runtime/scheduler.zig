const std = @import("std");
const assert = std.debug.assert;

pub const AsyncSubmission = @import("../aio/lib.zig").AsyncSubmission;
const AtomicDynamicBitSet = @import("../core/atomic_bitset.zig").AtomicDynamicBitSet;
const Pool = @import("../core/pool.zig").Pool;
const PoolKind = @import("../core/pool.zig").PoolKind;
const Queue = @import("../core/queue.zig").Queue;
const Frame = @import("../frame/lib.zig").Frame;
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

    pub fn deinit(self: *Scheduler) void {
        self.tasks.deinit();
        self.released.deinit(self.allocator);
        self.triggers.deinit(self.allocator);
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
        try self.triggers.set(index);
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

    pub fn spawn(self: *Scheduler, frame_ctx: anytype, comptime frame_fn: anytype, stack_size: usize) !void {
        const index = blk: {
            if (self.released.pop()) |index| {
                break :blk self.tasks.borrow_assume_unset(index);
            } else {
                break :blk try self.tasks.borrow();
            }
        };

        const frame: *Frame = try .init(self.allocator, stack_size, frame_ctx, frame_fn);

        const item: Task = .{ .index = index, .frame = frame, .state = .dead };
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
