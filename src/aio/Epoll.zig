pub const Epoll = @This();

epoll_fd: posix.fd_t,
wake_event_fd: posix.fd_t,
events: []linux.epoll_event,

jobs: pool.Pool(Job),

pub fn init(gpa: mem.Allocator, options: AsyncIO.Options) !Epoll {
    const size = options.initial_task_size + 1;
    const epoll_fd = try syscall.epoll_create1(0);
    debug.assert(epoll_fd > -1);
    errdefer syscall.close(epoll_fd);

    const wake_event_fd: posix.fd_t = try syscall.eventfd(
        0,
        linux.EFD.CLOEXEC,
    );
    errdefer syscall.close(wake_event_fd);

    const events = try gpa.alloc(
        linux.epoll_event,
        options.aio_reap_size_max,
    );
    errdefer gpa.free(events);

    var jobs: pool.Pool(Job) = try .init(
        gpa,
        size,
        options.pooling,
    );
    errdefer jobs.deinit(gpa);

    // Queue the wake task.
    const job_index = jobs.borrow_assume_unset(0);
    const item = jobs.get_ptr(job_index);
    item.* = .{
        .job_index = job_index,
        .type = .wake,
        .task_index = @bitCast(@as(isize, -1)),
    };

    var event: linux.epoll_event = .{
        .events = linux.EPOLL.IN,
        .data = .{ .u64 = job_index },
    };

    try syscall.epoll_ctl(
        epoll_fd,
        linux.EPOLL.CTL_ADD,
        wake_event_fd,
        &event,
    );

    return .{
        .epoll_fd = epoll_fd,
        .wake_event_fd = wake_event_fd,
        .events = events,
        .jobs = jobs,
    };
}

pub fn inner_deinit(epoll: *Epoll, gpa: mem.Allocator) void {
    syscall.close(epoll.epoll_fd);
    gpa.free(epoll.events);
    epoll.jobs.deinit(gpa);
    syscall.close(epoll.wake_event_fd);
}

fn deinit(runner: *anyopaque, gpa: mem.Allocator) void {
    const epoll: *Epoll = @ptrCast(@alignCast(runner));
    epoll.inner_deinit(gpa);
}

pub fn queue_job(
    runner: *anyopaque,
    gpa: mem.Allocator,
    task_index: usize,
    job: AsyncIO.Submission,
) Errors.QueueJob!void {
    const epoll: *Epoll = @ptrCast(@alignCast(runner));

    try switch (job) {
        .timer => |timer| epoll.queue_timer(
            gpa,
            task_index,
            timer,
        ),
        .accept => |accept| epoll.queue_accept(
            gpa,
            task_index,
            accept.socket,
        ),
        .connect => |connect| epoll.queue_connect(
            gpa,
            task_index,
            connect.socket,
        ),
        .recv => |recv| epoll.queue_recv(
            gpa,
            task_index,
            recv.socket,
            recv.buffer,
        ),
        .send => |send| epoll.queue_send(
            gpa,
            task_index,
            send.socket,
            send.buffer,
        ),
        .open, .delete, .mkdir, .stat, .read, .write, .close => unreachable,
    };
}

fn queue_timer(
    epoll: *Epoll,
    gpa: mem.Allocator,
    task_index: usize,
    duration: Io.Duration,
) Errors.Timer!void {
    const job_index = try epoll.jobs.borrow_hint(gpa, task_index);
    errdefer epoll.jobs.release(job_index);

    const item = epoll.jobs.get_ptr(job_index);

    const timer_fd = try syscall.timerfd_create(
        linux.TIMERFD_CLOCK.MONOTONIC,
        .{ .NONBLOCK = true },
    );

    const ktimerspec: linux.itimerspec = .{
        .it_value = .{
            .sec = @intCast(@divFloor(duration.nanoseconds, std.time.ns_per_s)),
            .nsec = @intCast(@mod(duration.nanoseconds, std.time.ns_per_s)),
        },
        .it_interval = .{ .sec = 0, .nsec = 0 },
    };

    try syscall.timerfd_settime(
        timer_fd,
        .{},
        &ktimerspec,
        null,
    );
    item.* = .{
        .job_index = job_index,
        .type = .{
            .timer = .{ .fd = timer_fd },
        },
        .task_index = task_index,
    };

    var event: linux.epoll_event = .{
        .events = linux.EPOLL.IN,
        .data = .{ .u64 = job_index },
    };

    try epoll.add_fd(timer_fd, &event);
}

