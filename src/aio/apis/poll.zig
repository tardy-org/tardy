const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const Pool = @import("../../core/pool.zig").Pool;
const Cross = @import("../../cross/lib.zig");
const Stat = @import("../../fs/lib.zig").Stat;
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

const log = std.log.scoped(.@"tardy/aio/poll");

const TimerPair = struct {
    milliseconds: usize,
    task: usize,
};

const TimerQueue = std.PriorityQueue(TimerPair, void, struct {
    fn compare(_: void, a: TimerPair, b: TimerPair) std.math.Order {
        return std.math.order(a.milliseconds, b.milliseconds);
    }
}.compare);

pub const AsyncPoll = struct {
    allocator: std.mem.Allocator,
    wake_pipe: [2]std.posix.fd_t,

    fd_list: std.ArrayList(std.posix.pollfd),
    fd_job_map: std.AutoHashMap(std.posix.fd_t, Job),
    timers: TimerQueue,

    pub fn init(allocator: std.mem.Allocator, options: AsyncOptions) !AsyncPoll {
        const size = options.size_tasks_initial + 1;

        // 0 is read, 1 is write.
        const pipe: [2]std.posix.fd_t = blk: {
            if (comptime builtin.os.tag == .windows) {
                const server_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
                defer std.posix.close(server_socket);

                const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
                try std.posix.bind(server_socket, &addr.any, addr.getOsSockLen());

                var binded_addr: std.posix.sockaddr = undefined;
                var binded_size: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
                try std.posix.getsockname(server_socket, &binded_addr, &binded_size);

                try std.posix.listen(server_socket, 1);

                const write_end = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
                errdefer std.posix.close(write_end);
                try std.posix.connect(write_end, &binded_addr, binded_size);

                const read_end = try std.posix.accept(server_socket, null, null, 0);
                errdefer std.posix.close(read_end);

                break :blk .{ read_end, write_end };
            } else break :blk try std.posix.pipe();
        };
        errdefer for (pipe) |fd| std.posix.close(fd);

        var fd_list: std.ArrayList(std.posix.pollfd) = try .initCapacity(allocator, size);
        errdefer fd_list.deinit(allocator);

        var fd_job_map: std.AutoHashMap(std.posix.fd_t, Job) = .init(allocator);
        errdefer fd_job_map.deinit();
        try fd_job_map.ensureTotalCapacity(@intCast(size));

        if (comptime builtin.os.tag == .windows) {
            try fd_list.append(allocator, .{ .fd = @ptrCast(pipe[0]), .events = std.posix.POLL.IN, .revents = 0 });
            try fd_job_map.put(@ptrCast(pipe[0]), .{ .index = 0, .type = .wake, .task = 0 });
        } else {
            try fd_list.append(allocator, .{ .fd = pipe[0], .events = std.posix.POLL.IN, .revents = 0 });
            try fd_job_map.put(pipe[0], .{ .index = 0, .type = .wake, .task = 0 });
        }

        const timers = TimerQueue.init(allocator, {});
        errdefer timers.deinit();

        return AsyncPoll{
            .allocator = allocator,
            .wake_pipe = pipe,
            .fd_list = fd_list,
            .fd_job_map = fd_job_map,
            .timers = timers,
        };
    }

    pub fn inner_deinit(self: *AsyncPoll, allocator: std.mem.Allocator) void {
        self.fd_list.deinit(allocator);
        self.fd_job_map.deinit();
        self.timers.deinit();
        for (self.wake_pipe) |fd| std.posix.close(fd);
    }

    fn deinit(runner: *anyopaque, allocator: std.mem.Allocator) void {
        const poll: *AsyncPoll = @ptrCast(@alignCast(runner));
        poll.inner_deinit(allocator);
    }

    pub fn queue_job(runner: *anyopaque, task: usize, job: AsyncSubmission) !void {
        const poll: *AsyncPoll = @ptrCast(@alignCast(runner));

        try switch (job) {
            .timer => |inner| queue_timer(poll, task, inner),
            .accept => |inner| queue_accept(poll, task, inner.socket, inner.kind),
            .connect => |inner| queue_connect(poll, task, inner.socket, inner.addr, inner.kind),
            .recv => |inner| queue_recv(poll, task, inner.socket, inner.buffer),
            .send => |inner| queue_send(poll, task, inner.socket, inner.buffer),
            .open, .delete, .mkdir, .stat, .read, .write, .close => unreachable,
        };
    }

    fn queue_timer(self: *AsyncPoll, task: usize, timespec: Timespec) !void {
        const current: usize = @intCast(std.time.milliTimestamp());
        const seconds_to_ms: usize = @intCast(timespec.seconds * 1000);
        const nanos_to_ms: usize = @intCast(@divFloor(timespec.nanos, std.time.ns_per_ms));
        const milliseconds: usize = current + seconds_to_ms + nanos_to_ms;

        try self.timers.add(.{ .milliseconds = milliseconds, .task = task });
    }

    fn queue_accept(
        self: *AsyncPoll,
        task: usize,
        socket: std.posix.socket_t,
        kind: Socket.Kind,
    ) !void {
        try self.fd_list.append(self.allocator, .{ .fd = socket, .events = std.posix.POLL.IN, .revents = 0 });
        try self.fd_job_map.put(socket, .{
            .index = 0,
            .type = .{
                .accept = .{
                    .socket = socket,
                    .kind = kind,
                    .addr = undefined,
                    .addr_len = @sizeOf(std.net.Address),
                },
            },
            .task = task,
        });
    }

    fn queue_connect(
        self: *AsyncPoll,
        task: usize,
        socket: std.posix.socket_t,
        addr: std.net.Address,
        kind: Socket.Kind,
    ) !void {
        std.posix.connect(
            socket,
            &addr.any,
            addr.getOsSockLen(),
        ) catch |e| switch (e) {
            std.posix.ConnectError.WouldBlock => {},
            else => return e,
        };

        try self.fd_list.append(self.allocator, .{ .fd = socket, .events = std.posix.POLL.OUT, .revents = 0 });
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

    fn queue_recv(self: *AsyncPoll, task: usize, socket: std.posix.socket_t, buffer: []u8) !void {
        try self.fd_list.append(self.allocator, .{ .fd = socket, .events = std.posix.POLL.IN, .revents = 0 });
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

    fn queue_send(self: *AsyncPoll, task: usize, socket: std.posix.socket_t, buffer: []const u8) !void {
        try self.fd_list.append(self.allocator, .{ .fd = socket, .events = std.posix.POLL.OUT, .revents = 0 });
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

    pub fn wake(_: *anyopaque, target_runner: *anyopaque) !void {
        const poll: *AsyncPoll = @ptrCast(@alignCast(target_runner));

        const bytes: []const u8 = "00000000";
        var i: usize = 0;
        while (i < bytes.len) i += try std.posix.write(poll.wake_pipe[1], bytes[i..]);
    }

    pub fn submit(_: *anyopaque) !void {}

    pub fn reap(runner: *anyopaque, completions: []Completion, wait: bool) ![]Completion {
        const poll: *AsyncPoll = @ptrCast(@alignCast(runner));
        var reaped: usize = 0;

        poll_loop: while (reaped == 0 and wait) {
            const current: usize = @intCast(std.time.milliTimestamp());

            // Reap all completed Timers
            while (poll.timers.peek()) |peeked| {
                if (peeked.milliseconds > current) break;
                if (completions.len - reaped == 0) break;

                const timer = poll.timers.remove();
                completions[reaped] = .{
                    .result = .none,
                    .task = timer.task,
                };
                reaped += 1;
            }

            var timeout: i32 = if (!wait or reaped > 0) 0 else -1;

            // Select next Timer
            if (poll.timers.peek()) |peeked| timeout = @intCast(peeked.milliseconds - current);

            log.debug("timeout = {d}", .{timeout});
            const poll_result = if (comptime builtin.os.tag == .windows)
                std.os.windows.poll(poll.fd_list.items.ptr, @intCast(poll.fd_list.items.len), timeout)
            else
                try std.posix.poll(poll.fd_list.items, timeout);

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

                const result: Result = result: {
                    switch (job.type) {
                        .wake => {
                            assert(pfd.revents & std.posix.POLL.IN != 0 or pfd.revents & std.posix.POLL.RDNORM != 0);

                            var buf: [8]u8 = undefined;
                            _ = std.posix.read(poll.wake_pipe[0], &buf) catch unreachable;
                            remove = false;
                            break :result .wake;
                        },
                        .accept => |*inner| {
                            assert(pfd.revents & std.posix.POLL.IN != 0 or pfd.revents & std.posix.POLL.RDNORM != 0);

                            const socket = std.posix.accept(
                                inner.socket,
                                &inner.addr.any,
                                @ptrCast(&inner.addr_len),
                                std.posix.SOCK.NONBLOCK,
                            ) catch |e| {
                                const err = switch (e) {
                                    std.posix.AcceptError.WouldBlock => {
                                        log.debug("accept wouldblock - not removing", .{});
                                        remove = false;
                                        continue;
                                    },
                                    std.posix.AcceptError.ConnectionAborted,
                                    std.posix.AcceptError.ConnectionResetByPeer,
                                    => AcceptError.ConnectionAborted,
                                    std.posix.AcceptError.SocketNotListening => AcceptError.NotListening,
                                    std.posix.AcceptError.ProcessFdQuotaExceeded => AcceptError.ProcessFdQuotaExceeded,
                                    std.posix.AcceptError.SystemFdQuotaExceeded => AcceptError.SystemFdQuotaExceeded,
                                    std.posix.AcceptError.FileDescriptorNotASocket => AcceptError.NotASocket,
                                    std.posix.AcceptError.OperationNotSupported => AcceptError.OperationNotSupported,
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
                        .connect => |_| {
                            assert(pfd.revents & std.posix.POLL.OUT != 0);

                            if (pfd.revents & std.posix.POLL.ERR != 0) {
                                break :result .{ .connect = .{ .err = ConnectError.Unexpected } };
                            } else {
                                break :result .{ .connect = .actual };
                            }
                        },
                        .recv => |inner| {
                            if (pfd.revents & std.posix.POLL.HUP != 0) break :result .{
                                .recv = .{ .err = RecvError.Closed },
                            };

                            assert(pfd.revents & std.posix.POLL.IN != 0 or pfd.revents & std.posix.POLL.RDNORM != 0);
                            const count = std.posix.recv(inner.socket, inner.buffer, 0) catch |e| {
                                const err = switch (e) {
                                    std.posix.RecvFromError.WouldBlock => {
                                        log.debug("recv wouldblock - not removing", .{});
                                        remove = false;
                                        continue;
                                    },
                                    std.posix.RecvFromError.ConnectionResetByPeer => RecvError.Closed,
                                    else => RecvError.Unexpected,
                                };

                                break :result .{ .recv = .{ .err = err } };
                            };

                            if (count == 0) break :result .{ .recv = .{ .err = RecvError.Closed } };
                            break :result .{ .recv = .{ .actual = count } };
                        },
                        .send => |inner| {
                            if (pfd.revents & std.posix.POLL.HUP != 0) break :result .{
                                .send = .{ .err = SendError.Closed },
                            };

                            assert(pfd.revents & std.posix.POLL.OUT != 0);
                            const count = std.posix.send(inner.socket, inner.buffer, 0) catch |e| {
                                log.err("send failed with {}", .{e});
                                const err = switch (e) {
                                    std.posix.SendError.WouldBlock => {
                                        log.debug("send wouldblock - not removing", .{});
                                        remove = false;
                                        continue;
                                    },
                                    std.posix.SendError.ConnectionResetByPeer,
                                    std.posix.SendError.BrokenPipe,
                                    => SendError.Closed,
                                    else => SendError.Unexpected,
                                };

                                break :result .{ .send = .{ .err = err } };
                            };

                            break :result .{ .send = .{ .actual = count } };
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

                completions[reaped] = .{ .result = result, .task = job.task };
                reaped += 1;
            }
        }

        return completions[0..reaped];
    }

    pub fn to_async(self: *AsyncPoll) Async {
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
