pub const Poll = @This();

wake_pipe: [2]fs.File.Handle,
fd_list: std.ArrayList(syscall.pollfd),
fd_job_map: array_hash_map.Auto(fs.File.Handle, Job),

timers: TimerQueue,

pub fn init(gpa: mem.Allocator, options: AsyncIO.Options) !Poll {
    const size = options.initial_task_size + 1;

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

            syscall.connect(write_end, &addr) catch |err| {
                switch (err) {
                    error.WouldBlock => {},
                    else => |e| return e,
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

    var fd_list: std.ArrayList(syscall.pollfd) = try .initCapacity(gpa, size);
    errdefer fd_list.deinit(gpa);

    var fd_job_map: array_hash_map.Auto(fs.File.Handle, Job) = .empty;
    errdefer fd_job_map.deinit(gpa);

    try fd_job_map.ensureTotalCapacity(gpa, size);

    if (comptime native_os == .windows) {
        try fd_list.append(gpa, .{
            .fd = @ptrCast(pipe[0]),
            .events = syscall.POLL.IN,
            .revents = 0,
        });
        try fd_job_map.put(gpa, @ptrCast(pipe[0]), .{
            .job_index = 0,
            .type = .wake,
            .task_index = 0,
        });
    } else {
        try fd_list.append(gpa, .{
            .fd = pipe[0],
            .events = syscall.POLL.IN,
            .revents = 0,
        });
        try fd_job_map.put(gpa, pipe[0], .{
            .job_index = 0,
            .type = .wake,
            .task_index = 0,
        });
    }

    const timers: TimerQueue = .empty;
    errdefer timers.deinit(gpa);

    return .{
        .wake_pipe = pipe,
        .fd_list = fd_list,
        .fd_job_map = fd_job_map,
        .timers = timers,
    };
}

pub fn inner_deinit(poll: *Poll, gpa: mem.Allocator) void {
    poll.fd_list.deinit(gpa);
    poll.fd_job_map.deinit(gpa);
    poll.timers.deinit(gpa);

    for (poll.wake_pipe) |fd| if (comptime native_os == .windows)
        syscall.ws2.closesock(fd) catch unreachable
    else
        syscall.close(fd);
}

fn deinit(runner: *anyopaque, gpa: mem.Allocator) void {
    const poll: *Poll = @ptrCast(@alignCast(runner));
    poll.inner_deinit(gpa);
}

pub fn queue_job(
    runner: *anyopaque,
    gpa: mem.Allocator,
    task_index: usize,
    job: AsyncIO.Submission,
) Errors.QueueJob!void {
    const poll: *Poll = @ptrCast(@alignCast(runner));

    try switch (job) {
        .timer => |timer| poll.queue_timer(
            gpa,
            task_index,
            timer,
        ),
        .accept => |accept| poll.queue_accept(
            gpa,
            task_index,
            accept.socket,
        ),
        .connect => |connect| poll.queue_connect(
            gpa,
            task_index,
            connect.socket,
        ),
        .recv => |recv| poll.queue_recv(
            gpa,
            task_index,
            recv.socket,
            recv.buffer,
        ),
        .send => |send| poll.queue_send(
            gpa,
            task_index,
            send.socket,
            send.buffer,
        ),
        .open, .delete, .mkdir, .stat, .read, .write, .close => unreachable,
    };
}

fn queue_timer(
    poll: *Poll,
    gpa: mem.Allocator,
    task_index: usize,
    duration: Io.Duration,
) Errors.Timer!void {
    const current = syscall.now(.real);
    try poll.timers.push(gpa, .{
        .duration = current.addDuration(duration),
        .task_index = task_index,
    });
}

fn queue_accept(
    poll: *Poll,
    gpa: mem.Allocator,
    task_index: usize,
    socket: *const net.Socket,
) Errors.Accept!void {
    try poll.fd_list.append(gpa, .{
        .fd = socket.handle,
        .events = syscall.POLL.IN,
        .revents = 0,
    });
    try poll.fd_job_map.put(gpa, socket.handle, .{
        .job_index = 0,
        .type = .{
            .accept = .{
                .socket = .{
                    .handle = socket.handle,
                    .kind = socket.kind,
                    .addr = .init(socket.addr.family()),
                },
            },
        },
        .task_index = task_index,
    });
}

fn queue_connect(
    poll: *Poll,
    gpa: mem.Allocator,
    task_index: usize,
    socket: *const net.Socket,
) Errors.Connect!void {
    syscall.connect(
        socket.handle,
        &socket.addr,
    ) catch |err| switch (err) {
        error.WouldBlock => {},
        else => |e| return e,
    };

    try poll.fd_list.append(gpa, .{
        .fd = socket.handle,
        .events = syscall.POLL.OUT,
        .revents = 0,
    });
    try poll.fd_job_map.put(gpa, socket.handle, .{
        .job_index = 0,
        .type = .{
            .connect = .{
                .socket = socket,
            },
        },
        .task_index = task_index,
    });
}

fn queue_recv(
    poll: *Poll,
    gpa: mem.Allocator,
    task_index: usize,
    socket: net.Socket.Handle,
    buffer: []u8,
) Errors.Recv!void {
    try poll.fd_list.append(gpa, .{
        .fd = socket,
        .events = syscall.POLL.IN,
        .revents = 0,
    });
    try poll.fd_job_map.put(gpa, socket, .{
        .job_index = 0,
        .type = .{
            .recv = .{
                .socket = socket,
                .buffer = buffer,
            },
        },
        .task_index = task_index,
    });
}

fn queue_send(
    poll: *Poll,
    gpa: mem.Allocator,
    task_index: usize,
    socket: net.Socket.Handle,
    buffer: []const u8,
) Errors.Send!void {
    try poll.fd_list.append(gpa, .{
        .fd = socket,
        .events = syscall.POLL.OUT,
        .revents = 0,
    });
    try poll.fd_job_map.put(gpa, socket, .{
        .job_index = 0,
        .type = .{
            .send = .{
                .socket = socket,
                .buffer = buffer,
            },
        },
        .task_index = task_index,
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
                .task_index = timer.task_index,
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
            const job_index = i - 1;
            if (reaped >= completions.len) break;
            if (ready == 0) break;

            const pfd = poll.fd_list.items[job_index];
            log.debug("revents={x}", .{pfd.revents});
            if (pfd.revents == 0) continue;
            const job = poll.fd_job_map.getPtr(pfd.fd).?;

            var remove: bool = true;
            defer if (remove) {
                _ = poll.fd_list.swapRemove(job_index);
                _ = poll.fd_job_map.swapRemove(pfd.fd);
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

                        const client_fd = syscall.accept(
                            accept.socket.handle,
                            &accept.socket.addr,
                            if (native_os != .windows)
                                posix.SOCK.NONBLOCK
                            else
                                0,
                        ) catch |err| {
                            const e = switch (err) {
                                error.WouldBlock => {
                                    log.debug(
                                        "accept wouldblock - not removing",
                                        .{},
                                    );
                                    remove = false;
                                    continue;
                                },
                                error.ConnectionAborted,
                                error.ProcessFdQuotaExceeded,
                                error.SystemFdQuotaExceeded,
                                => |e| e,
                                error.SocketNotListening => error.NotListening,
                                else => error.Unexpected,
                            };

                            break :result .{ .accept = .{
                                .err = e,
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
                                .err = error.Unexpected,
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
                                .err = error.Closed,
                            },
                        };

                        debug.assert(pfd.revents & syscall.POLL.IN != 0 or
                            pfd.revents & syscall.POLL.RDNORM != 0);

                        const count = syscall.recv(
                            recv.socket,
                            recv.buffer,
                            0,
                        ) catch |err| {
                            const e = switch (err) {
                                error.WouldBlock => {
                                    log.debug(
                                        "recv wouldblock - not removing",
                                        .{},
                                    );
                                    remove = false;
                                    continue;
                                },
                                error.ConnectionResetByPeer => error.Closed,
                                else => error.Unexpected,
                            };

                            break :result .{ .recv = .{
                                .err = e,
                            } };
                        };

                        if (count == 0) break :result .{
                            .recv = .{
                                .err = error.Closed,
                            },
                        };
                        break :result .{ .recv = .{
                            .actual = count,
                        } };
                    },
                    .send => |send| {
                        if (pfd.revents & syscall.POLL.HUP != 0) break :result .{
                            .send = .{
                                .err = error.Closed,
                            },
                        };

                        debug.assert(pfd.revents & syscall.POLL.OUT != 0);

                        const count = syscall.send(
                            send.socket,
                            send.buffer,
                            0,
                        ) catch |err| {
                            log.err("send failed with {}", .{err});
                            const e = switch (err) {
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
                                => error.Closed,
                                else => error.Unexpected,
                            };

                            break :result .{ .send = .{
                                .err = e,
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
                .task_index = job.task_index,
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
    pub const Connect = syscall.Errors.Connect || OoM;
    pub const Timer = OoM;
    pub const Accept = OoM;
    pub const Recv = OoM;
    pub const Send = OoM;
    pub const Wake = syscall.Errors.Write;
    pub const QueueJob = Connect || Wake || Timer || Accept || Recv || Send;
};
const TimerPair = struct {
    duration: Io.Timestamp,
    task_index: usize,
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
const array_hash_map = std.array_hash_map;
const mem = std.mem;
const OoM = mem.Allocator.Error;
const builtin = @import("builtin");
const native_os = builtin.os.tag;

const tardy = @import("../root.zig");
const fs = tardy.fs;
const net = tardy.net;
const AsyncIO = tardy.AsyncIO;
const results = tardy.results;
const Job = @import("job.zig").Job;
const syscall = @import("syscall.zig");
