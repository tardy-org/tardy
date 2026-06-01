const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const posix = std.posix;
const Atomic = std.atomic.Value;
const pool = @import("../../core/pool.zig");

const Pool = @import("../../core/pool.zig").Pool;
const Timespec = @import("../../lib.zig").Timespec;
const Socket = @import("../../net/lib.zig").Socket;
const Completion = @import("../completion.zig").Completion;
const Result = @import("../completion.zig").Result;
const AcceptResult = @import("../completion.zig").AcceptResult;
const AcceptError = @import("../completion.zig").AcceptError;
const ConnectResult = @import("../completion.zig").ConnectResult;
const ConnectError = @import("../completion.zig").ConnectError;
const RecvResult = @import("../completion.zig").RecvResult;
const RecvError = @import("../completion.zig").RecvError;
const SendResult = @import("../completion.zig").SendResult;
const SendError = @import("../completion.zig").SendError;
const Job = @import("../job.zig").Job;
const Async = @import("../lib.zig").Async;
const AsyncOptions = @import("../lib.zig").AsyncOptions;
const AsyncFeatures = @import("../lib.zig").AsyncFeatures;
const AsyncSubmission = @import("../lib.zig").AsyncSubmission;
const syscall = @import("syscall.zig");

const log = std.log.scoped(.@"tardy/aio/kqueue");

pub const Errors = struct {
    pub const Connect = syscall.ConnectError || Error;
    pub const Submit = syscall.KEventError;
    pub const Wake = syscall.KEventError;
    pub const QueueJob = Connect || Submit || Wake || Error;
};
const Error = error{ChangeQueueFull} || pool.Error;

const WAKE_IDENT = 1;