fn queue_accept(
    epoll: *Epoll,
    gpa: mem.Allocator,
    task_index: usize,
    socket: *const net.Socket,
) Errors.Accept!void {
    const job_index = try epoll.jobs.borrow_hint(gpa, task_index);
    errdefer epoll.jobs.release(job_index);

    const item = epoll.jobs.get_ptr(job_index);
    item.* = .{
        .job_index = job_index,
        .type = .{
            .accept = .{ .socket = .{
                .handle = socket.handle,
                .kind = socket.kind,
                .addr = .init(socket.addr.family()),
            } },
        },
        .task_index = task_index,
    };

    var event: linux.epoll_event = .{
        .events = linux.EPOLL.IN,
        .data = .{ .u64 = job_index },
    };

    try epoll.add_or_mod_fd(socket.handle, &event);
}

fn queue_connect(
    epoll: *Epoll,
    gpa: mem.Allocator,
    task_index: usize,
    socket: *const net.Socket,
) Errors.Connect!void {
    const job_index = try epoll.jobs.borrow_hint(gpa, task_index);
    errdefer epoll.jobs.release(job_index);

    const item = epoll.jobs.get_ptr(job_index);
    item.* = .{
        .job_index = job_index,
        .type = .{
            .connect = .{ .socket = socket },
        },
        .task_index = task_index,
    };

    syscall.connect(
        socket.handle,
        &socket.addr,
    ) catch |err| switch (err) {
        error.WouldBlock => {},
        else => |e| return e,
    };

    var event: linux.epoll_event = .{
        .events = linux.EPOLL.OUT,
        .data = .{ .u64 = job_index },
    };

    try epoll.add_or_mod_fd(socket.handle, &event);
}

fn queue_recv(
    epoll: *Epoll,
    gpa: mem.Allocator,
    task_index: usize,
    socket: net.Socket.Handle,
    buffer: []u8,
) Errors.Recv!void {
    const job_index = try epoll.jobs.borrow_hint(gpa, task_index);
    errdefer epoll.jobs.release(job_index);

    const item = epoll.jobs.get_ptr(job_index);
    item.* = .{
        .job_index = job_index,
        .type = .{
            .recv = .{
                .socket = socket,
                .buffer = buffer,
            },
        },
        .task_index = task_index,
    };

    var event: linux.epoll_event = .{
        .events = linux.EPOLL.IN,
        .data = .{ .u64 = job_index },
    };

    try epoll.add_or_mod_fd(socket, &event);
}

fn queue_send(
    epoll: *Epoll,
    gpa: mem.Allocator,
    task_index: usize,
    socket: net.Socket.Handle,
    buffer: []const u8,
) Errors.Send!void {
    const job_index = try epoll.jobs.borrow_hint(gpa, task_index);
    errdefer epoll.jobs.release(job_index);

    const item = epoll.jobs.get_ptr(job_index);
    item.* = .{
        .job_index = job_index,
        .type = .{
            .send = .{
                .socket = socket,
                .buffer = buffer,
            },
        },
        .task_index = task_index,
    };

    var event: linux.epoll_event = .{
        .events = linux.EPOLL.OUT,
        .data = .{ .u64 = job_index },
    };

    try epoll.add_or_mod_fd(socket, &event);
}

