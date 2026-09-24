pub const Scheduler = @This();

tasks: pool.Pool(Task),
runnable: usize,
// index to frames that are `.done` or `.errored`
released: std.ArrayList(usize),
triggers: atomic.Bitset,

pub fn init(gpa: mem.Allocator, task_size: usize, pooling: pool.Kind) !Scheduler {
    var tasks: pool.Pool(Task) = try .init(
        gpa,
        task_size,
        pooling,
    );
    errdefer tasks.deinit(gpa);

    var released: std.ArrayList(usize) = try .initCapacity(gpa, task_size);
    errdefer released.deinit(gpa);

    const triggers: atomic.Bitset = try .init(
        gpa,
        task_size,
        false,
    );
    errdefer triggers.deinit(gpa);

    return .{
        .tasks = tasks,
        .runnable = 0,
        .released = released,
        .triggers = triggers,
    };
}

pub fn deinit(sched: *Scheduler, gpa: mem.Allocator, io: std.Io) void {
    var iter = sched.tasks.iterator();
    while (iter.next_ptr()) |task| {
        task.frame.deinit(gpa);
    }
    sched.tasks.deinit(gpa);
    sched.released.deinit(gpa);
    sched.triggers.deinit(gpa, io);
}

pub fn set_runnable(sched: *Scheduler, task_index: usize) void {
    const task = sched.tasks.get_ptr(task_index);
    debug.assert(task.state != .runnable);
    task.state = .runnable;
    sched.runnable += 1;
}

pub fn trigger_await(sched: *Scheduler) void {
    const rt: *Runtime = @fieldParentPtr("scheduler", sched);
    const task_index = rt.current_task.?;
    const task = sched.tasks.get_ptr(task_index);

    // To waiting...
    task.state = .wait_for_trigger;
    sched.runnable -= 1;

    Coroutine.yield();
}

// NOTE: This can spuriously trigger a Task later in the Run Loop.
/// Safe to call from a different Runtime.
pub fn trigger(
    sched: *Scheduler,
    gpa: mem.Allocator,
    io: std.Io,
    task_index: usize,
) OoM!void {
    try sched.triggers.set(gpa, io, task_index);
}

// This is only safe to call from the Runtime that the Frame is running on.
pub fn ioAwait(
    sched: *Scheduler,
    gpa: mem.Allocator,
    job: AsyncIO.Submission,
) AsyncIO.Errors.QueueJob!void {
    const rt: *Runtime = @fieldParentPtr("scheduler", sched);
    const task_index = rt.current_task.?;
    const task = sched.tasks.get_ptr(task_index);

    // To waiting...
    task.state = .wait_for_io;
    sched.runnable -= 1;

    // Queue the related I/O job.
    try rt.aio.queue_job(gpa, task_index, job);
    Coroutine.yield();
}

pub fn spawn(
    sched: *Scheduler,
    gpa: mem.Allocator,
    comptime coroutine_fn: anytype,
    args: meta.ArgsTuple(@TypeOf(coroutine_fn)),
    stack_size: ?Coroutine.Stack,
) !void {
    const task_index = blk: {
        if (sched.released.pop()) |index| {
            break :blk sched.tasks.borrow_assume_unset(index);
        } else {
            break :blk try sched.tasks.borrow(gpa);
        }
    };

    const frame: *Coroutine = .init(
        gpa,
        coroutine_fn,
        args,
        stack_size,
    );

    const item: Task = .{
        .index = task_index,
        .frame = frame,
        .state = .dead,
    };
    const item_ptr = sched.tasks.get_ptr(task_index);
    item_ptr.* = item;

    sched.set_runnable(task_index);
}

pub fn release(sched: *Scheduler, gpa: mem.Allocator, task_index: usize) !void {
    // must be runnable to set?
    const task = sched.tasks.get_ptr(task_index);
    debug.assert(task.state == .runnable);
    task.state = .dead;
    sched.runnable -= 1;

    sched.tasks.release(task_index);
    try sched.released.append(gpa, task_index);
}

const TaskWithJob = struct {
    task: Task,
    job: ?AsyncIO.Submission = null,
};

const std = @import("std");
const mem = std.mem;
const OoM = mem.Allocator.Error;
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