pub const AsyncKqueue = struct {
    kqueue_fd: posix.fd_t,

    changes: []posix.Kevent,
    change_count: usize = 0,
    events: []posix.Kevent,

    jobs: Pool(Job),

    pub fn init(allocator: std.mem.Allocator, options: AsyncOptions) !AsyncKqueue {
        const kqueue_fd = try syscall.kqueue();
        assert(kqueue_fd > -1);
        errdefer syscall.close(kqueue_fd);

        const events = try allocator.alloc(posix.Kevent, options.size_aio_reap_max);
        const changes = try allocator.alloc(posix.Kevent, options.size_aio_reap_max);
        var jobs: Pool(Job) = try .init(allocator, options.size_tasks_initial + 1, options.pooling);

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

        _ = try syscall.kevent(kqueue_fd, &.{event}, &.{}, null);

        return .{
            .kqueue_fd = kqueue_fd,
            .events = events,
            .changes = changes,
            .change_count = 0,
            .jobs = jobs,
        };
    }

    pub fn inner_deinit(self: *AsyncKqueue, allocator: std.mem.Allocator) void {
        syscall.close(self.kqueue_fd);
        allocator.free(self.events);
        allocator.free(self.changes);
        self.jobs.deinit();
    }

    pub fn deinit(runner: *anyopaque, allocator: std.mem.Allocator) void {
        const kqueue: *AsyncKqueue = @ptrCast(@alignCast(runner));
        kqueue.inner_deinit(allocator);
    }

    pub fn queue_job(runner: *anyopaque, task: usize, job: AsyncSubmission) Errors.QueueJob!void {
        const kqueue: *AsyncKqueue = @ptrCast(@alignCast(runner));

        (switch (job) {
            .timer => |inner| queue_timer(kqueue, task, inner),
            .accept => |inner| queue_accept(kqueue, task, inner.socket, inner.kind),
            .connect => |inner| queue_connect(kqueue, task, inner.socket, inner.addr, inner.kind),
            .recv => |inner| queue_recv(kqueue, task, inner.socket, inner.buffer),
            .send => |inner| queue_send(kqueue, task, inner.socket, inner.buffer),
            .open, .delete, .mkdir, .stat, .read, .write, .close => unreachable,
        }) catch |e| if (e == error.ChangeQueueFull) {
            try submit(runner);
            try queue_job(runner, task, job);
        } else return e;
    }

    fn queue_timer(self: *AsyncKqueue, task: usize, duration: Io.Duration) Error!void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);
        const item = self.jobs.get_ptr(index);

        item.* = .{
            .index = index,
            .type = .{ .timer = .none },
            .task = task,
        };

        // kqueue uses milliseconds.
        const milliseconds = duration.toMilliseconds();

        if (self.change_count < self.changes.len) {
            const event = &self.changes[self.change_count];
            self.change_count += 1;

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
        self: *AsyncKqueue,
        task: usize,
        socket: Socket.Handle,
        kind: Socket.Kind,
    ) Error!void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);
        const item = self.jobs.get_ptr(index);
        item.* = .{
            .index = index,
            .type = .{
                .accept = .{
                    .socket = socket,
                    .addr = .empty,
                    .kind = kind,
                },
            },
            .task = task,
        };

        if (self.change_count < self.changes.len) {
            const event = &self.changes[self.change_count];
            self.change_count += 1;

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
        self: *AsyncKqueue,
        task: usize,
        socket: Socket.Handle,
        addr: Socket.Address,
        kind: Socket.Kind,
    ) Errors.Connect!void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);
        const item = self.jobs.get_ptr(index);
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

        if (self.change_count < self.changes.len) {
            syscall.connect(
                socket,
                addr,
            ) catch |e| switch (e) {
                error.WouldBlock => {},
                else => |err| return err,
            };

            const event = &self.changes[self.change_count];
            self.change_count += 1;

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
        self: *AsyncKqueue,
        task: usize,
        socket: Socket.Handle,
        buffer: []u8,
    ) Error!void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);
        const item = self.jobs.get_ptr(index);
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

        if (self.change_count < self.changes.len) {
            const event = &self.changes[self.change_count];
            self.change_count += 1;

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
        self: *AsyncKqueue,
        task: usize,
        socket: Socket.Handle,
        buffer: []const u8,
    ) Error!void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);
        const item = self.jobs.get_ptr(index);
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

        if (self.change_count < self.changes.len) {
            const event = &self.changes[self.change_count];
            self.change_count += 1;

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
        const kqueue: *AsyncKqueue = @ptrCast(@alignCast(runner));

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
        const kqueue: *AsyncKqueue = @ptrCast(@alignCast(runner));
        _ = try syscall.kevent(
            kqueue.kqueue_fd,
            kqueue.changes[0..kqueue.change_count],
            &.{},
            null,
        );
        kqueue.change_count = 0;
    }

    pub fn reap(runner: *anyopaque, completions: []Completion, wait: bool) ![]Completion {
        const kqueue: *AsyncKqueue = @ptrCast(@alignCast(runner));
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
                assert(kqueue.jobs.dirty.isSet(job_index));

                var job_complete = true;
                defer if (job_complete) kqueue.jobs.release(job_index);

                const job = kqueue.jobs.get_ptr(job_index);

                const result: Result = result: {
                    switch (job.type) {
                        .wake => {
                            assert(event.filter == posix.system.EVFILT.USER);
                            assert(event.ident == WAKE_IDENT);
                            job_complete = false;
                            break :result .wake;
                        },
                        .timer => |inner| {
                            assert(event.filter == posix.system.EVFILT.TIMER);
                            assert(inner == .none);
                            break :result .none;
                        },
                        .accept => |*inner| {
                            assert(event.filter == posix.system.EVFILT.READ);
                            var sockaddr, var socklen = inner.addr.toPosix();

                            const socket_fd = syscall.accept(
                                inner.socket,
                                &sockaddr,
                                &socklen,
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
                                        .addr = inner.addr,
                                        .kind = inner.kind,
                                    },
                                },
                            };
                        },
                        .connect => {
                            assert(event.filter == posix.system.EVFILT.WRITE);

                            const result: ConnectResult = blk: {
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
                        .recv => |inner| {
                            assert(event.filter == posix.system.EVFILT.READ);
                            const rc = syscall.recvfrom(
                                inner.socket,
                                inner.buffer,
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
                                        .err = RecvError.Closed,
                                    },
                                }
                            else
                                break :result .{
                                    .recv = .{
                                        .actual = @intCast(rc),
                                    },
                                };
                        },
                        .send => |inner| {
                            assert(event.filter == posix.system.EVFILT.WRITE);
                            const rc = syscall.send(
                                inner.socket,
                                inner.buffer,
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

    pub fn to_async(self: *AsyncKqueue) Async {
        return .{
            .runner = self,
            .features = .init(&.{
                .timer,
                .accept,
                .connect,
                .recv,
                .send,
            }),
            .vtable = .{
                .queue_job = queue_job,
                .deinit = deinit,
                .wake = wake,
                .submit = submit,
                .reap = reap,
            },
        };
    }
};
