const std = @import("std");
const assert = std.debug.assert;
const PosixError = std.posix.E;
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
    kqueue_fd: std.posix.fd_t,

    changes: []std.posix.Kevent,
    change_count: usize = 0,
    events: []std.posix.Kevent,

    jobs: Pool(Job),

    pub fn init(allocator: std.mem.Allocator, options: AsyncOptions) !AsyncKqueue {
        const kqueue_fd = try std.posix.kqueue();
        assert(kqueue_fd > -1);
        errdefer std.posix.close(kqueue_fd);

        const events = try allocator.alloc(std.posix.Kevent, options.size_aio_reap_max);
        const changes = try allocator.alloc(std.posix.Kevent, options.size_aio_reap_max);
        var jobs = try Pool(Job).init(allocator, options.size_tasks_initial + 1, options.pooling);

        const index = jobs.borrow_assume_unset(0);
        const item = jobs.get_ptr(index);
        item.* = .{
            .index = 0,
            .type = .wake,
            .task = undefined,
        };

        const event: std.posix.Kevent = .{
            .ident = WAKE_IDENT,
            .filter = std.posix.system.EVFILT.USER,
            .flags = std.posix.system.EV.ADD | std.posix.system.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };

        _ = try std.posix.kevent(kqueue_fd, &.{event}, &.{}, null);

        return AsyncKqueue{
            .kqueue_fd = kqueue_fd,
            .events = events,
            .changes = changes,
            .change_count = 0,
            .jobs = jobs,
        };
    }

    pub fn inner_deinit(self: *AsyncKqueue, allocator: std.mem.Allocator) void {
        std.posix.close(self.kqueue_fd);
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
                .filter = std.posix.system.EVFILT.TIMER,
                .flags = std.posix.system.EV.ADD | std.posix.system.EV.ONESHOT,
                .fflags = 0,
                .data = milliseconds,
                .udata = index,
            };
        } else return error.ChangeQueueFull;
    }

    fn queue_accept(self: *AsyncKqueue, task: usize, socket: std.posix.socket_t, kind: Socket.Kind) !void {
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
                .filter = std.posix.system.EVFILT.READ,
                .flags = std.posix.system.EV.ADD | std.posix.system.EV.ONESHOT,
                .fflags = 0,
                .data = 0,
                .udata = index,
            };
        } else return error.ChangeQueueFull;
    }

    fn queue_connect(
        self: *AsyncKqueue,
        task: usize,
        socket: std.posix.socket_t,
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
            std.posix.connect(
                socket,
                &addr.any,
                addr.getOsSockLen(),
            ) catch |e| switch (e) {
                std.posix.ConnectError.WouldBlock => {},
                else => return e,
            };

            const event = &self.changes[self.change_count];
            self.change_count += 1;

            event.* = .{
                .ident = @intCast(socket),
                .filter = std.posix.system.EVFILT.WRITE,
                .flags = std.posix.system.EV.ADD | std.posix.system.EV.ONESHOT,
                .fflags = 0,
                .data = 0,
                .udata = index,
            };
        } else return error.ChangeQueueFull;
    }

    fn queue_recv(
        self: *AsyncKqueue,
        task: usize,
        socket: std.posix.socket_t,
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
                .filter = std.posix.system.EVFILT.READ,
                .flags = std.posix.system.EV.ADD | std.posix.system.EV.ONESHOT,
                .fflags = 0,
                .data = 0,
                .udata = index,
            };
        } else return error.ChangeQueueFull;
    }

    fn queue_send(
        self: *AsyncKqueue,
        task: usize,
        socket: std.posix.socket_t,
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
                .filter = std.posix.system.EVFILT.WRITE,
                .flags = std.posix.system.EV.ADD | std.posix.system.EV.ONESHOT,
                .fflags = 0,
                .data = 0,
                .udata = index,
            };
        } else return error.ChangeQueueFull;
    }

    pub fn wake(_: *anyopaque, target_runner: *anyopaque) !void {
        const kqueue: *AsyncKqueue = @ptrCast(@alignCast(target_runner));

        const event: std.posix.Kevent = .{
            .ident = WAKE_IDENT,
            .filter = std.posix.system.EVFILT.USER,
            .flags = std.posix.system.EV.ADD | std.posix.system.EV.ONESHOT,
            .fflags = std.posix.system.NOTE.TRIGGER,
            .data = 0,
            .udata = 0,
        };

        // add a new event to the change list.
        _ = try std.posix.kevent(kqueue.kqueue_fd, &.{event}, &.{}, null);
    }

    pub fn submit(runner: *anyopaque) !void {
        const kqueue: *AsyncKqueue = @ptrCast(@alignCast(runner));
        _ = try std.posix.kevent(kqueue.kqueue_fd, kqueue.changes[0..kqueue.change_count], &.{}, null);
        kqueue.change_count = 0;
    }

    pub fn reap(runner: *anyopaque, completions: []Completion, wait: bool) ![]Completion {
        const kqueue: *AsyncKqueue = @ptrCast(@alignCast(runner));
        var reaped: usize = 0;

        while (reaped == 0 and wait) {
            const remaining = completions.len - reaped;
            if (remaining == 0) break;

            const timeout_spec: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
            const timeout: ?*const std.posix.timespec = if (!wait or reaped > 0) &timeout_spec else null;
            log.debug("remaining count={d}", .{remaining});

            // Handle all of the kqueue I/O
            const kqueue_events = try std.posix.kevent(
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
                            assert(event.filter == std.posix.system.EVFILT.USER);
                            assert(event.ident == WAKE_IDENT);
                            job_complete = false;
                            break :blk .wake;
                        },
                        .timer => |inner| {
                            assert(event.filter == std.posix.system.EVFILT.TIMER);
                            assert(inner == .none);
                            break :blk .none;
                        },
                        .accept => |*inner| {
                            assert(event.filter == std.posix.system.EVFILT.READ);
                            const rc = std.posix.system.accept(
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
                                const e: PosixError = std.posix.errno(rc);
                                const err = switch (e) {
                                    PosixError.AGAIN => AcceptError.WouldBlock,
                                    PosixError.BADF => AcceptError.InvalidFd,
                                    PosixError.CONNABORTED => AcceptError.ConnectionAborted,
                                    PosixError.FAULT => AcceptError.InvalidAddress,
                                    PosixError.INTR => AcceptError.Interrupted,
                                    PosixError.INVAL => AcceptError.NotListening,
                                    PosixError.MFILE => AcceptError.ProcessFdQuotaExceeded,
                                    PosixError.NFILE => AcceptError.SystemFdQuotaExceeded,
                                    PosixError.NOBUFS, PosixError.NOMEM => AcceptError.OutOfMemory,
                                    PosixError.NOTSOCK => AcceptError.NotASocket,
                                    PosixError.OPNOTSUPP => AcceptError.OperationNotSupported,
                                    else => AcceptError.Unexpected,
                                };

                                break :result .{ .err = err };
                            };

                            break :blk .{ .accept = result };
                        },
                        .connect => |_| {
                            assert(event.filter == std.posix.system.EVFILT.WRITE);

                            const result: ConnectResult = result: {
                                if (event.flags & std.posix.system.EV.ERROR != 0) {
                                    const rc = event.data;
                                    const err = switch (std.posix.errno(rc)) {
                                        PosixError.AGAIN,
                                        PosixError.ALREADY,
                                        PosixError.INPROGRESS,
                                        => unreachable,
                                        PosixError.ACCES, PosixError.PERM => ConnectError.AccessDenied,
                                        PosixError.ADDRINUSE => ConnectError.AddressInUse,
                                        PosixError.ADDRNOTAVAIL => ConnectError.AddressNotAvailable,
                                        PosixError.AFNOSUPPORT => ConnectError.AddressFamilyNotSupported,
                                        PosixError.BADF => ConnectError.InvalidFd,
                                        PosixError.CONNREFUSED => ConnectError.ConnectionRefused,
                                        PosixError.FAULT => ConnectError.InvalidAddress,
                                        PosixError.INTR => ConnectError.Interrupted,
                                        PosixError.ISCONN => ConnectError.AlreadyConnected,
                                        PosixError.NETUNREACH => ConnectError.NetworkUnreachable,
                                        PosixError.NOTSOCK => ConnectError.NotASocket,
                                        PosixError.PROTOTYPE => ConnectError.ProtocolFamilyNotSupported,
                                        PosixError.TIMEDOUT => ConnectError.TimedOut,
                                        else => ConnectError.Unexpected,
                                    };
                                    break :result .{ .err = err };
                                } else break :result .actual;
                            };

                            break :blk .{ .connect = result };
                        },
                        .recv => |inner| {
                            assert(event.filter == std.posix.system.EVFILT.READ);
                            const rc = std.posix.system.recvfrom(
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
                                const e: PosixError = std.posix.errno(rc);
                                const err = switch (e) {
                                    PosixError.AGAIN => RecvError.WouldBlock,
                                    PosixError.BADF => RecvError.InvalidFd,
                                    PosixError.CONNREFUSED => RecvError.ConnectionRefused,
                                    PosixError.FAULT => RecvError.InvalidAddress,
                                    PosixError.INTR => RecvError.Interrupted,
                                    PosixError.INVAL => RecvError.InvalidArguments,
                                    PosixError.NOMEM => RecvError.OutOfMemory,
                                    PosixError.NOTCONN => RecvError.NotConnected,
                                    PosixError.NOTSOCK => RecvError.NotASocket,
                                    else => RecvError.Unexpected,
                                };

                                break :result .{ .err = err };
                            };

                            break :blk .{ .recv = result };
                        },
                        .send => |inner| {
                            assert(event.filter == std.posix.system.EVFILT.WRITE);
                            const rc = std.posix.system.send(inner.socket, inner.buffer.ptr, inner.buffer.len, 0);
                            if (rc >= 0) break :blk .{ .send = .{ .actual = @intCast(rc) } };

                            const result: SendResult = result: {
                                const e: PosixError = std.posix.errno(rc);
                                const err = switch (e) {
                                    PosixError.AGAIN => SendError.WouldBlock,
                                    PosixError.ACCES => SendError.AccessDenied,
                                    PosixError.ALREADY => SendError.OpenInProgress,
                                    PosixError.BADF => SendError.InvalidFd,
                                    PosixError.CONNRESET, PosixError.PIPE => SendError.Closed,
                                    PosixError.DESTADDRREQ => SendError.NoDestinationAddress,
                                    PosixError.FAULT => SendError.InvalidAddress,
                                    PosixError.INTR => SendError.Interrupted,
                                    PosixError.INVAL => SendError.InvalidArguments,
                                    PosixError.ISCONN => SendError.AlreadyConnected,
                                    PosixError.MSGSIZE => SendError.InvalidSize,
                                    PosixError.NOBUFS, PosixError.NOMEM => SendError.OutOfMemory,
                                    PosixError.NOTCONN => SendError.NotConnected,
                                    PosixError.OPNOTSUPP => SendError.OperationNotSupported,
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
        return Async{
            .runner = self,
            .features = AsyncFeatures.init(&.{
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
