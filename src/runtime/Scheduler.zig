pub const Scheduler = @This();

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
    errdefer tasks.deinit(allocator);

    var released: std.ArrayList(usize) = try .initCapacity(allocator, size);
    errdefer released.deinit(allocator);

    const triggers: atomic.Bitset = try .init(
        allocator,
        size,
        false,
    );
    errdefer triggers.deinit(allocator);

    return .{
        .tasks = tasks,
        .runnable = 0,
        .released = released,
        .triggers = triggers,
    };
}

pub fn deinit(sched: *Scheduler, allocator: mem.Allocator, io: std.Io) void {
    var iter = sched.tasks.iterator();
    while (iter.next_ptr()) |task| {
        task.frame.deinit(allocator);
    }
    sched.tasks.deinit(allocator);
    sched.released.deinit(allocator);
    sched.triggers.deinit(allocator, io);
}

pub fn set_runnable(sched: *Scheduler, index: usize) void {
    const task = sched.tasks.get_ptr(index);
    debug.assert(task.state != .runnable);
    task.state = .runnable;
    sched.runnable += 1;
}

pub fn trigger_await(sched: *Scheduler) void {
    const rt: *Runtime = @fieldParentPtr("scheduler", sched);
    const index = rt.current_task.?;
    const task = sched.tasks.get_ptr(index);

    // To waiting...
    task.state = .wait_for_trigger;
    sched.runnable -= 1;

    Coroutine.yield();
}

// NOTE: This can spuriously trigger a Task later in the Run Loop.
/// Safe to call from a different Runtime.
pub fn trigger(sched: *Scheduler, index: usize) !void {
    const rt: *Runtime = @fieldParentPtr("scheduler", sched);
    try sched.triggers.set(rt.allocator, rt.io, index);
}

// This is only safe to call from the Runtime that the Frame is running on.
pub fn io_await(
    sched: *Scheduler,
    allocator: mem.Allocator,
    job: AsyncIO.Submission,
) !void {
    const rt: *Runtime = @fieldParentPtr("scheduler", sched);
    const index = rt.current_task.?;
    const task = sched.tasks.get_ptr(index);

    // To waiting...
    task.state = .wait_for_io;
    sched.runnable -= 1;

    // Queue the related I/O job.
    try rt.aio.queue_job(allocator, index, job);
    Coroutine.yield();
}

pub fn spawn(
    sched: *Scheduler,
    allocator: mem.Allocator,
    comptime coroutine_fn: anytype,
    args: meta.ArgsTuple(@TypeOf(coroutine_fn)),
    stack_size: ?Coroutine.Stack,
) !void {
    const index = blk: {
        if (sched.released.pop()) |index| {
            break :blk sched.tasks.borrow_assume_unset(index);
        } else {
            break :blk try sched.tasks.borrow(allocator);
        }
    };

    const frame: *Coroutine = .init(
        allocator,
        coroutine_fn,
        args,
        stack_size,
    );

    const item: Task = .{
        .index = index,
        .frame = frame,
        .state = .dead,
    };
    const item_ptr = sched.tasks.get_ptr(index);
    item_ptr.* = item;
    sched.set_runnable(index);
}

pub fn release(sched: *Scheduler, allocator: mem.Allocator, index: usize) !void {
    // must be runnable to set?
    const task = sched.tasks.get_ptr(index);
    debug.assert(task.state == .runnable);
    task.state = .dead;
    sched.runnable -= 1;

    sched.tasks.release(index);
    try sched.released.append(allocator, index);
}

const TaskWithJob = struct {
    task: Task,
    job: ?AsyncIO.Submission = null,
};

const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const debug = std.debug;

const tardy = @import("../root.zig");
const pool = tardy.core.pool;
const queue = tardy.core.queue;
const atomic = tardy.core.atomic;
const AsyncIO = tardy.AsyncIO;
const Coroutine = tardy.Coroutine;
const Runtime = tardy.Runtime;
const Task = @import("Task.zig");
