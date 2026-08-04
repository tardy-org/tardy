pub const Kqueue = @This();

kqueue_fd: posix.fd_t,
changes: []posix.Kevent,
change_count: usize = 0,
events: []posix.Kevent,

jobs: pool.Pool(Job),

pub fn init(allocator: mem.Allocator, options: AsyncIO.Options) !Kqueue {
    const kqueue_fd = try syscall.kqueue();
    debug.assert(kqueue_fd > -1);
    errdefer syscall.close(kqueue_fd);

    const events = try allocator.alloc(
        posix.Kevent,
        options.size_aio_reap_max,
    );
    const changes = try allocator.alloc(
        posix.Kevent,
        options.size_aio_reap_max,
    );
    var jobs: pool.Pool(Job) = try .init(
        allocator,
        options.size_tasks_initial + 1,
        options.pooling,
    );

    const index = jobs.borrow_assume_unset(0);
    const item = jobs.get_ptr(index);
    item.* = .{
        .index = 0,
        .type = .wake,
        .task = undefined,
    };

    const event: posix.Kevent = .{
        .ident = WAKE_IDENT,
        .filter = posix.system.EVFILT.USER,
        .flags = posix.system.EV.ADD | posix.system.EV.CLEAR,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };

    _ = try syscall.kevent(
        kqueue_fd,
        &.{event},
        &.{},
        null,
    );

    return .{
        .kqueue_fd = kqueue_fd,
        .events = events,
        .changes = changes,
        .change_count = 0,
        .jobs = jobs,
    };
}

pub fn inner_deinit(kqueue: *Kqueue, allocator: mem.Allocator) void {
    syscall.close(kqueue.kqueue_fd);
    allocator.free(kqueue.events);
    allocator.free(kqueue.changes);
    kqueue.jobs.deinit(allocator);
}

pub fn deinit(runner: *anyopaque, allocator: mem.Allocator) void {
    const kqueue: *Kqueue = @ptrCast(@alignCast(runner));
    kqueue.inner_deinit(allocator);
}

pub fn queue_job(
    runner: *anyopaque,
    allocator: mem.Allocator,
    task: usize,
    job: AsyncIO.Submission,
) Errors.QueueJob!void {
    const kqueue: *Kqueue = @ptrCast(@alignCast(runner));

    (switch (job) {
        .timer => |timer| kqueue.queue_timer(
            allocator,
            task,
            timer,
        ),
        .accept => |accept| kqueue.queue_accept(
            allocator,
            task,
            accept.socket,
            accept.kind,
        ),
        .connect => |connect| kqueue.queue_connect(
            allocator,
            task,
            connect.socket,
            connect.addr,
            connect.kind,
        ),
        .recv => |recv| kqueue.queue_recv(
            allocator,
            task,
            recv.socket,
            recv.buffer,
        ),
        .send => |send| kqueue.queue_send(
            allocator,
            task,
            send.socket,
            send.buffer,
        ),
        .open, .delete, .mkdir, .stat, .read, .write, .close => unreachable,
    }) catch |e| if (e == error.ChangeQueueFull) {
        try submit(runner);
        try queue_job(runner, allocator, task, job);
    } else return e;
}

fn queue_timer(
    kqueue: *Kqueue,
    allocator: mem.Allocator,
    task: usize,
    duration: Io.Duration,
) Error!void {
    const index = try kqueue.jobs.borrow_hint(allocator, task);
    errdefer kqueue.jobs.release(index);

    const item = kqueue.jobs.get_ptr(index);

    item.* = .{
        .index = index,
        .type = .{ .timer = .none },
        .task = task,
    };

    // kqueue uses milliseconds.
    const milliseconds = duration.toMilliseconds();

    if (kqueue.change_count < kqueue.changes.len) {
        const event = &kqueue.changes[kqueue.change_count];
        kqueue.change_count += 1;

        event.* = .{
            .ident = index,
            .filter = posix.system.EVFILT.TIMER,
            .flags = posix.system.EV.ADD | posix.system.EV.ONESHOT,
            .fflags = 0,
            .data = milliseconds,
            .udata = index,
        };
    } else return error.ChangeQueueFull;
}

fn queue_accept(
    kqueue: *Kqueue,
    allocator: mem.Allocator,
    task: usize,
    socket: net.Socket.Handle,
    kind: net.Socket.Kind,
) Error!void {
    const index = try kqueue.jobs.borrow_hint(allocator, task);
    errdefer kqueue.jobs.release(index);

    const item = kqueue.jobs.get_ptr(index);
    item.* = .{
        .index = index,
        .type = .{
            .accept = .{
                .socket = socket,
                .addr = .wildcard,
                .kind = kind,
            },
        },
        .task = task,
    };

    if (kqueue.change_count < kqueue.changes.len) {
        const event = &kqueue.changes[kqueue.change_count];
        kqueue.change_count += 1;

        event.* = .{
            .ident = @intCast(socket),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.ADD | posix.system.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = index,
        };
    } else return error.ChangeQueueFull;
}

