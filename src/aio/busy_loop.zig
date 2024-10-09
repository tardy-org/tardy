const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Completion = @import("completion.zig").Completion;

const AsyncIO = @import("lib.zig").AsyncIO;
const AsyncIOError = @import("lib.zig").AsyncIOError;
const AsyncIOOptions = @import("lib.zig").AsyncIOOptions;

const log = std.log.scoped(.@"tardy/async/busy_loop");

pub const AsyncBusyLoop = struct {
    pub const Job = struct {
        type: union(enum) {
            accept,
            recv: []u8,
            send: []const u8,
            close,
        },
        socket: std.posix.socket_t,
        context: *anyopaque,
        time: ?i64,
    };

    inner: std.ArrayListUnmanaged(Job),
    timeout: ?u32,

    pub fn init(allocator: std.mem.Allocator, options: AsyncIOOptions) !AsyncBusyLoop {
        const list = try std.ArrayListUnmanaged(Job).initCapacity(allocator, options.size_connections_max);
        return AsyncBusyLoop{ .inner = list, .timeout = options.ms_operation_max };
    }

    pub fn deinit(self: *AsyncIO, allocator: std.mem.Allocator) void {
        const loop: *AsyncBusyLoop = @ptrCast(@alignCast(self.runner));
        loop.inner.deinit(allocator);
    }

    pub fn queue_accept(
        self: *AsyncIO,
        ctx: *anyopaque,
        socket: std.posix.socket_t,
    ) AsyncIOError!void {
        const loop: *AsyncBusyLoop = @ptrCast(@alignCast(self.runner));
        loop.inner.appendAssumeCapacity(.{
            .type = .accept,
            .socket = socket,
            .context = ctx,
            .time = null,
        });
    }

    pub fn queue_recv(
        self: *AsyncIO,
        ctx: *anyopaque,
        socket: std.posix.socket_t,
        buffer: []u8,
    ) AsyncIOError!void {
        const loop: *AsyncBusyLoop = @ptrCast(@alignCast(self.runner));
        loop.inner.appendAssumeCapacity(.{
            .type = .{ .recv = buffer },
            .socket = socket,
            .context = ctx,
            .time = null,
        });
    }

    pub fn queue_send(
        self: *AsyncIO,
        ctx: *anyopaque,
        socket: std.posix.socket_t,
        buffer: []const u8,
    ) AsyncIOError!void {
        const loop: *AsyncBusyLoop = @ptrCast(@alignCast(self.runner));
        loop.inner.appendAssumeCapacity(.{
            .type = .{ .send = buffer },
            .socket = socket,
            .context = ctx,
            .time = null,
        });
    }

    pub fn queue_close(
        self: *AsyncIO,
        ctx: *anyopaque,
        socket: std.posix.socket_t,
    ) AsyncIOError!void {
        const loop: *AsyncBusyLoop = @ptrCast(@alignCast(self.runner));
        loop.inner.appendAssumeCapacity(.{
            .type = .close,
            .socket = socket,
            .context = ctx,
            .time = null,
        });
    }

    pub fn submit(self: *AsyncIO) AsyncIOError!void {
        const loop: *AsyncBusyLoop = @ptrCast(@alignCast(self.runner));
        if (loop.timeout) |_| {
            const ms = std.time.milliTimestamp();
            for (loop.inner.items) |*job| {
                if (job.time == null) job.time = ms;
            }
        }
    }

    pub fn reap(self: *AsyncIO) AsyncIOError![]Completion {
        const loop: *AsyncBusyLoop = @ptrCast(@alignCast(self.runner));
        var reaped: usize = 0;

        while (reaped < 1) {
            var i: usize = 0;

            const time = std.time.milliTimestamp();
            while (i < loop.inner.items.len and reaped < self.completions.len) : (i += 1) {
                const job = loop.inner.items[i];

                // Handle timeouts first.
                if (loop.timeout) |timeout_ms| {
                    assert(job.time != null);

                    if (time >= job.time.? + timeout_ms) {
                        const com_ptr = &self.completions[reaped];
                        com_ptr.result = .timeout;
                        com_ptr.context = job.context;
                        _ = loop.inner.swapRemove(i);
                        i -|= 1;
                        reaped += 1;
                        continue;
                    }
                }

                switch (job.type) {
                    .accept => {
                        const com_ptr = &self.completions[reaped];

                        const res: std.posix.socket_t = blk: {
                            const accept_result = std.posix.accept(job.socket, null, null, 0) catch |e| {
                                switch (e) {
                                    error.WouldBlock => continue,
                                    error.ConnectionResetByPeer => switch (comptime builtin.target.os.tag) {
                                        .windows => break :blk std.os.windows.ws2_32.INVALID_SOCKET,
                                        else => break :blk 0,
                                    },
                                    else => {
                                        log.debug("accept failed: {}", .{e});
                                        switch (comptime builtin.target.os.tag) {
                                            .windows => break :blk std.os.windows.ws2_32.INVALID_SOCKET,
                                            else => break :blk -1,
                                        }
                                    },
                                }
                            };

                            break :blk accept_result;
                        };

                        com_ptr.result = .{ .socket = res };
                        com_ptr.context = job.context;
                        _ = loop.inner.swapRemove(i);
                        i -|= 1;
                        reaped += 1;
                    },

                    .recv => |buffer| {
                        const com_ptr = &self.completions[reaped];
                        const len: i32 = blk: {
                            const read_len = std.posix.recv(job.socket, buffer, 0) catch |e| {
                                switch (e) {
                                    error.WouldBlock => continue,
                                    error.ConnectionResetByPeer => break :blk 0,
                                    else => {
                                        log.debug("recv failed: {}", .{e});
                                        break :blk -1;
                                    },
                                }
                            };

                            break :blk @intCast(read_len);
                        };

                        com_ptr.result = .{ .value = @intCast(len) };
                        com_ptr.context = job.context;
                        _ = loop.inner.swapRemove(i);
                        i -|= 1;
                        reaped += 1;
                    },

                    .send => |buffer| {
                        const com_ptr = &self.completions[reaped];
                        const len: i32 = blk: {
                            const send_len = std.posix.send(job.socket, buffer, 0) catch |e| {
                                switch (e) {
                                    error.WouldBlock => continue,
                                    error.ConnectionResetByPeer => break :blk 0,
                                    else => {
                                        log.debug("send failed: {}", .{e});
                                        break :blk -1;
                                    },
                                }
                            };

                            break :blk @intCast(send_len);
                        };

                        com_ptr.result = .{ .value = @intCast(len) };
                        com_ptr.context = job.context;
                        _ = loop.inner.swapRemove(i);
                        i -|= 1;
                        reaped += 1;
                    },

                    .close => {
                        const com_ptr = &self.completions[reaped];
                        std.posix.close(job.socket);
                        com_ptr.result = .{ .value = 0 };
                        com_ptr.context = job.context;
                        _ = loop.inner.swapRemove(i);
                        i -|= 1;
                        reaped += 1;
                    },
                }
            }
        }

        return self.completions[0..reaped];
    }

    pub fn to_async(self: *AsyncBusyLoop) AsyncIO {
        return AsyncIO{
            .runner = self,
            ._deinit = deinit,
            ._queue_accept = queue_accept,
            ._queue_recv = queue_recv,
            ._queue_send = queue_send,
            ._queue_close = undefined,
            ._submit = submit,
            ._reap = reap,
        };
    }
};
