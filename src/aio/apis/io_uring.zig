const std = @import("std");
const assert = std.debug.assert;
const LinuxError = std.os.linux.E;
const builtin = @import("builtin");

const Pool = @import("../../core/pool.zig").Pool;
const Cross = @import("../../cross/lib.zig");
const Stat = @import("../../fs/lib.zig").Stat;
const Path = @import("../../fs/lib.zig").Path;
const Timespec = @import("../../lib.zig").Timespec;
const Socket = @import("../../net/lib.zig").Socket;
const Completion = @import("../completion.zig").Completion;
const Result = @import("../completion.zig").Result;
const InnerOpenResult = @import("../completion.zig").InnerOpenResult;
const OpenError = @import("../completion.zig").OpenError;
const AcceptResult = @import("../completion.zig").AcceptResult;
const AcceptError = @import("../completion.zig").AcceptError;
const ConnectResult = @import("../completion.zig").ConnectResult;
const ConnectError = @import("../completion.zig").ConnectError;
const RecvResult = @import("../completion.zig").RecvResult;
const RecvError = @import("../completion.zig").RecvError;
const SendResult = @import("../completion.zig").SendResult;
const SendError = @import("../completion.zig").SendError;
const MkdirResult = @import("../completion.zig").MkdirResult;
const MkdirError = @import("../completion.zig").MkdirError;
const DeleteResult = @import("../completion.zig").DeleteResult;
const DeleteError = @import("../completion.zig").DeleteError;
const ReadResult = @import("../completion.zig").ReadResult;
const ReadError = @import("../completion.zig").ReadError;
const WriteResult = @import("../completion.zig").WriteResult;
const WriteError = @import("../completion.zig").WriteError;
const StatResult = @import("../completion.zig").StatResult;
const StatError = @import("../completion.zig").StatError;
const Job = @import("../job.zig").Job;
const Async = @import("../lib.zig").Async;
const AsyncOptions = @import("../lib.zig").AsyncOptions;
const AsyncFeatures = @import("../lib.zig").AsyncFeatures;
const AsyncSubmission = @import("../lib.zig").AsyncSubmission;
const AsyncOpenFlags = @import("../lib.zig").AsyncOpenFlags;

const log = std.log.scoped(.@"tardy/aio/io_uring");

const JobBundle = struct {
    job: Job,
    statx: *std.os.linux.Statx = undefined,
    timespec: *std.os.linux.kernel_timespec = undefined,
};