fn queue_connect(
    kqueue: *Kqueue,
    allocator: mem.Allocator,
    task: usize,
    socket: net.Socket.Handle,
    // TODO: take *const
    addr: net.Socket.Address,
    kind: net.Socket.Kind,
) Errors.Connect!void {
    const index = try kqueue.jobs.borrow_hint(allocator, task);
    errdefer kqueue.jobs.release(index);

    const item = kqueue.jobs.get_ptr(index);
    item.* = .{
        .index = index,
        .type = .{
            .connect = .{
                .socket = socket,
                .addr = addr,
                .kind = kind,
            },
        },
        .task = task,
    };

    if (kqueue.change_count < kqueue.changes.len) {
        syscall.connect(
            socket,
            &addr,
        ) catch |e| switch (e) {
            error.WouldBlock => {},
            else => |err| return err,
        };

        const event = &kqueue.changes[kqueue.change_count];
        kqueue.change_count += 1;

        event.* = .{
            .ident = @intCast(socket),
            .filter = posix.system.EVFILT.WRITE,
            .flags = posix.system.EV.ADD | posix.system.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = index,
        };
    } else return error.ChangeQueueFull;
}

fn queue_recv(
    kqueue: *Kqueue,
    allocator: mem.Allocator,
    task: usize,
    socket: net.Socket.Handle,
    buffer: []u8,
) Error!void {
    const index = try kqueue.jobs.borrow_hint(allocator, task);
    errdefer kqueue.jobs.release(index);

    const item = kqueue.jobs.get_ptr(index);
    item.* = .{
        .index = index,
        .type = .{
            .recv = .{
                .socket = socket,
                .buffer = buffer,
            },
        },
        .task = task,
    };

    if (kqueue.change_count < kqueue.changes.len) {
        const event = &kqueue.changes[kqueue.change_count];
        kqueue.change_count += 1;

        event.* = .{
            .ident = @intCast(socket),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.ADD | posix.system.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = index,
        };
    } else return error.ChangeQueueFull;
}

fn queue_send(
    kqueue: *Kqueue,
    allocator: mem.Allocator,
    task: usize,
    socket: net.Socket.Handle,
    buffer: []const u8,
) Error!void {
    const index = try kqueue.jobs.borrow_hint(allocator, task);
    errdefer kqueue.jobs.release(index);

    const item = kqueue.jobs.get_ptr(index);
    item.* = .{
        .index = index,
        .type = .{
            .send = .{
                .socket = socket,
                .buffer = buffer,
            },
        },
        .task = task,
    };

    if (kqueue.change_count < kqueue.changes.len) {
        const event = &kqueue.changes[kqueue.change_count];
        kqueue.change_count += 1;

        event.* = .{
            .ident = @intCast(socket),
            .filter = posix.system.EVFILT.WRITE,
            .flags = posix.system.EV.ADD | posix.system.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = index,
        };
    } else return error.ChangeQueueFull;
}

pub fn wake(runner: *anyopaque) Errors.Wake!void {
    const kqueue: *Kqueue = @ptrCast(@alignCast(runner));

    const event: posix.Kevent = .{
        .ident = WAKE_IDENT,
        .filter = posix.system.EVFILT.USER,
        .flags = posix.system.EV.ADD | posix.system.EV.ONESHOT,
        .fflags = posix.system.NOTE.TRIGGER,
        .data = 0,
        .udata = 0,
    };

    // add a new event to the change list.
    _ = try syscall.kevent(
        kqueue.kqueue_fd,
        &.{event},
        &.{},
        null,
    );
}

pub fn submit(runner: *anyopaque) Errors.Submit!void {
    const kqueue: *Kqueue = @ptrCast(@alignCast(runner));
    _ = try syscall.kevent(
        kqueue.kqueue_fd,
        kqueue.changes[0..kqueue.change_count],
        &.{},
        null,
    );
    kqueue.change_count = 0;
}

