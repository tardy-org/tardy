const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const Atomic = std.atomic.Value;

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

const log = std.log.scoped(.@"tardy/aio/kqueue");

const WAKE_IDENT = 1;

pub const AsyncKqueue = struct {
    kqueue_fd: posix.fd_t,

    changes: []posix.Kevent,
    change_count: usize = 0,
    events: []posix.Kevent,

    jobs: Pool(Job),

    pub fn init(allocator: std.mem.Allocator, options: AsyncOptions) !AsyncKqueue {
        const kqueue_fd = try posix.kqueue();
        assert(kqueue_fd > -1);
        errdefer posix.close(kqueue_fd);

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

        _ = try posix.kevent(kqueue_fd, &.{event}, &.{}, null);

        return AsyncKqueue{
            .kqueue_fd = kqueue_fd,
            .events = events,
            .changes = changes,
            .change_count = 0,
            .jobs = jobs,
        };
    }

    pub fn inner_deinit(self: *AsyncKqueue, allocator: std.mem.Allocator) void {
        posix.close(self.kqueue_fd);
        allocator.free(self.events);
        allocator.free(self.changes);
        self.jobs.deinit();
    }

    pub fn deinit(runner: *anyopaque, allocator: std.mem.Allocator) void {
        const kqueue: *AsyncKqueue = @ptrCast(@alignCast(runner));
        kqueue.inner_deinit(allocator);
    }

    pub fn queue_job(runner: *anyopaque, task: usize, job: AsyncSubmission) !void {
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

    fn queue_timer(self: *AsyncKqueue, task: usize, timespec: Timespec) !void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);
        const item = self.jobs.get_ptr(index);

        item.* = .{
            .index = index,
            .type = .{ .timer = .none },
            .task = task,
        };

        // kqueue uses milliseconds.
        const milliseconds: isize = @intCast(
            timespec.seconds * 1000 + @divFloor(timespec.nanos, std.time.ns_per_ms),
        );

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

    fn queue_accept(self: *AsyncKqueue, task: usize, socket: posix.socket_t, kind: Socket.Kind) !void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);
        const item = self.jobs.get_ptr(index);
        item.* = .{
            .index = index,
            .type = .{
                .accept = .{
                    .socket = socket,
                    .addr = undefined,
                    .addr_len = @sizeOf(std.net.Address),
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
        socket: posix.socket_t,
        addr: std.net.Address,
        kind: Socket.Kind,
    ) !void {
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
            posix.connect(
                socket,
                &addr.any,
                addr.getOsSockLen(),
            ) catch |e| switch (e) {
                posix.ConnectError.WouldBlock => {},
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
        socket: posix.socket_t,
        buffer: []u8,
    ) !void {
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
        socket: posix.socket_t,
        buffer: []const u8,
    ) !void {
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

    pub fn wake(runner: *anyopaque) !void {
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
        _ = try posix.kevent(kqueue.kqueue_fd, &.{event}, &.{}, null);
    }

    pub fn submit(runner: *anyopaque) !void {
        const kqueue: *AsyncKqueue = @ptrCast(@alignCast(runner));
        _ = try posix.kevent(kqueue.kqueue_fd, kqueue.changes[0..kqueue.change_count], &.{}, null);
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
            const kqueue_events = try posix.kevent(
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

                const result: Result = blk: {
                    switch (job.type) {
                        .wake => {
                            assert(event.filter == posix.system.EVFILT.USER);
                            assert(event.ident == WAKE_IDENT);
                            job_complete = false;
                            break :blk .wake;
                        },
                        .timer => |inner| {
                            assert(event.filter == posix.system.EVFILT.TIMER);
                            assert(inner == .none);
                            break :blk .none;
                        },
                        .accept => |*inner| {
                            assert(event.filter == posix.system.EVFILT.READ);
                            const rc = posix.system.accept(
                                inner.socket,
                                &inner.addr.any,
                                @ptrCast(&inner.addr_len),
                            );

                            if (rc >= 0) break :blk .{ .accept = .{
                                .actual = .{
                                    .handle = @intCast(rc),
                                    .addr = inner.addr,
                                    .kind = inner.kind,
                                },
                            } };

                            const result: AcceptResult = result: {
                                const e: posix.E = posix.errno(rc);
                                const err = switch (e) {
                                    .AGAIN => AcceptError.WouldBlock,
                                    .BADF => AcceptError.InvalidFd,
                                    .CONNABORTED => AcceptError.ConnectionAborted,
                                    .FAULT => AcceptError.InvalidAddress,
                                    .INTR => AcceptError.Interrupted,
                                    .INVAL => AcceptError.NotListening,
                                    .MFILE => AcceptError.ProcessFdQuotaExceeded,
                                    .NFILE => AcceptError.SystemFdQuotaExceeded,
                                    .NOBUFS, .NOMEM => AcceptError.OutOfMemory,
                                    .NOTSOCK => AcceptError.NotASocket,
                                    .OPNOTSUPP => AcceptError.OperationNotSupported,
                                    else => AcceptError.Unexpected,
                                };

                                break :result .{ .err = err };
                            };

                            break :blk .{ .accept = result };
                        },
                        .connect => {
                            assert(event.filter == posix.system.EVFILT.WRITE);

                            const result: ConnectResult = result: {
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
                                    break :result .{ .err = err };
                                } else break :result .actual;
                            };

                            break :blk .{ .connect = result };
                        },
                        .recv => |inner| {
                            assert(event.filter == posix.system.EVFILT.READ);
                            const rc = posix.system.recvfrom(
                                inner.socket,
                                inner.buffer.ptr,
                                inner.buffer.len,
                                0,
                                null,
                                null,
                            );

                            if (rc > 0) break :blk .{ .recv = .{ .actual = @intCast(rc) } };
                            if (rc == 0) break :blk .{ .recv = .{ .err = RecvError.Closed } };

                            const result: RecvResult = result: {
                                const e: posix.E = posix.errno(rc);
                                const err = switch (e) {
                                    .AGAIN => RecvError.WouldBlock,
                                    .BADF => RecvError.InvalidFd,
                                    .CONNREFUSED => RecvError.ConnectionRefused,
                                    .FAULT => RecvError.InvalidAddress,
                                    .INTR => RecvError.Interrupted,
                                    .INVAL => RecvError.InvalidArguments,
                                    .NOMEM => RecvError.OutOfMemory,
                                    .NOTCONN => RecvError.NotConnected,
                                    .NOTSOCK => RecvError.NotASocket,
                                    else => RecvError.Unexpected,
                                };

                                break :result .{ .err = err };
                            };

                            break :blk .{ .recv = result };
                        },
                        .send => |inner| {
                            assert(event.filter == posix.system.EVFILT.WRITE);
                            const rc = posix.system.send(inner.socket, inner.buffer.ptr, inner.buffer.len, 0);
                            if (rc >= 0) break :blk .{ .send = .{ .actual = @intCast(rc) } };

                            const result: SendResult = result: {
                                const e: posix.E = posix.errno(rc);
                                const err = switch (e) {
                                    .AGAIN => SendError.WouldBlock,
                                    .ACCES => SendError.AccessDenied,
                                    .ALREADY => SendError.OpenInProgress,
                                    .BADF => SendError.InvalidFd,
                                    .CONNRESET, .PIPE => SendError.Closed,
                                    .DESTADDRREQ => SendError.NoDestinationAddress,
                                    .FAULT => SendError.InvalidAddress,
                                    .INTR => SendError.Interrupted,
                                    .INVAL => SendError.InvalidArguments,
                                    .ISCONN => SendError.AlreadyConnected,
                                    .MSGSIZE => SendError.InvalidSize,
                                    .NOBUFS, .NOMEM => SendError.OutOfMemory,
                                    .NOTCONN => SendError.NotConnected,
                                    .OPNOTSUPP => SendError.OperationNotSupported,
                                    else => SendError.Unexpected,
                                };

                                break :result .{ .err = err };
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
