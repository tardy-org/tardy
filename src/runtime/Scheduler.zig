pub const Scheduler = @This();

allocator: mem.Allocator,
tasks: pool.Pool(Task),
runnable: usize,
released: std.ArrayList(usize),
triggers: atomic.Bitset,

pub fn init(allocator: mem.Allocator, size: usize, pooling: pool.Kind) !Scheduler {
    var tasks: pool.Pool(Task) = try .init(
        allocator,
        size,
        pooling,
    );
    errdefer tasks.deinit();

    var released: std.ArrayList(usize) = try .initCapacity(allocator, size);
    errdefer released.deinit(allocator);

    const triggers: atomic.Bitset = try .init(
        allocator,
        size,
        false,
    );
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
    debug.assert(task.state != .runnable);
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

    Coroutine.yield();
}

// NOTE: This can spuriously trigger a Task later in the Run Loop.
/// Safe to call from a different Runtime.
pub fn trigger(self: *Scheduler, index: usize) !void {
    const rt: *Runtime = @fieldParentPtr("scheduler", self);
    try self.triggers.set(rt.io, index);
}

// This is only safe to call from the Runtime that the Frame is running on.
pub fn io_await(self: *Scheduler, job: AsyncIO.Submission) !void {
    const rt: *Runtime = @fieldParentPtr("scheduler", self);
    const index = rt.current_task.?;
    const task = self.tasks.get_ptr(index);

    // To waiting...
    task.state = .wait_for_io;
    self.runnable -= 1;

    // Queue the related I/O job.
    try rt.aio.queue_job(index, job);
    Coroutine.yield();
}

pub fn spawn(
    self: *Scheduler,
    comptime coroutine_fn: anytype,
    args: anytype,
    stack_size: ?Coroutine.Stack,
) !void {
    const index = blk: {
        if (self.released.pop()) |index| {
            break :blk self.tasks.borrow_assume_unset(index);
        } else {
            break :blk try self.tasks.borrow();
        }
    };

    const frame_ptr: *Coroutine = .init(
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
    debug.assert(task.state == .runnable);
    task.state = .dead;
    self.runnable -= 1;

    self.tasks.release(index);
    try self.released.append(self.allocator, index);
}

const TaskWithJob = struct {
    task: Task,
    job: ?AsyncIO.Submission = null,
};

const std = @import("std");
const mem = std.mem;
const debug = std.debug;

const tardy = @import("../root.zig");
const pool = tardy.core.pool;
const queue = tardy.core.queue;
const atomic = tardy.core.atomic;
const AsyncIO = tardy.AsyncIO;
const Coroutine = tardy.Coroutine;
const Runtime = tardy.Runtime;
const Task = @import("Task.zig");