fn add_or_mod_fd(
    epoll: *Epoll,
    fd: posix.fd_t,
    event: *linux.epoll_event,
) syscall.Errors.EpollCtl!void {
    epoll.add_fd(fd, event) catch |err| switch (err) {
        error.FileDescriptorAlreadyPresentInSet => {
            try epoll.mod_fd(fd, event);
        },
        else => |e| return e,
    };
}

fn add_fd(
    epoll: *Epoll,
    fd: posix.fd_t,
    event: *linux.epoll_event,
) syscall.Errors.EpollCtl!void {
    try syscall.epoll_ctl(
        epoll.epoll_fd,
        linux.EPOLL.CTL_ADD,
        fd,
        event,
    );
}

fn mod_fd(
    epoll: *Epoll,
    fd: posix.fd_t,
    event: *linux.epoll_event,
) syscall.Errors.EpollCtl!void {
    try syscall.epoll_ctl(
        epoll.epoll_fd,
        linux.EPOLL.CTL_MOD,
        fd,
        event,
    );
}

fn remove_fd(epoll: *Epoll, fd: posix.fd_t) syscall.Errors.EpollCtl!void {
    try syscall.epoll_ctl(
        epoll.epoll_fd,
        linux.EPOLL.CTL_DEL,
        fd,
        null,
    );
}

pub fn wake(runner: *anyopaque) syscall.Errors.Write!void {
    const epoll: *Epoll = @ptrCast(@alignCast(runner));

    const bytes: []const u8 = "00000000";
    var i: usize = 0;
    while (i < bytes.len) {
        i += try syscall.write(epoll.wake_event_fd, bytes[i..]);
    }
}

pub fn submit(_: *anyopaque) !void {}

