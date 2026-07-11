const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const mem = std.mem;
const Io = std.Io;
const linux = std.os.linux;

const Cross = @import("../../cross/lib.zig");
const File = @import("../../fs/file.zig").File;
const Stat = @import("../../fs/lib.zig").Stat;
const Path = @import("../../fs/lib.zig").Path;
const Socket = @import("../../net/lib.zig").Socket;
const tardy = @import("../../root.zig");
const results = tardy.results;
const pool = tardy.core.pool;
const AsyncIO = tardy.AsyncIO;
const Job = @import("../job.zig").Job;
const syscall = @import("syscall.zig");

const log = std.log.scoped(.@"tardy/aio/epoll");

pub const Errors = struct {
    pub const Timer = syscall.TimerFdCreateError || syscall.TimerFdSetError || Error;
    pub const Send = Error;
    pub const Recv = Error;
    pub const Accept = Error;
    pub const Connect = syscall.ConnectError || Error;
    pub const QueueJob = Timer || Send || Recv || Accept || Connect;
};
pub const Error = syscall.EpollCtlError || pool.Error;

pub const AsyncEpoll = struct {
    epoll_fd: posix.fd_t,
    wake_event_fd: posix.fd_t,
    events: []linux.epoll_event,

    jobs: pool.Pool(Job),

    pub fn init(allocator: mem.Allocator, options: AsyncIO.Options) !AsyncEpoll {
        const size = options.size_tasks_initial + 1;
        const epoll_fd = try syscall.epoll_create1(0);
        assert(epoll_fd > -1);
        errdefer syscall.close(epoll_fd);

        const wake_event_fd: posix.fd_t = try syscall.eventfd(0, linux.EFD.CLOEXEC);
        errdefer syscall.close(wake_event_fd);

        const events = try allocator.alloc(linux.epoll_event, options.size_aio_reap_max);
        errdefer allocator.free(events);

        var jobs: pool.Pool(Job) = try .init(allocator, size, options.pooling);
        errdefer jobs.deinit();

        // Queue the wake task.
        const index = jobs.borrow_assume_unset(0);
        const item = jobs.get_ptr(index);
        item.* = .{
            .index = index,
            .type = .wake,
            .task = @bitCast(@as(isize, -1)),
        };

        var event: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .u64 = index },
        };

        try syscall.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, wake_event_fd, &event);

        return .{
            .epoll_fd = epoll_fd,
            .wake_event_fd = wake_event_fd,
            .events = events,
            .jobs = jobs,
        };
    }

    pub fn inner_deinit(self: *AsyncEpoll, allocator: mem.Allocator) void {
        syscall.close(self.epoll_fd);
        allocator.free(self.events);
        self.jobs.deinit();
        syscall.close(self.wake_event_fd);
    }

    fn deinit(runner: *anyopaque, allocator: mem.Allocator) void {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(runner));
        epoll.inner_deinit(allocator);
    }

    pub fn queue_job(
        runner: *anyopaque,
        task: usize,
        job: AsyncIO.Submission,
    ) Errors.QueueJob!void {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(runner));

        try switch (job) {
            .timer => |inner| queue_timer(epoll, task, inner),
            .accept => |inner| queue_accept(epoll, task, inner.socket, inner.kind),
            .connect => |inner| queue_connect(epoll, task, inner.socket, inner.addr, inner.kind),
            .recv => |inner| queue_recv(epoll, task, inner.socket, inner.buffer),
            .send => |inner| queue_send(epoll, task, inner.socket, inner.buffer),
            .open, .delete, .mkdir, .stat, .read, .write, .close => unreachable,
        };
    }

    fn queue_timer(self: *AsyncEpoll, task: usize, duration: Io.Duration) Errors.Timer!void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);

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

        try syscall.timerfd_settime(timer_fd, .{}, &ktimerspec, null);
        item.* = .{
            .index = index,
            .type = .{ .timer = .{ .fd = timer_fd } },
            .task = task,
        };

        var event: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .u64 = index },
        };

        try self.add_fd(timer_fd, &event);
    }

    fn queue_accept(
        self: *AsyncEpoll,
        task: usize,
        socket: Socket.Handle,
        kind: Socket.Kind,
    ) Errors.Accept!void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);
        item.* = .{
            .index = index,
            .type = .{
                .accept = .{
                    .socket = socket,
                    .kind = kind,
                    .addr = .wildcard,
                },
            },
            .task = task,
        };

        var event: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .u64 = index },
        };

        try self.add_or_mod_fd(socket, &event);
    }

    fn queue_connect(
        self: *AsyncEpoll,
        task: usize,
        socket: Socket.Handle,
        // TODO: take *const
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

        syscall.connect(
            socket,
            &addr,
        ) catch |e| switch (e) {
            error.WouldBlock => {},
            else => |err| return err,
        };

        var event: linux.epoll_event = .{
            .events = linux.EPOLL.OUT,
            .data = .{ .u64 = index },
        };

        try self.add_or_mod_fd(socket, &event);
    }

    fn queue_recv(self: *AsyncEpoll, task: usize, socket: Socket.Handle, buffer: []u8) Errors.Recv!void {
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

        var event: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .u64 = index },
        };

        try self.add_or_mod_fd(socket, &event);
    }

    fn queue_send(self: *AsyncEpoll, task: usize, socket: Socket.Handle, buffer: []const u8) Errors.Send!void {
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

        var event: linux.epoll_event = .{
            .events = linux.EPOLL.OUT,
            .data = .{ .u64 = index },
        };

        try self.add_or_mod_fd(socket, &event);
    }

    fn add_or_mod_fd(self: *AsyncEpoll, fd: posix.fd_t, event: *linux.epoll_event) syscall.EpollCtlError!void {
        self.add_fd(fd, event) catch |e| switch (e) {
            error.FileDescriptorAlreadyPresentInSet => {
                try self.mod_fd(fd, event);
            },
            else => |err| return err,
        };
    }

    fn add_fd(self: *AsyncEpoll, fd: posix.fd_t, event: *linux.epoll_event) syscall.EpollCtlError!void {
        try syscall.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, event);
    }

    fn mod_fd(self: *AsyncEpoll, fd: posix.fd_t, event: *linux.epoll_event) syscall.EpollCtlError!void {
        try syscall.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, fd, event);
    }

    fn remove_fd(self: *AsyncEpoll, fd: posix.fd_t) syscall.EpollCtlError!void {
        try syscall.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
    }

    pub fn wake(runner: *anyopaque) syscall.WriteError!void {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(runner));

        const bytes: []const u8 = "00000000";
        var i: usize = 0;
        while (i < bytes.len) {
            i += try syscall.write(epoll.wake_event_fd, bytes[i..]);
        }
    }

    pub fn submit(_: *anyopaque) !void {}

    pub fn reap(
        runner: *anyopaque,
        completions: []results.Completion,
        wait: bool,
    ) ![]results.Completion {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(runner));
        var reaped: usize = 0;

        while (reaped == 0 and wait) {
            const remaining = completions.len - reaped;
            if (remaining == 0) break;

            const timeout: i32 = if (!wait) 0 else -1;
            // Handle all of the epoll I/O
            const epoll_events = syscall.epoll_wait(epoll.epoll_fd, epoll.events[0..remaining], timeout);
            for (epoll.events[0..epoll_events]) |event| {
                const job_index: usize = @intCast(event.data.u64);
                assert(epoll.jobs.dirty.isSet(job_index));

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
                            _ = syscall.read(epoll.wake_event_fd, buffer[0..]) catch |e| {
                                log.err("wake failed: {}", .{e});
                                unreachable;
                            };

                            break :blk .wake;
                        },
                        .timer => |inner| {
                            const timer_fd = inner.fd;
                            defer epoll.remove_fd(timer_fd) catch unreachable;
                            assert(event.events & linux.EPOLL.IN != 0);

                            var buffer: [8]u8 = undefined;
                            // Should NEVER fail.
                            _ = syscall.read(timer_fd, buffer[0..]) catch |e| {
                                log.debug("timer failed: {}", .{e});
                                unreachable;
                            };

                            break :blk .none;
                        },
                        .accept => |*inner| {
                            assert(event.events & linux.EPOLL.IN != 0);

                            const result: results.AcceptResult = result: {
                                const handle = syscall.accept(
                                    inner.socket,
                                    &inner.addr,
                                    0,
                                ) catch |e| {
                                    const err = switch (e) {
                                        error.WouldBlock => {
                                            job_complete = false;
                                            continue;
                                        },
                                        else => results.AcceptError.Unexpected,
                                    };

                                    break :result .{ .err = err };
                                };

                                break :result .{ .actual = .{
                                    .handle = handle,
                                    .addr = inner.addr,
                                    .kind = inner.kind,
                                } };
                            };

                            break :blk .{ .accept = result };
                        },
                        .connect => {
                            assert(event.events & linux.EPOLL.OUT != 0);

                            const result: results.ConnectResult = result: {
                                if (event.events & linux.EPOLL.ERR != 0) {
                                    break :result .{
                                        .err = results.ConnectError.Unexpected,
                                    };
                                } else {
                                    break :result .actual;
                                }
                            };

                            break :blk .{ .connect = result };
                        },
                        .recv => |inner| {
                            assert(event.events & linux.EPOLL.IN != 0);

                            const result: results.RecvResult = result: {
                                const length = syscall.recv(
                                    inner.socket,
                                    inner.buffer,
                                    0,
                                ) catch |e| {
                                    const err = switch (e) {
                                        error.WouldBlock => {
                                            job_complete = false;
                                            continue;
                                        },
                                        else => |err| err,
                                    };

                                    break :result .{ .err = err };
                                };

                                if (length == 0) break :result .{ .err = results.RecvError.Closed };
                                break :result .{ .actual = length };
                            };

                            break :blk .{ .recv = result };
                        },
                        .send => |inner| {
                            assert(event.events & linux.EPOLL.OUT != 0);

                            const result: results.SendResult = result: {
                                const length = syscall.send(
                                    inner.socket,
                                    inner.buffer,
                                    0,
                                ) catch |e| {
                                    const err = switch (e) {
                                        error.WouldBlock => {
                                            job_complete = false;
                                            continue;
                                        },
                                        else => |err| err,
                                    };

                                    break :result .{ .err = err };
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
                    .task = job.task,
                };
                reaped += 1;
            }
        }

        return completions[0..reaped];
    }

    pub fn to_async(self: *AsyncEpoll) AsyncIO {
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
