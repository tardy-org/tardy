pub const Poll = @This();

allocator: mem.Allocator,
wake_pipe: [2]fs.File.Handle,

fd_list: std.ArrayList(syscall.pollfd),
fd_job_map: std.AutoHashMap(fs.File.Handle, Job),

timers: TimerQueue,

pub fn init(allocator: mem.Allocator, options: AsyncIO.Options) !Poll {
    const size = options.size_tasks_initial + 1;

    // 0 is read, 1 is write.
    const pipe: [2]fs.File.Handle = blk: {
        if (comptime native_os == .windows) {
            syscall.ws2.wsaStartup(2, 2) catch unreachable;

            const server_socket = try syscall.socket(
                posix.AF.INET,
                posix.SOCK.STREAM,
                0,
            );
            defer syscall.close(server_socket);

            const addr: net.Socket.Address = .{
                .ip = .{ .ip4 = .loopback(0) },
            };
            try syscall.bind(server_socket, &addr);

            try syscall.listen(server_socket, 1);

            const write_end = try syscall.socket(
                posix.AF.INET,
                posix.SOCK.STREAM,
                0,
            );
            errdefer syscall.close(write_end);

            // Required to prevent INVALID_ADDRESS_COMPONENT error on AFD
            var binded_addr = mem.zeroes(std.posix.sockaddr);
            var binded_size: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
            try syscall.getsockname(server_socket, &binded_addr, &binded_size);
            const bounded_addr = net.Socket.Address.fromAny(&binded_addr);

            try syscall.connect(write_end, &bounded_addr);

            const read_end = try syscall.accept(
                server_socket,
                null,
                0,
            );
            errdefer syscall.close(read_end);

            break :blk .{ read_end, write_end };
        } else break :blk try syscall.pipe();
    };
    errdefer for (pipe) |fd| syscall.close(fd);

    var fd_list: std.ArrayList(syscall.pollfd) = try .initCapacity(
        allocator,
        size,
    );
    errdefer fd_list.deinit(allocator);

    var fd_job_map: std.AutoHashMap(fs.File.Handle, Job) = .init(allocator);
    errdefer fd_job_map.deinit();
    try fd_job_map.ensureTotalCapacity(@intCast(size));

    if (comptime native_os == .windows) {
        try fd_list.append(allocator, .{
            .fd = @ptrCast(pipe[0]),
            .events = syscall.POLL.IN,
            .revents = 0,
        });
        try fd_job_map.put(@ptrCast(pipe[0]), .{
            .index = 0,
            .type = .wake,
            .task = 0,
        });
    } else {
        try fd_list.append(allocator, .{
            .fd = pipe[0],
            .events = syscall.POLL.IN,
            .revents = 0,
        });
        try fd_job_map.put(pipe[0], .{
            .index = 0,
            .type = .wake,
            .task = 0,
        });
    }

    const timers: TimerQueue = .empty;
    errdefer timers.deinit(allocator);

    return .{
        .allocator = allocator,
        .wake_pipe = pipe,
        .fd_list = fd_list,
        .fd_job_map = fd_job_map,
        .timers = timers,
    };
}

pub fn inner_deinit(self: *Poll, allocator: mem.Allocator) void {
    defer if (comptime native_os == .windows) syscall.ws2.wsaCleanup() catch unreachable;

    self.fd_list.deinit(allocator);
    self.fd_job_map.deinit();
    self.timers.deinit(allocator);
    for (self.wake_pipe) |fd| if (comptime native_os == .windows) (syscall.ws2.closesock(fd) catch unreachable) else syscall.close(fd);
}

fn deinit(runner: *anyopaque, allocator: mem.Allocator) void {
    const poll: *Poll = @ptrCast(@alignCast(runner));
    poll.inner_deinit(allocator);
}

pub fn queue_job(runner: *anyopaque, task: usize, job: AsyncIO.Submission) Errors.QueueJob!void {
    const poll: *Poll = @ptrCast(@alignCast(runner));

    try switch (job) {
        .timer => |inner| queue_timer(poll, task, inner),
        .accept => |inner| queue_accept(poll, task, inner.socket, inner.kind),
        .connect => |inner| queue_connect(poll, task, inner.socket, inner.addr, inner.kind),
        .recv => |inner| queue_recv(poll, task, inner.socket, inner.buffer),
        .send => |inner| queue_send(poll, task, inner.socket, inner.buffer),
        .open, .delete, .mkdir, .stat, .read, .write, .close => unreachable,
    };
}

fn queue_timer(self: *Poll, task: usize, duration: Io.Duration) Errors.Timer!void {
    const current = syscall.now(.real);
    try self.timers.push(self.allocator, .{
        .duration = current.addDuration(duration),
        .task = task,
    });
}