pub fn reap(
    runner: *anyopaque,
    _: mem.Allocator,
    completions: []results.Completion,
    wait: bool,
) ![]results.Completion {
    const epoll: *Epoll = @ptrCast(@alignCast(runner));

    var reaped: usize = 0;
    while (reaped == 0 and wait) {
        const remaining = completions.len - reaped;
        if (remaining == 0) break;

        const timeout: i32 = if (!wait) 0 else -1;

        // Handle all of the epoll I/O
        const epoll_events = syscall.epoll_wait(
            epoll.epoll_fd,
            epoll.events[0..remaining],
            timeout,
        );

        for (epoll.events[0..epoll_events]) |event| {
            const job_index: usize = @intCast(event.data.u64);
            debug.assert(epoll.jobs.dirty.isSet(job_index));

            var job_complete = true;
            defer if (job_complete) epoll.jobs.release(job_index);

            const job = epoll.jobs.get_ptr(job_index);

            const result: results.Result = blk: {
                switch (job.type) {
                    .wake => {
                        // this keeps it in the job queue and we pretty
                        // much never want to remove this fd.
                        job_complete = false;
                        var buffer: [8]u8 = undefined;

                        // Should NEVER fail.
                        _ = syscall.read(
                            epoll.wake_event_fd,
                            buffer[0..],
                        ) catch |err| {
                            log.err("wake failed: {}", .{err});
                            unreachable;
                        };

                        break :blk .wake;
                    },
                    .timer => |timer| {
                        const timer_fd = timer.fd;
                        defer epoll.remove_fd(timer_fd) catch unreachable;
                        debug.assert(event.events & linux.EPOLL.IN != 0);

                        var buffer: [8]u8 = undefined;
                        // Should NEVER fail.
                        _ = syscall.read(
                            timer_fd,
                            buffer[0..],
                        ) catch |err| {
                            log.debug("timer failed: {}", .{err});
                            unreachable;
                        };

                        break :blk .none;
                    },
                    .accept => |*accept| {
                        debug.assert(event.events & linux.EPOLL.IN != 0);

                        const result: results.Results.Accept = result: {
                            const client_fd = syscall.accept(
                                accept.socket.handle,
                                &accept.socket.addr,
                                posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
                            ) catch |err| {
                                const e = switch (err) {
                                    error.WouldBlock => {
                                        job_complete = false;
                                        continue;
                                    },
                                    else => error.Unexpected,
                                };

                                break :result .{ .err = e };
                            };

                            break :result .{ .actual = .{
                                .handle = client_fd,
                                .addr = accept.socket.addr,
                                .kind = accept.socket.kind,
                            } };
                        };

                        break :blk .{ .accept = result };
                    },
                    .connect => {
                        debug.assert(event.events & linux.EPOLL.OUT != 0);

                        const result: results.Results.Connect = result: {
                            if (event.events & linux.EPOLL.ERR != 0) {
                                break :result .{
                                    .err = error.Unexpected,
                                };
                            } else {
                                break :result .actual;
                            }
                        };

                        break :blk .{ .connect = result };
                    },
                    .recv => |recv| {
                        debug.assert(event.events & linux.EPOLL.IN != 0);

                        const result: results.Results.Recv = result: {
                            const length = syscall.recv(
                                recv.socket,
                                recv.buffer,
                                // TODO: support MSG_CMSG_CLOEXEC
                                posix.MSG.DONTWAIT,
                            ) catch |err| {
                                const e = switch (err) {
                                    error.WouldBlock => {
                                        job_complete = false;
                                        continue;
                                    },
                                    else => |e| e,
                                };

                                break :result .{ .err = e };
                            };

                            if (length == 0) break :result .{
                                .err = error.Closed,
                            };
                            break :result .{ .actual = length };
                        };

                        break :blk .{ .recv = result };
                    },
                    .send => |send| {
                        debug.assert(event.events & linux.EPOLL.OUT != 0);

                        const result: results.Results.Send = result: {
                            const length = syscall.send(
                                send.socket,
                                send.buffer,
                                posix.MSG.DONTWAIT,
                            ) catch |err| {
                                const e = switch (err) {
                                    error.WouldBlock => {
                                        job_complete = false;
                                        continue;
                                    },
                                    else => |e| e,
                                };

                                break :result .{ .err = e };
                            };

                            break :result .{ .actual = length };
                        };

                        break :blk .{ .send = result };
                    },
                    .open,
                    .delete,
                    .mkdir,
                    .stat,
                    .read,
                    .write,
                    .close,
                    => unreachable,
                }
            };

            completions[reaped] = .{
                .result = result,
                .task_index = job.task_index,
            };
            reaped += 1;
        }
    }

    return completions[0..reaped];
}

pub fn to_async(epoll: *Epoll) AsyncIO {
    return .{
        .runner = epoll,
        .features = .init(&.{
            .timer,
            .accept,
            .connect,
            .recv,
            .send,
        }),
        .vtable = &.{
            .queue_job = queue_job,
            .deinit = deinit,
            .wake = wake,
            .submit = submit,
            .reap = reap,
        },
    };
}

const log = std.log.scoped(.@"tardy/aio/Epoll");

pub const Errors = struct {
    const Error = syscall.Errors.EpollCtl || pool.Error;

    pub const Timer = syscall.Errors.TimerFdCreate ||
        syscall.Errors.TimerFdSet || Error;
    pub const Send = Error;
    pub const Recv = Error;
    pub const Accept = Error;
    pub const Connect = syscall.Errors.Connect || Error;
    pub const QueueJob = Timer || Send || Recv || Accept || Connect;
};

const std = @import("std");
const debug = std.debug;
const posix = std.posix;
const mem = std.mem;
const Io = std.Io;
const linux = std.os.linux;

const tardy = @import("../root.zig");
const results = tardy.results;
const pool = tardy.core.pool;
const net = tardy.net;
const AsyncIO = tardy.AsyncIO;
const Job = @import("job.zig").Job;
const syscall = @import("syscall.zig");