pub const AsyncIoUring = struct {
    const base_flags = blk: {
        var flags = 0;
        // If you are building for musl, you won't have access to these flags.
        // This means you will run with no flags for compatibility reasons.

        // SINGLE_ISSUER requires 6.0
        if (builtin.target.os.isAtLeast(
            .linux,
            .{ .major = 6, .minor = 0, .patch = 0 },
        )) |is_atleast| {
            if (is_atleast) flags |= std.os.linux.IORING_SETUP_SINGLE_ISSUER;
        }

        // COOP_TASKRUN requires 5.19
        if (builtin.target.os.isAtLeast(
            .linux,
            .{ .major = 5, .minor = 19, .patch = 0 },
        )) |is_atleast| {
            if (is_atleast) flags |= std.os.linux.IORING_SETUP_COOP_TASKRUN;
        }

        break :blk flags;
    };

    allocator: std.mem.Allocator,
    inner: *std.os.linux.IoUring,
    wake_event_fd: std.posix.fd_t,
    wake_event_buffer: []u8,

    // Currently, the batch size is predetermined.
    // You basically define how large you want your batches to be.
    cqes: []std.os.linux.io_uring_cqe,
    jobs: Pool(JobBundle),

    pub fn init(allocator: std.mem.Allocator, options: AsyncOptions) !AsyncIoUring {
        // Extra job for the wake event_fd.
        const size = options.size_tasks_initial + 1;

        const wake_event_fd: std.posix.fd_t = @intCast(
            std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC),
        );
        errdefer std.posix.close(wake_event_fd);

        const wake_event_buffer = try allocator.alloc(u8, 8);
        errdefer allocator.free(wake_event_buffer);

        const submit_size: u16 = @min(
            // 4096 is the max uring submit size.
            4096,
            std.math.ceilPowerOfTwo(u16, @intCast(options.size_aio_reap_max)) catch 4096,
        );

        const uring = blk: {
            if (options.parent_async) |parent| {
                const parent_uring: *AsyncIoUring = @ptrCast(
                    @alignCast(parent.runner),
                );
                assert(parent_uring.inner.fd >= 0);

                // Initialize using the WQ from the parent ring.
                const flags: u32 = base_flags | std.os.linux.IORING_SETUP_ATTACH_WQ;
                var params = std.mem.zeroInit(std.os.linux.io_uring_params, .{
                    .flags = flags,
                    .wq_fd = @as(u32, @intCast(parent_uring.inner.fd)),
                });

                const uring = try allocator.create(std.os.linux.IoUring);
                errdefer allocator.destroy(uring);

                uring.* = try .init_params(submit_size, &params);
                errdefer uring.deinit();

                break :blk uring;
            } else {
                // Initalize IO Uring
                const uring = try allocator.create(std.os.linux.IoUring);
                errdefer allocator.destroy(uring);

                uring.* = try .init(submit_size, base_flags);
                errdefer uring.deinit();

                break :blk uring;
            }
        };
        errdefer allocator.destroy(uring);
        errdefer uring.deinit();

        var jobs: Pool(JobBundle) = try .init(allocator, size, options.pooling);
        errdefer jobs.deinit();

        const index = jobs.borrow_assume_unset(0);
        const item = jobs.get_ptr(index);
        item.* = .{ .job = .{ .index = index, .type = .wake, .task = undefined } };
        _ = try uring.read(index, wake_event_fd, .{ .buffer = wake_event_buffer }, 0);

        const cqes = try allocator.alloc(std.os.linux.io_uring_cqe, options.size_aio_reap_max);
        errdefer allocator.free(cqes);

        return AsyncIoUring{
            .inner = uring,
            .allocator = allocator,
            .wake_event_fd = wake_event_fd,
            .wake_event_buffer = wake_event_buffer,
            .jobs = jobs,
            .cqes = cqes,
        };
    }

    pub fn inner_deinit(self: *AsyncIoUring, allocator: std.mem.Allocator) void {
        std.posix.close(self.wake_event_fd);
        self.inner.deinit();
        self.jobs.deinit();
        allocator.free(self.wake_event_buffer);
        allocator.free(self.cqes);
        allocator.destroy(self.inner);
    }

    fn deinit(runner: *anyopaque, allocator: std.mem.Allocator) void {
        const uring: *AsyncIoUring = @ptrCast(@alignCast(runner));
        uring.inner_deinit(allocator);
    }

    fn queue_job(
        runner: *anyopaque,
        task: usize,
        job: AsyncSubmission,
    ) !void {
        const uring: *AsyncIoUring = @ptrCast(@alignCast(runner));
        (switch (job) {
            .timer => |inner| queue_timer(uring, task, inner),
            .open => |inner| queue_open(uring, task, inner.path, inner.flags),
            .delete => |inner| queue_delete(uring, task, inner.path, inner.is_dir),
            .mkdir => |inner| queue_mkdir(uring, task, inner.path, inner.mode),
            .stat => |inner| queue_stat(uring, task, inner),
            .read => |inner| queue_read(uring, task, inner.fd, inner.buffer, inner.offset),
            .write => |inner| queue_write(uring, task, inner.fd, inner.buffer, inner.offset),
            .close => |inner| queue_close(uring, task, inner),
            .accept => |inner| queue_accept(uring, task, inner.socket, inner.kind),
            .connect => |inner| queue_connect(uring, task, inner.socket, inner.addr, inner.kind),
            .recv => |inner| queue_recv(uring, task, inner.socket, inner.buffer),
            .send => |inner| queue_send(uring, task, inner.socket, inner.buffer),
        }) catch |e| if (e == error.SubmissionQueueFull) {
            try submit(runner);
            try queue_job(runner, task, job);
        } else return e;
    }

    fn queue_timer(self: *AsyncIoUring, task: usize, timespec: Timespec) !void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);
        item.job = .{
            .index = index,
            .task = task,
            .type = .{ .timer = .none },
        };

        const timespec_ptr = try self.allocator.create(std.os.linux.kernel_timespec);
        errdefer self.allocator.destroy(timespec_ptr);

        timespec_ptr.* = std.os.linux.kernel_timespec{
            .sec = @intCast(timespec.seconds),
            .nsec = @intCast(timespec.nanos),
        };
        item.timespec = timespec_ptr;

        _ = try self.inner.timeout(index, timespec_ptr, 0, 0);
    }

    fn queue_open(self: *AsyncIoUring, task: usize, path: Path, flags: AsyncOpenFlags) !void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);
        item.job = .{
            .index = index,
            .type = .{
                .open = .{
                    .path = path,
                    .kind = if (flags.directory) .dir else .file,
                    .flags = flags,
                },
            },
            .task = task,
        };

        const o_flags: std.os.linux.O = blk: {
            var o: std.os.linux.O = .{};

            switch (flags.mode) {
                .read => o.ACCMODE = .RDONLY,
                .write => o.ACCMODE = .WRONLY,
                .read_write => o.ACCMODE = .RDWR,
            }

            o.APPEND = flags.append;
            o.CREAT = flags.create;
            o.TRUNC = flags.truncate;
            o.EXCL = flags.exclusive;
            o.NONBLOCK = flags.non_block;
            o.SYNC = flags.sync;
            o.DIRECTORY = flags.directory;
            o.PATH = false;

            break :blk o;
        };

        const perms = flags.perms orelse 0;

        switch (path) {
            .rel => |inner| _ = try self.inner.openat(
                index,
                inner.dir,
                inner.path.ptr,
                o_flags,
                @intCast(perms),
            ),
            .abs => |inner| _ = try self.inner.openat(
                index,
                std.posix.AT.FDCWD,
                inner.ptr,
                o_flags,
                @intCast(perms),
            ),
        }
    }

    fn queue_delete(self: *AsyncIoUring, task: usize, path: Path, is_dir: bool) !void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);
        item.job = .{ .index = index, .type = .{ .delete = .{ .path = path, .is_dir = is_dir } }, .task = task };

        const mode: u32 = if (is_dir) std.posix.AT.REMOVEDIR else 0;

        switch (path) {
            .rel => |inner| _ = try self.inner.unlinkat(index, inner.dir, inner.path.ptr, mode),
            .abs => |inner| _ = try self.inner.unlinkat(index, std.posix.AT.FDCWD, inner.ptr, mode),
        }
    }

    fn queue_mkdir(self: *AsyncIoUring, task: usize, path: Path, mode: isize) !void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);
        item.job = .{ .index = index, .type = .{ .mkdir = .{ .path = path, .mode = mode } }, .task = task };

        switch (path) {
            .rel => |inner| _ = try self.inner.mkdirat(index, inner.dir, inner.path.ptr, @intCast(mode)),
            .abs => |inner| _ = try self.inner.mkdirat(index, std.posix.AT.FDCWD, inner.ptr, @intCast(mode)),
        }
    }

    fn queue_stat(self: *AsyncIoUring, task: usize, fd: std.posix.fd_t) !void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);
        item.job = .{ .index = index, .type = .{ .stat = fd }, .task = task };

        const statx_ptr = try self.allocator.create(std.os.linux.Statx);
        errdefer self.allocator.destroy(statx_ptr);
        item.statx = statx_ptr;

        _ = try self.inner.statx(
            index,
            fd,
            "",
            std.os.linux.AT.EMPTY_PATH,
            std.os.linux.STATX_BASIC_STATS,
            statx_ptr,
        );
    }

    fn queue_read(self: *AsyncIoUring, task: usize, fd: std.posix.fd_t, buffer: []u8, offset: ?usize) !void {
        // If we don't have an offset, set it as -1.
        const real_offset: usize = if (offset) |o| o else @bitCast(@as(isize, -1));

        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);
        const item = self.jobs.get_ptr(index);
        item.job = .{
            .index = index,
            .type = .{
                .read = .{
                    .fd = fd,
                    .buffer = buffer,
                    .offset = real_offset,
                },
            },
            .task = task,
        };

        _ = try self.inner.read(index, fd, .{ .buffer = buffer }, real_offset);
    }

    fn queue_write(self: *AsyncIoUring, task: usize, fd: std.posix.fd_t, buffer: []const u8, offset: ?usize) !void {
        // If we don't have an offset, set it as -1.
        const real_offset: usize = if (offset) |o| o else @bitCast(@as(isize, -1));

        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);
        const item = self.jobs.get_ptr(index);
        item.job = .{
            .index = index,
            .type = .{
                .write = .{
                    .fd = fd,
                    .buffer = buffer,
                    .offset = real_offset,
                },
            },
            .task = task,
        };

        _ = try self.inner.write(index, fd, buffer, real_offset);
    }

    fn queue_close(self: *AsyncIoUring, task: usize, fd: std.posix.fd_t) !void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);
        item.job = .{ .index = index, .type = .{ .close = fd }, .task = task };

        _ = try self.inner.close(index, fd);
    }

    fn queue_accept(self: *AsyncIoUring, task: usize, socket: std.posix.socket_t, kind: Socket.Kind) !void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);
        item.job = .{
            .index = index,
            .type = .{
                .accept = .{
                    .socket = socket,
                    .kind = kind,
                    .addr = undefined,
                    .addr_len = @sizeOf(std.net.Address),
                },
            },
            .task = task,
        };

        _ = try self.inner.accept(
            index,
            socket,
            &item.job.type.accept.addr.any,
            @ptrCast(&item.job.type.accept.addr_len),
            0,
        );
    }

    fn queue_connect(
        self: *AsyncIoUring,
        task: usize,
        socket: std.posix.socket_t,
        addr: std.net.Address,
        kind: Socket.Kind,
    ) !void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);
        const item = self.jobs.get_ptr(index);
        item.job = .{
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

        _ = try self.inner.connect(
            index,
            socket,
            &item.job.type.connect.addr.any,
            addr.getOsSockLen(),
        );
    }

    fn queue_recv(
        self: *AsyncIoUring,
        task: usize,
        socket: std.posix.socket_t,
        buffer: []u8,
    ) !void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);
        const item = self.jobs.get_ptr(index);
        item.job = .{
            .index = index,
            .type = .{
                .recv = .{
                    .socket = socket,
                    .buffer = buffer,
                },
            },
            .task = task,
        };

        _ = try self.inner.recv(index, socket, .{ .buffer = buffer }, 0);
    }

    fn queue_send(self: *AsyncIoUring, task: usize, socket: std.posix.socket_t, buffer: []const u8) !void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);
        item.job = .{
            .index = index,
            .type = .{
                .send = .{
                    .socket = socket,
                    .buffer = buffer,
                },
            },
            .task = task,
        };

        _ = try self.inner.send(index, socket, buffer, 0);
    }

    inline fn queue_wake(self: *AsyncIoUring) !void {
        if (self.wake_event_fd == Cross.fd.INVALID_FD) return;

        const index = try self.jobs.borrow();
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);
        item.job = .{
            .index = index,
            .type = .wake,
            .task = undefined,
        };

        _ = try self.inner.read(
            index,
            self.wake_event_fd,
            .{ .buffer = self.wake_event_buffer },
            0,
        );
    }

    fn wake(runner: *anyopaque) !void {
        const uring: *AsyncIoUring = @ptrCast(@alignCast(runner));
        const bytes: []const u8 = "00000000";
        var i: usize = 0;
        while (i < bytes.len) i += try std.posix.write(uring.wake_event_fd, bytes);
    }

    fn submit(runner: *anyopaque) !void {
        const uring: *AsyncIoUring = @ptrCast(@alignCast(runner));

        _ = while (true) {
            break uring.inner.submit() catch |e| switch (e) {
                error.SignalInterrupt => continue,
                else => return e,
            };
        };
    }

    fn reap(runner: *anyopaque, completions: []Completion, wait: bool) ![]Completion {
        const uring: *AsyncIoUring = @ptrCast(@alignCast(runner));
        // either wait for atleast 1 or just take whats there.
        const uring_nr: u32 = if (wait) 1 else 0;

        const count = while (true) {
            break uring.inner.copy_cqes(uring.cqes[0..], uring_nr) catch |e| {
                switch (e) {
                    error.SignalInterrupt => continue,
                    else => return e,
                }
            };
        };

        for (uring.cqes[0..count], 0..) |cqe, i| {
            var job_with_data: JobBundle = uring.jobs.get(cqe.user_data);
            const job: *Job = &job_with_data.job;
            uring.jobs.release(job.index);

            const result: Result = blk: {
                if (cqe.res < 0) {
                    log.debug("{d} - other status on SQE: {t}", .{
                        job.index,
                        @as(LinuxError, @enumFromInt(-cqe.res)),
                    });
                }
                switch (job.type) {
                    .wake => {
                        try uring.queue_wake();
                        break :blk .wake;
                    },
                    .timer => {
                        defer uring.allocator.destroy(job_with_data.timespec);
                        break :blk .none;
                    },
                    .close => break :blk .close,
                    .accept => |inner| {
                        if (cqe.res >= 0) switch (inner.kind) {
                            .tcp, .unix => break :blk .{
                                .accept = .{
                                    .actual = .{ .handle = cqe.res, .addr = inner.addr, .kind = inner.kind },
                                },
                            },
                            .udp => unreachable,
                        };

                        const result: AcceptResult = result: {
                            const e: LinuxError = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                LinuxError.AGAIN => .{ .err = AcceptError.WouldBlock },
                                LinuxError.BADF => .{ .err = AcceptError.InvalidFd },
                                LinuxError.CONNABORTED => .{ .err = AcceptError.ConnectionAborted },
                                LinuxError.FAULT => .{ .err = AcceptError.InvalidAddress },
                                LinuxError.INVAL => .{ .err = AcceptError.NotListening },
                                LinuxError.MFILE => .{ .err = AcceptError.ProcessFdQuotaExceeded },
                                LinuxError.NFILE => .{ .err = AcceptError.SystemFdQuotaExceeded },
                                LinuxError.NOBUFS, LinuxError.NOMEM => .{ .err = AcceptError.OutOfMemory },
                                LinuxError.NOTSOCK => .{ .err = AcceptError.NotASocket },
                                LinuxError.OPNOTSUPP => .{ .err = AcceptError.OperationNotSupported },
                                else => .{ .err = AcceptError.Unexpected },
                            };
                        };

                        break :blk .{ .accept = result };
                    },
                    .connect => |_| {
                        if (cqe.res >= 0) break :blk .{ .connect = .actual };

                        const result: ConnectResult = result: {
                            const e: LinuxError = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                LinuxError.ACCES, LinuxError.PERM => .{ .err = ConnectError.AccessDenied },
                                LinuxError.ADDRINUSE => .{ .err = ConnectError.AddressInUse },
                                LinuxError.ADDRNOTAVAIL => .{ .err = ConnectError.AddressNotAvailable },
                                LinuxError.AFNOSUPPORT => .{ .err = ConnectError.AddressFamilyNotSupported },
                                LinuxError.AGAIN, LinuxError.ALREADY, LinuxError.INPROGRESS => .{
                                    .err = ConnectError.WouldBlock,
                                },
                                LinuxError.BADF => .{ .err = ConnectError.InvalidFd },
                                LinuxError.CONNREFUSED => .{ .err = ConnectError.ConnectionRefused },
                                LinuxError.FAULT => .{ .err = ConnectError.InvalidAddress },
                                LinuxError.ISCONN => .{ .err = ConnectError.AlreadyConnected },
                                LinuxError.NETUNREACH => .{ .err = ConnectError.NetworkUnreachable },
                                LinuxError.NOTSOCK => .{ .err = ConnectError.NotASocket },
                                LinuxError.PROTOTYPE => .{ .err = ConnectError.ProtocolFamilyNotSupported },
                                LinuxError.TIMEDOUT => .{ .err = ConnectError.TimedOut },
                                else => .{ .err = ConnectError.Unexpected },
                            };
                        };

                        break :blk .{ .connect = result };
                    },
                    .recv => {
                        if (cqe.res > 0) break :blk .{ .recv = .{ .actual = @intCast(cqe.res) } };
                        if (cqe.res == 0) break :blk .{ .recv = .{ .err = RecvError.Closed } };

                        const result: RecvResult = result: {
                            const e: LinuxError = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                LinuxError.AGAIN => .{ .err = RecvError.WouldBlock },
                                LinuxError.BADF => .{ .err = RecvError.InvalidFd },
                                LinuxError.CONNRESET => .{ .err = RecvError.Closed },
                                LinuxError.CONNREFUSED => .{ .err = RecvError.ConnectionRefused },
                                LinuxError.FAULT => .{ .err = RecvError.InvalidAddress },
                                LinuxError.INVAL => .{ .err = RecvError.InvalidArguments },
                                LinuxError.NOMEM => .{ .err = RecvError.OutOfMemory },
                                LinuxError.NOTCONN => .{ .err = RecvError.NotConnected },
                                LinuxError.NOTSOCK => .{ .err = RecvError.NotASocket },
                                else => .{ .err = RecvError.Unexpected },
                            };
                        };

                        break :blk .{ .recv = result };
                    },
                    .send => {
                        if (cqe.res >= 0) break :blk .{ .send = .{ .actual = @intCast(cqe.res) } };

                        const result: SendResult = result: {
                            const e: LinuxError = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                LinuxError.ACCES => .{ .err = SendError.AccessDenied },
                                LinuxError.AGAIN => .{ .err = SendError.WouldBlock },
                                LinuxError.ALREADY => .{ .err = SendError.OpenInProgress },
                                LinuxError.BADF => .{ .err = SendError.InvalidFd },
                                LinuxError.CONNRESET, LinuxError.PIPE => .{ .err = SendError.Closed },
                                LinuxError.DESTADDRREQ => .{ .err = SendError.NoDestinationAddress },
                                LinuxError.FAULT => .{ .err = SendError.InvalidAddress },
                                LinuxError.INVAL => .{ .err = SendError.InvalidArguments },
                                LinuxError.ISCONN => .{ .err = SendError.AlreadyConnected },
                                LinuxError.MSGSIZE => .{ .err = SendError.InvalidSize },
                                LinuxError.NOBUFS, LinuxError.NOMEM => .{ .err = SendError.OutOfMemory },
                                LinuxError.NOTCONN => .{ .err = SendError.NotConnected },
                                LinuxError.OPNOTSUPP => .{ .err = SendError.OperationNotSupported },
                                else => .{ .err = SendError.Unexpected },
                            };
                        };

                        break :blk .{ .send = result };
                    },
                    .mkdir => {
                        if (cqe.res == 0) break :blk .{ .mkdir = .{ .actual = {} } };

                        const result: MkdirResult = result: {
                            const e: LinuxError = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                LinuxError.ACCES => .{ .err = MkdirError.AccessDenied },
                                LinuxError.EXIST => .{ .err = MkdirError.AlreadyExists },
                                LinuxError.LOOP, LinuxError.MLINK => .{ .err = MkdirError.Loop },
                                LinuxError.NAMETOOLONG => .{ .err = MkdirError.NameTooLong },
                                LinuxError.NOENT => .{ .err = MkdirError.NotFound },
                                LinuxError.NOSPC => .{ .err = MkdirError.NoSpace },
                                LinuxError.NOTDIR => .{ .err = MkdirError.NotADirectory },
                                LinuxError.ROFS => .{ .err = MkdirError.ReadOnlyFileSystem },
                                else => .{ .err = MkdirError.Unexpected },
                            };
                        };

                        break :blk .{ .mkdir = result };
                    },
                    .open => |inner| {
                        if (cqe.res >= 0) switch (inner.kind) {
                            .file => break :blk .{
                                .open = .{ .actual = .{ .file = .{ .handle = @intCast(cqe.res) } } },
                            },
                            .dir => break :blk .{
                                .open = .{ .actual = .{ .dir = .{ .handle = @intCast(cqe.res) } } },
                            },
                        };

                        const result: InnerOpenResult = result: {
                            const e: LinuxError = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                LinuxError.ACCES, LinuxError.PERM => .{ .err = OpenError.AccessDenied },
                                LinuxError.BADF => .{ .err = OpenError.InvalidFd },
                                LinuxError.BUSY => .{ .err = OpenError.Busy },
                                LinuxError.DQUOT => .{ .err = OpenError.DiskQuotaExceeded },
                                LinuxError.EXIST => .{ .err = OpenError.AlreadyExists },
                                LinuxError.FAULT => .{ .err = OpenError.InvalidAddress },
                                LinuxError.FBIG, LinuxError.OVERFLOW => .{ .err = OpenError.FileTooBig },
                                LinuxError.INVAL => .{ .err = OpenError.InvalidArguments },
                                LinuxError.ISDIR => .{ .err = OpenError.IsDirectory },
                                LinuxError.LOOP => .{ .err = OpenError.Loop },
                                LinuxError.MFILE => .{ .err = OpenError.ProcessFdQuotaExceeded },
                                LinuxError.NAMETOOLONG => .{ .err = OpenError.NameTooLong },
                                LinuxError.NFILE => .{ .err = OpenError.SystemFdQuotaExceeded },
                                LinuxError.NODEV, LinuxError.NXIO => .{ .err = OpenError.DeviceNotFound },
                                LinuxError.NOENT => .{ .err = OpenError.NotFound },
                                LinuxError.NOMEM => .{ .err = OpenError.OutOfMemory },
                                LinuxError.NOSPC => .{ .err = OpenError.NoSpace },
                                LinuxError.NOTDIR => .{ .err = OpenError.NotADirectory },
                                LinuxError.OPNOTSUPP => .{ .err = OpenError.OperationNotSupported },
                                LinuxError.ROFS => .{ .err = OpenError.ReadOnlyFileSystem },
                                LinuxError.TXTBSY => .{ .err = OpenError.FileLocked },
                                LinuxError.AGAIN => .{ .err = OpenError.WouldBlock },
                                else => .{ .err = OpenError.Unexpected },
                            };
                        };

                        break :blk .{ .open = result };
                    },
                    .delete => {
                        if (cqe.res == 0) break :blk .{ .delete = .{ .actual = {} } };

                        const result: DeleteResult = result: {
                            const e: LinuxError = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                // unlink
                                LinuxError.ACCES => .{ .err = DeleteError.AccessDenied },
                                LinuxError.BUSY => .{ .err = DeleteError.Busy },
                                LinuxError.FAULT => .{ .err = DeleteError.InvalidAddress },
                                LinuxError.IO => .{ .err = DeleteError.IoError },
                                LinuxError.ISDIR, LinuxError.PERM => .{ .err = DeleteError.IsDirectory },
                                LinuxError.LOOP => .{ .err = DeleteError.Loop },
                                LinuxError.NAMETOOLONG => .{ .err = DeleteError.NameTooLong },
                                LinuxError.NOENT => .{ .err = DeleteError.NotFound },
                                LinuxError.NOMEM => .{ .err = DeleteError.OutOfMemory },
                                LinuxError.NOTDIR => .{ .err = DeleteError.IsNotDirectory },
                                LinuxError.ROFS => .{ .err = DeleteError.ReadOnlyFileSystem },
                                LinuxError.BADF => .{ .err = DeleteError.InvalidFd },
                                // rmdir
                                LinuxError.INVAL => .{ .err = DeleteError.InvalidArguments },
                                LinuxError.NOTEMPTY => .{ .err = DeleteError.NotEmpty },
                                else => .{ .err = DeleteError.Unexpected },
                            };
                        };

                        break :blk .{ .delete = result };
                    },
                    .read => {
                        if (cqe.res > 0) break :blk .{ .read = .{ .actual = @intCast(cqe.res) } };
                        if (cqe.res == 0) break :blk .{ .read = .{ .err = ReadError.EndOfFile } };

                        const result: ReadResult = result: {
                            const e: LinuxError = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                LinuxError.AGAIN => .{ .err = ReadError.WouldBlock },
                                LinuxError.BADF => .{ .err = ReadError.InvalidFd },
                                LinuxError.FAULT => .{ .err = ReadError.InvalidAddress },
                                LinuxError.INVAL => .{ .err = ReadError.InvalidArguments },
                                LinuxError.IO => .{ .err = ReadError.IoError },
                                LinuxError.ISDIR => .{ .err = ReadError.IsDirectory },
                                else => .{ .err = ReadError.Unexpected },
                            };
                        };

                        break :blk .{ .read = result };
                    },
                    .write => {
                        if (cqe.res > 0) break :blk .{ .write = .{ .actual = @intCast(cqe.res) } };

                        const result: WriteResult = result: {
                            const e: LinuxError = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                LinuxError.AGAIN => .{ .err = WriteError.WouldBlock },
                                LinuxError.BADF => .{ .err = WriteError.InvalidFd },
                                LinuxError.DESTADDRREQ => .{ .err = WriteError.NoDestinationAddress },
                                LinuxError.DQUOT => .{ .err = WriteError.DiskQuotaExceeded },
                                LinuxError.FAULT => .{ .err = WriteError.InvalidAddress },
                                LinuxError.FBIG => .{ .err = WriteError.FileTooBig },
                                LinuxError.INVAL => .{ .err = WriteError.InvalidArguments },
                                LinuxError.IO => .{ .err = WriteError.IoError },
                                LinuxError.NOSPC => .{ .err = WriteError.NoSpace },
                                LinuxError.PERM => .{ .err = WriteError.AccessDenied },
                                LinuxError.PIPE => .{ .err = WriteError.BrokenPipe },
                                else => .{ .err = WriteError.Unexpected },
                            };
                        };

                        break :blk .{ .write = result };
                    },
                    .stat => {
                        defer uring.allocator.destroy(job_with_data.statx);

                        if (cqe.res == 0) {
                            const statx = job_with_data.statx;
                            const stat: Stat = .{
                                .size = @intCast(statx.size),
                                .mode = @intCast(statx.mode),
                                .accessed = .{
                                    .seconds = @intCast(statx.atime.sec),
                                    .nanos = @intCast(statx.atime.nsec),
                                },
                                .modified = .{
                                    .seconds = @intCast(statx.mtime.sec),
                                    .nanos = @intCast(statx.mtime.nsec),
                                },
                                .changed = .{
                                    .seconds = @intCast(statx.ctime.sec),
                                    .nanos = @intCast(statx.ctime.nsec),
                                },
                            };
                            break :blk .{ .stat = .{ .actual = stat } };
                        }

                        const result: StatResult = result: {
                            const e: LinuxError = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                LinuxError.ACCES => .{ .err = StatError.AccessDenied },
                                LinuxError.BADF => .{ .err = StatError.InvalidFd },
                                LinuxError.FAULT => .{ .err = StatError.InvalidAddress },
                                LinuxError.INVAL => .{ .err = StatError.InvalidArguments },
                                LinuxError.LOOP => .{ .err = StatError.Loop },
                                LinuxError.NAMETOOLONG => .{ .err = StatError.NameTooLong },
                                LinuxError.NOENT => .{ .err = StatError.NotFound },
                                LinuxError.NOMEM => .{ .err = StatError.OutOfMemory },
                                LinuxError.NOTDIR => .{ .err = StatError.NotADirectory },
                                else => .{ .err = StatError.Unexpected },
                            };
                        };

                        break :blk .{ .stat = result };
                    },
                }
            };

            completions[i] = Completion{
                .result = result,
                .task = job.task,
            };
        }

        return completions[0..count];
    }

    pub fn to_async(self: *AsyncIoUring) Async {
        return Async{
            .runner = self,
            .features = AsyncFeatures.all(),
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