pub fn reap(
    runner: *anyopaque,
    _: mem.Allocator,
    completions: []results.Completion,
    wait: bool,
) ![]results.Completion {
    const kqueue: *Kqueue = @ptrCast(@alignCast(runner));
    var reaped: usize = 0;

    while (reaped == 0 and wait) {
        const remaining = completions.len - reaped;
        if (remaining == 0) break;

        const timeout_spec: posix.timespec = .{ .sec = 0, .nsec = 0 };
        const timeout: ?*const posix.timespec = if (!wait or reaped > 0) &timeout_spec else null;
        log.debug("remaining count={d}", .{remaining});

        // Handle all of the kqueue I/O
        const kqueue_events = try syscall.kevent(
            kqueue.kqueue_fd,
            &.{},
            kqueue.events[0..remaining],
            timeout,
        );

        for (kqueue.events[0..kqueue_events]) |event| {
            const job_index = event.udata;
            debug.assert(kqueue.jobs.dirty.isSet(job_index));

            var job_complete = true;
            defer if (job_complete) kqueue.jobs.release(job_index);

            const job = kqueue.jobs.get_ptr(job_index);

            const result: results.Result = result: {
                switch (job.type) {
                    .wake => {
                        debug.assert(event.filter == posix.system.EVFILT.USER);
                        debug.assert(event.ident == WAKE_IDENT);
                        job_complete = false;
                        break :result .wake;
                    },
                    .timer => |timer| {
                        debug.assert(event.filter == posix.system.EVFILT.TIMER);
                        debug.assert(timer == .none);
                        break :result .none;
                    },
                    .accept => |*accept| {
                        debug.assert(event.filter == posix.system.EVFILT.READ);

                        const socket_fd = syscall.accept(
                            accept.socket,
                            &accept.addr,
                            0,
                        ) catch |err| break :result .{
                            .accept = .{
                                .err = err,
                            },
                        };

                        break :result .{
                            .accept = .{
                                .actual = .{
                                    .handle = socket_fd,
                                    .addr = accept.addr,
                                    .kind = accept.kind,
                                },
                            },
                        };
                    },
                    .connect => {
                        debug.assert(event.filter == posix.system.EVFILT.WRITE);

                        const ConnectError = results.ConnectError;
                        const result: results.ConnectResult = blk: {
                            if (event.flags & posix.system.EV.ERROR != 0) {
                                const rc = event.data;
                                const err = switch (posix.errno(rc)) {
                                    .AGAIN,
                                    .ALREADY,
                                    .INPROGRESS,
                                    => unreachable,
                                    .ACCES, .PERM => ConnectError.AccessDenied,
                                    .ADDRINUSE => ConnectError.AddressInUse,
                                    .ADDRNOTAVAIL => ConnectError.AddressNotAvailable,
                                    .AFNOSUPPORT => ConnectError.AddressFamilyNotSupported,
                                    .BADF => ConnectError.InvalidFd,
                                    .CONNREFUSED => ConnectError.ConnectionRefused,
                                    .FAULT => ConnectError.InvalidAddress,
                                    .INTR => ConnectError.Interrupted,
                                    .ISCONN => ConnectError.AlreadyConnected,
                                    .NETUNREACH => ConnectError.NetworkUnreachable,
                                    .NOTSOCK => ConnectError.NotASocket,
                                    .PROTOTYPE => ConnectError.ProtocolFamilyNotSupported,
                                    .TIMEDOUT => ConnectError.TimedOut,
                                    else => ConnectError.Unexpected,
                                };
                                break :blk .{ .err = err };
                            } else break :blk .actual;
                        };

                        break :result .{
                            .connect = result,
                        };
                    },
                    .recv => |recv| {
                        debug.assert(event.filter == posix.system.EVFILT.READ);
                        const rc = syscall.recvfrom(
                            recv.socket,
                            recv.buffer,
                            0,
                            null,
                            null,
                        ) catch |err| break :result .{
                            .recv = .{
                                .err = err,
                            },
                        };

                        break :result if (rc == 0)
                            .{
                                .recv = .{
                                    .err = results.RecvError.Closed,
                                },
                            }
                        else
                            break :result .{
                                .recv = .{
                                    .actual = @intCast(rc),
                                },
                            };
                    },
                    .send => |send| {
                        debug.assert(event.filter == posix.system.EVFILT.WRITE);
                        const rc = syscall.send(
                            send.socket,
                            send.buffer,
                            0,
                        ) catch |err| {
                            break :result .{
                                .send = .{
                                    .err = err,
                                },
                            };
                        };

                        break :result .{
                            .send = .{
                                .actual = @intCast(rc),
                            },
                        };
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
                .task = job.task,
            };
            reaped += 1;
        }
    }

    return completions[0..reaped];
}

pub fn to_async(kqueue: *Kqueue) AsyncIO {
    return .{
        .runner = kqueue,
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

const log = std.log.scoped(.@"tardy/aio/Kqueue");

pub const Errors = struct {
    pub const Connect = syscall.ConnectError || Error;
    pub const Submit = syscall.KEventError;
    pub const Wake = syscall.KEventError;
    pub const QueueJob = Connect || Submit || Wake || Error;
};
const Error = error{ChangeQueueFull} || pool.Error;

const WAKE_IDENT = 1;

const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const Io = std.Io;
const posix = std.posix;

const tardy = @import("../root.zig");
const results = tardy.results;
const pool = tardy.core.pool;
const net = tardy.net;
const AsyncIO = tardy.AsyncIO;
const Job = @import("job.zig").Job;
const syscall = @import("syscall.zig");