fn queue_accept(
    self: *Poll,
    task: usize,
    socket: net.Socket.Handle,
    kind: net.Socket.Kind,
) Errors.Accept!void {
    try self.fd_list.append(self.allocator, .{
        .fd = socket,
        .events = syscall.POLL.IN,
        .revents = 0,
    });
    try self.fd_job_map.put(socket, .{
        .index = 0,
        .type = .{
            .accept = .{
                .socket = socket,
                .kind = kind,
                .addr = .wildcard,
            },
        },
        .task = task,
    });
}

fn queue_connect(
    self: *Poll,
    task: usize,
    socket: net.Socket.Handle,
    // TODO: take by *const
    addr: net.Socket.Address,
    kind: net.Socket.Kind,
) Errors.Connect!void {
    syscall.connect(
        socket,
        &addr,
    ) catch |e| switch (e) {
        error.WouldBlock => {},
        else => |err| return err,
    };

    try self.fd_list.append(self.allocator, .{
        .fd = socket,
        .events = syscall.POLL.OUT,
        .revents = 0,
    });
    try self.fd_job_map.put(socket, .{
        .index = 0,
        .type = .{
            .connect = .{
                .socket = socket,
                .addr = addr,
                .kind = kind,
            },
        },
        .task = task,
    });
}

fn queue_recv(
    self: *Poll,
    task: usize,
    socket: net.Socket.Handle,
    buffer: []u8,
) Errors.Recv!void {
    try self.fd_list.append(self.allocator, .{
        .fd = socket,
        .events = syscall.POLL.IN,
        .revents = 0,
    });
    try self.fd_job_map.put(socket, .{
        .index = 0,
        .type = .{
            .recv = .{
                .socket = socket,
                .buffer = buffer,
            },
        },
        .task = task,
    });
}

fn queue_send(
    self: *Poll,
    task: usize,
    socket: net.Socket.Handle,
    buffer: []const u8,
) Errors.Send!void {
    try self.fd_list.append(self.allocator, .{
        .fd = socket,
        .events = syscall.POLL.OUT,
        .revents = 0,
    });
    try self.fd_job_map.put(socket, .{
        .index = 0,
        .type = .{
            .send = .{
                .socket = socket,
                .buffer = buffer,
            },
        },
        .task = task,
    });
}

pub fn wake(runner: *anyopaque) Errors.Wake!void {
    const poll: *Poll = @ptrCast(@alignCast(runner));

    const bytes: []const u8 = "00000000";
    var i: usize = 0;
    while (i < bytes.len) i += try syscall.write(
        poll.wake_pipe[1],
        bytes[i..],
    );
}

pub fn submit(_: *anyopaque) !void {}

