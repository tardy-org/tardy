pub const Poll = @This();

wake_pipe: [2]fs.File.Handle,
fd_list: std.ArrayList(syscall.pollfd),
// TODO: audit all uses of `AutoHashMap` if they can be replaced
// by array variant
fd_job_map: std.AutoHashMapUnmanaged(fs.File.Handle, Job),

timers: TimerQueue,

pub fn init(allocator: mem.Allocator, options: AsyncIO.Options) !Poll {
    const size = options.size_tasks_initial + 1;

    // 0 is read, 1 is write.
    const pipe: [2]fs.File.Handle = blk: {
        if (comptime native_os == .windows) {
            const server = try syscall.socket(
                posix.AF.INET,
                posix.SOCK.STREAM,
                posix.IPPROTO.IP,
            );
            defer syscall.close(server);

            var addr: net.Socket.Address = .localhost;
            try syscall.bind(server, &addr);
            try syscall.listen(server, 1);

            // Required to prevent INVALID_ADDRESS_COMPONENT error on AFD
            try syscall.getsockname(
                server,
                &addr.any,
                &addr.len,
            );

            const write_end = try syscall.socket(
                posix.AF.INET,
                posix.SOCK.STREAM,
                posix.IPPROTO.IP,
            );
            errdefer syscall.close(write_end);

            syscall.connect(write_end, &addr) catch |e| {
                switch (e) {
                    error.WouldBlock => {},
                    else => |err| return err,
                }
            };

            const read_end = try syscall.accept(
                server,
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

    var fd_job_map: std.AutoHashMapUnmanaged(fs.File.Handle, Job) = .empty;
    errdefer fd_job_map.deinit(allocator);

    try fd_job_map.ensureTotalCapacity(allocator, @intCast(size));

    if (comptime native_os == .windows) {
        try fd_list.append(allocator, .{
            .fd = @ptrCast(pipe[0]),
            .events = syscall.POLL.IN,
            .revents = 0,
        });
        try fd_job_map.put(allocator, @ptrCast(pipe[0]), .{
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
        try fd_job_map.put(allocator, pipe[0], .{
            .index = 0,
            .type = .wake,
            .task = 0,
        });
    }

    const timers: TimerQueue = .empty;
    errdefer timers.deinit(allocator);

    return .{
        .wake_pipe = pipe,
        .fd_list = fd_list,
        .fd_job_map = fd_job_map,
        .timers = timers,
    };
}

pub fn inner_deinit(poll: *Poll, allocator: mem.Allocator) void {
    poll.fd_list.deinit(allocator);
    poll.fd_job_map.deinit(allocator);
    poll.timers.deinit(allocator);
    for (poll.wake_pipe) |fd| if (comptime native_os == .windows)
        syscall.ws2.closesock(fd) catch unreachable
    else
        syscall.close(fd);
}

fn deinit(runner: *anyopaque, allocator: mem.Allocator) void {
    const poll: *Poll = @ptrCast(@alignCast(runner));
    poll.inner_deinit(allocator);
}

pub fn queue_job(
    runner: *anyopaque,
    allocator: mem.Allocator,
    task: usize,
    job: AsyncIO.Submission,
) Errors.QueueJob!void {
    const poll: *Poll = @ptrCast(@alignCast(runner));

    try switch (job) {
        .timer => |timer| poll.queue_timer(
            allocator,
            task,
            timer,
        ),
        .accept => |accept| poll.queue_accept(
            allocator,
            task,
            accept.socket,
        ),
        .connect => |connect| poll.queue_connect(
            allocator,
            task,
            connect.socket,
        ),
        .recv => |recv| poll.queue_recv(
            allocator,
            task,
            recv.socket,
            recv.buffer,
        ),
        .send => |send| poll.queue_send(
            allocator,
            task,
            send.socket,
            send.buffer,
        ),
        .open, .delete, .mkdir, .stat, .read, .write, .close => unreachable,
    };
}

fn queue_timer(
    poll: *Poll,
    allocator: mem.Allocator,
    task: usize,
    duration: Io.Duration,
) Errors.Timer!void {
    const current = syscall.now(.real);
    try poll.timers.push(allocator, .{
        .duration = current.addDuration(duration),
        .task = task,
    });
}

fn queue_accept(
    poll: *Poll,
    allocator: mem.Allocator,
    task: usize,
    socket: *const net.Socket,
) Errors.Accept!void {
    try poll.fd_list.append(allocator, .{
        .fd = socket.handle,
        .events = syscall.POLL.IN,
        .revents = 0,
    });
    try poll.fd_job_map.put(allocator, socket.handle, .{
        .index = 0,
        .type = .{
            .accept = .{
                .socket = .{
                    .handle = socket.handle,
                    .kind = socket.kind,
                    .addr = .init(socket.addr.family()),
                },
            },
        },
        .task = task,
    });
}

fn queue_connect(
    poll: *Poll,
    allocator: mem.Allocator,
    task: usize,
    socket: *const net.Socket,
) Errors.Connect!void {
    syscall.connect(
        socket.handle,
        &socket.addr,
    ) catch |e| switch (e) {
        error.WouldBlock => {},
        else => |err| return err,
    };

    try poll.fd_list.append(allocator, .{
        .fd = socket.handle,
        .events = syscall.POLL.OUT,
        .revents = 0,
    });
    try poll.fd_job_map.put(allocator, socket.handle, .{
        .index = 0,
        .type = .{
            .connect = .{
                .socket = socket,
            },
        },
        .task = task,
    });
}

fn queue_recv(
    poll: *Poll,
    allocator: mem.Allocator,
    task: usize,
    socket: net.Socket.Handle,
    buffer: []u8,
) Errors.Recv!void {
    try poll.fd_list.append(allocator, .{
        .fd = socket,
        .events = syscall.POLL.IN,
        .revents = 0,
    });
    try poll.fd_job_map.put(allocator, socket, .{
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
    poll: *Poll,
    allocator: mem.Allocator,
    task: usize,
    socket: net.Socket.Handle,
    buffer: []const u8,
) Errors.Send!void {
    try poll.fd_list.append(allocator, .{
        .fd = socket,
        .events = syscall.POLL.OUT,
        .revents = 0,
    });
    try poll.fd_job_map.put(allocator, socket, .{
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
    _: mem.Allocator,
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
        if (poll.timers.peek()) |peeked| timeout = @intCast(
            peeked.duration.nanoseconds - current.nanoseconds,
        );

        log.debug("timeout = {d}", .{timeout});
        const poll_result = try syscall.poll(
            poll.fd_list.items,
            @intCast(@divFloor(timeout, std.time.ns_per_ms)),
        );

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
                        debug.assert(pfd.revents & syscall.POLL.IN != 0 or
                            pfd.revents & syscall.POLL.RDNORM != 0);

                        var buf: [8]u8 = undefined;
                        _ = syscall.read(
                            poll.wake_pipe[0],
                            &buf,
                        ) catch unreachable;
                        remove = false;
                        break :result .wake;
                    },
                    .accept => |*accept| {
                        debug.assert(pfd.revents & syscall.POLL.IN != 0 or
                            pfd.revents & syscall.POLL.RDNORM != 0);

                        const AcceptError = results.AcceptError;
                        const client_fd = syscall.accept(
                            accept.socket.handle,
                            &accept.socket.addr,
                            if (native_os != .windows)
                                posix.SOCK.NONBLOCK
                            else
                                0,
                        ) catch |e| {
                            const err = switch (e) {
                                error.WouldBlock => {
                                    log.debug(
                                        "accept wouldblock - not removing",
                                        .{},
                                    );
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

                            break :result .{ .accept = .{
                                .err = err,
                            } };
                        };

                        break :result .{
                            .accept = .{
                                .actual = .{
                                    .handle = client_fd,
                                    .addr = accept.socket.addr,
                                    .kind = accept.socket.kind,
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
                            break :result .{
                                .connect = .actual,
                            };
                        }
                    },
                    .recv => |recv| {
                        if (pfd.revents & syscall.POLL.HUP != 0) break :result .{
                            .recv = .{
                                .err = results.RecvError.Closed,
                            },
                        };

                        debug.assert(pfd.revents & syscall.POLL.IN != 0 or
                            pfd.revents & syscall.POLL.RDNORM != 0);

                        const RecvError = results.RecvError;
                        const count = syscall.recv(
                            recv.socket,
                            recv.buffer,
                            0,
                        ) catch |e| {
                            const err = switch (e) {
                                error.WouldBlock => {
                                    log.debug(
                                        "recv wouldblock - not removing",
                                        .{},
                                    );
                                    remove = false;
                                    continue;
                                },
                                error.ConnectionResetByPeer => RecvError.Closed,
                                else => RecvError.Unexpected,
                            };

                            break :result .{ .recv = .{
                                .err = err,
                            } };
                        };

                        if (count == 0) break :result .{
                            .recv = .{
                                .err = RecvError.Closed,
                            },
                        };
                        break :result .{ .recv = .{
                            .actual = count,
                        } };
                    },
                    .send => |send| {
                        const SendError = results.SendError;
                        if (pfd.revents & syscall.POLL.HUP != 0) break :result .{
                            .send = .{
                                .err = SendError.Closed,
                            },
                        };

                        debug.assert(pfd.revents & syscall.POLL.OUT != 0);
                        const count = syscall.send(
                            send.socket,
                            send.buffer,
                            0,
                        ) catch |e| {
                            log.err("send failed with {}", .{e});
                            const err = switch (e) {
                                error.WouldBlock => {
                                    log.debug(
                                        "send wouldblock - not removing",
                                        .{},
                                    );
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

pub fn to_async(poll: *Poll) AsyncIO {
    return .{
        .runner = poll,
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

const log = std.log.scoped(.@"tardy/aio/Poll");

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

const TimerQueue = std.PriorityQueue(
    TimerPair,
    void,
    struct {
        fn compare(_: void, a: TimerPair, b: TimerPair) math.Order {
            return math.order(a.duration.nanoseconds, b.duration.nanoseconds);
        }
    }.compare,
);

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