pub fn reap(
    runner: *anyopaque,
    completions: []results.Completion,
    wait: bool,
) ![]results.Completion {
    const poll: *Poll = @ptrCast(@alignCast(runner));
    var reaped: usize = 0;

    poll_loop: while (reaped == 0 and wait) {
        const current = syscall.now(.real);

        // Reap all completed Timers
        while (poll.timers.peek()) |peeked| {
            if (peeked.duration.nanoseconds > current.nanoseconds) break;
            if (completions.len - reaped == 0) break;

            const timer = poll.timers.pop().?;
            completions[reaped] = .{
                .result = .none,
                .task = timer.task,
            };
            reaped += 1;
        }

        var timeout: i96 = if (!wait or reaped > 0) 0 else -1;

        // Select next Timer
        if (poll.timers.peek()) |peeked| timeout = @intCast(peeked.duration.nanoseconds - current.nanoseconds);

        log.debug("timeout = {d}", .{timeout});
        const poll_result = try syscall.poll(poll.fd_list.items, @intCast(@divFloor(timeout, std.time.ns_per_ms)));

        if (poll_result == 0 and timeout > 0) continue :poll_loop;

        var ready = poll_result;
        var i = poll.fd_list.items.len;
        while (i > 0) : (i -= 1) {
            const index = i - 1;
            if (reaped >= completions.len) break;
            if (ready == 0) break;

            const pfd = poll.fd_list.items[index];
            log.debug("revents={x}", .{pfd.revents});
            if (pfd.revents == 0) continue;
            const job = poll.fd_job_map.getPtr(pfd.fd).?;

            var remove: bool = true;
            defer if (remove) {
                _ = poll.fd_list.swapRemove(index);
                _ = poll.fd_job_map.remove(pfd.fd);
                ready -= 1;
            };

            const result: results.Result = result: {
                switch (job.type) {
                    .wake => {
                        debug.assert(pfd.revents & syscall.POLL.IN != 0 or pfd.revents & syscall.POLL.RDNORM != 0);

                        var buf: [8]u8 = undefined;
                        _ = syscall.read(poll.wake_pipe[0], &buf) catch unreachable;
                        remove = false;
                        break :result .wake;
                    },
                    .accept => |*inner| {
                        debug.assert(pfd.revents & syscall.POLL.IN != 0 or pfd.revents & syscall.POLL.RDNORM != 0);

                        const AcceptError = results.AcceptError;
                        const socket = syscall.accept(
                            inner.socket,
                            &inner.addr,
                            if (native_os != .windows) posix.SOCK.NONBLOCK else 0,
                        ) catch |e| {
                            const err = switch (e) {
                                error.WouldBlock => {
                                    log.debug("accept wouldblock - not removing", .{});
                                    remove = false;
                                    continue;
                                },
                                error.ConnectionAborted,
                                => AcceptError.ConnectionAborted,
                                error.SocketNotListening => AcceptError.NotListening,
                                error.ProcessFdQuotaExceeded => AcceptError.ProcessFdQuotaExceeded,
                                error.SystemFdQuotaExceeded => AcceptError.SystemFdQuotaExceeded,
                                else => AcceptError.Unexpected,
                            };

                            break :result .{ .accept = .{ .err = err } };
                        };

                        break :result .{
                            .accept = .{
                                .actual = .{
                                    .handle = socket,
                                    .addr = inner.addr,
                                    .kind = inner.kind,
                                },
                            },
                        };
                    },
                    .connect => {
                        debug.assert(pfd.revents & syscall.POLL.OUT != 0);

                        if (pfd.revents & syscall.POLL.ERR != 0) {
                            break :result .{ .connect = .{
                                .err = results.ConnectError.Unexpected,
                            } };
                        } else {
                            break :result .{ .connect = .actual };
                        }
                    },
                    .recv => |inner| {
                        if (pfd.revents & syscall.POLL.HUP != 0) break :result .{
                            .recv = .{
                                .err = results.RecvError.Closed,
                            },
                        };

                        debug.assert(pfd.revents & syscall.POLL.IN != 0 or
                            pfd.revents & syscall.POLL.RDNORM != 0);

                        const RecvError = results.RecvError;
                        const count = syscall.recv(
                            inner.socket,
                            inner.buffer,
                            0,
                        ) catch |e| {
                            const err = switch (e) {
                                error.WouldBlock => {
                                    log.debug("recv wouldblock - not removing", .{});
                                    remove = false;
                                    continue;
                                },
                                error.ConnectionResetByPeer => RecvError.Closed,
                                else => RecvError.Unexpected,
                            };

                            break :result .{ .recv = .{ .err = err } };
                        };

                        if (count == 0) break :result .{ .recv = .{ .err = RecvError.Closed } };
                        break :result .{ .recv = .{ .actual = count } };
                    },
                    .send => |inner| {
                        const SendError = results.SendError;
                        if (pfd.revents & syscall.POLL.HUP != 0) break :result .{
                            .send = .{
                                .err = SendError.Closed,
                            },
                        };

                        debug.assert(pfd.revents & syscall.POLL.OUT != 0);
                        const count = syscall.send(
                            inner.socket,
                            inner.buffer,
                            0,
                        ) catch |e| {
                            log.err("send failed with {}", .{e});
                            const err = switch (e) {
                                error.WouldBlock => {
                                    log.debug("send wouldblock - not removing", .{});
                                    remove = false;
                                    continue;
                                },
                                error.ConnectionResetByPeer,
                                error.BrokenPipe,
                                => SendError.Closed,
                                else => SendError.Unexpected,
                            };

                            break :result .{ .send = .{
                                .err = err,
                            } };
                        };

                        break :result .{ .send = .{
                            .actual = count,
                        } };
                    },
                    .timer,
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

pub fn to_async(self: *Poll) AsyncIO {
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

const log = std.log.scoped(.@"tardy/aio/poll");

pub const Errors = struct {
    pub const Connect = syscall.ConnectError || Error;
    pub const Timer = Error;
    pub const Accept = Error;
    pub const Recv = Error;
    pub const Send = Error;
    pub const Wake = syscall.WriteError;
    pub const QueueJob = Connect || Wake || Timer || Accept || Recv || Send;
};
const TimerPair = struct {
    duration: Io.Timestamp,
    task: usize,
};

const TimerQueue = std.PriorityQueue(TimerPair, void, struct {
    fn compare(_: void, a: TimerPair, b: TimerPair) math.Order {
        return math.order(a.duration.nanoseconds, b.duration.nanoseconds);
    }
}.compare);

const std = @import("std");
const Io = std.Io;
const debug = std.debug;
const posix = std.posix;
const math = std.math;
const mem = std.mem;
const Error = mem.Allocator.Error;
const builtin = @import("builtin");
const native_os = builtin.os.tag;

const tardy = @import("../root.zig");
const fs = tardy.fs;
const net = tardy.net;
const AsyncIO = tardy.AsyncIO;
const results = tardy.results;
const Job = @import("job.zig").Job;
const syscall = @import("syscall.zig");
