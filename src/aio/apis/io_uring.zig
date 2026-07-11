// TODO: move imports of all files to the bottom
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Io = std.Io;
const builtin = @import("builtin");
const mem = std.mem;

const Cross = @import("../../cross/lib.zig");
const Stat = @import("../../fs/lib.zig").Stat;
const Path = @import("../../fs/lib.zig").Path;
const Socket = @import("../../net/lib.zig").Socket;
const Job = @import("../job.zig").Job;
const tardy = @import("../../root.zig");
const results = tardy.results;
const pool = tardy.core.pool;

const AsyncIO = tardy.AsyncIO;
const syscall = @import("syscall.zig");
const posix = std.posix;

pub const Errors = struct {
    pub const Reap = Submit || Error;
    pub const QueueJob = Error || Submit;
    pub const Wake = syscall.WriteError;

    pub const Init = error{
        EntriesZero,
        EntriesNotPowerOfTwo,
        ParamsOutsideAccessibleAddressSpace,
        // The resv array contains non-zero data, p.flags contains an unsupported flag,
        // entries out of bounds, IORING_SETUP_SQ_AFF was specified without IORING_SETUP_SQPOLL,
        // or IORING_SETUP_CQSIZE was specified but linux.io_uring_params.cq_entries was invalid:
        ArgumentsInvalid,
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        SystemResources,
        // IORING_SETUP_SQPOLL was specified but effective user ID lacks sufficient privileges,
        // or a container seccomp policy prohibits io_uring syscalls:
        PermissionDenied,
        SystemOutdated,
    } || posix.MMapError || Error;

    pub const Submit = error{
        SystemResources,
        // The SQE `fd` is invalid, or IOSQE_FIXED_FILE was set but no files were registered:
        FileDescriptorInvalid,
        // The file descriptor is valid, but the ring is not in the right state.
        // See io_uring_register(2) for how to enable the ring.
        FileDescriptorInBadState,
        // The application attempted to overcommit the number of requests it can have pending.
        // The application should wait for some completions and try again:
        CompletionQueueOvercommitted,
        // The SQE is invalid, or valid but the ring was setup with IORING_SETUP_IOPOLL:
        SubmissionQueueEntryInvalid,
        // The buffer is outside the process' accessible address space, or IORING_OP_READ_FIXED
        // or IORING_OP_WRITE_FIXED was specified but no buffers were registered, or the range
        // described by `addr` and `len` is not within the buffer registered at `buf_index`:
        BufferInvalid,
        RingShuttingDown,
        // The kernel believes our `self.fd` does not refer to an io_uring instance,
        // or the opcode is valid but not supported by this kernel (more likely):
        OpcodeNotSupported,
        // The thread submitting the work is invalid. This may occur if IORING_ENTER_GETEVENTS
        // and IORING_SETUP_DEFER_TASKRUN is set, but the submitting thread is not the thread
        // that initially created or enabled the io_uring associated with fd.
        InvalidThread,
        // The operation was interrupted by a delivery of a signal before it could complete.
        // This can happen while waiting for events with IORING_ENTER_GETEVENTS:
        SignalInterrupt,
        Unexpected,
    };
};

pub const Error = error{
    SubmissionQueueFull,
} || pool.Error;

const log = std.log.scoped(.@"tardy/aio/io_uring");

const JobBundle = struct {
    job: Job,
    statx: *linux.Statx = undefined,
    timespec: *linux.kernel_timespec = undefined,
};

pub const AsyncIoUring = struct {
    allocator: mem.Allocator,
    inner: *linux.IoUring,
    wake_event_fd: posix.fd_t,
    wake_event_buffer: []u8,

    // Currently, the batch size is predetermined.
    // You basically define how large you want your batches to be.
    cqes: []linux.io_uring_cqe,
    jobs: pool.Pool(JobBundle),

    const base_flags = blk: {
        var flags = 0;
        // If you are building for musl, you won't have access to these flags.
        // This means you will run with no flags for compatibility reasons.

        // SINGLE_ISSUER requires 6.0
        if (builtin.target.os.isAtLeast(
            .linux,
            .{ .major = 6, .minor = 0, .patch = 0 },
        )) |is_atleast| {
            if (is_atleast) flags |= linux.IORING_SETUP_SINGLE_ISSUER;
        }

        // COOP_TASKRUN requires 5.19
        if (builtin.target.os.isAtLeast(
            .linux,
            .{ .major = 5, .minor = 19, .patch = 0 },
        )) |is_atleast| {
            if (is_atleast) flags |= linux.IORING_SETUP_COOP_TASKRUN;
        }

        break :blk flags;
    };

    pub fn init(allocator: mem.Allocator, options: AsyncIO.Options) (mem.Allocator.Error || Errors.Init)!AsyncIoUring {
        // Extra job for the wake event_fd.
        const size = options.size_tasks_initial + 1;

        const wake_event_fd: posix.fd_t = @intCast(
            linux.eventfd(0, linux.EFD.CLOEXEC),
        );
        errdefer syscall.close(wake_event_fd);

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
                const flags: u32 = base_flags | linux.IORING_SETUP_ATTACH_WQ;
                var params = mem.zeroInit(linux.io_uring_params, .{
                    .flags = flags,
                    .wq_fd = @as(u32, @intCast(parent_uring.inner.fd)),
                });

                const uring = try allocator.create(linux.IoUring);
                errdefer allocator.destroy(uring);

                uring.* = try .init_params(submit_size, &params);
                errdefer uring.deinit();

                break :blk uring;
            } else {
                // Initalize IO Uring
                const uring = try allocator.create(linux.IoUring);
                errdefer allocator.destroy(uring);

                uring.* = try .init(submit_size, base_flags);
                errdefer uring.deinit();

                break :blk uring;
            }
        };
        errdefer allocator.destroy(uring);
        errdefer uring.deinit();

        var jobs: pool.Pool(JobBundle) = try .init(
            allocator,
            size,
            options.pooling,
        );
        errdefer jobs.deinit();

        const index = jobs.borrow_assume_unset(0);
        const item = jobs.get_ptr(index);
        item.job = .{
            .index = index,
            .type = .wake,
            .task = undefined,
        };
        _ = try uring.read(index, wake_event_fd, .{ .buffer = wake_event_buffer }, 0);

        const cqes = try allocator.alloc(linux.io_uring_cqe, options.size_aio_reap_max);
        errdefer allocator.free(cqes);

        return .{
            .inner = uring,
            .allocator = allocator,
            .wake_event_fd = wake_event_fd,
            .wake_event_buffer = wake_event_buffer,
            .jobs = jobs,
            .cqes = cqes,
        };
    }

    pub fn inner_deinit(self: *AsyncIoUring, allocator: mem.Allocator) void {
        syscall.close(self.wake_event_fd);
        self.inner.deinit();
        self.jobs.deinit();
        allocator.free(self.wake_event_buffer);
        allocator.free(self.cqes);
        allocator.destroy(self.inner);
    }

    fn deinit(runner: *anyopaque, allocator: mem.Allocator) void {
        const uring: *AsyncIoUring = @ptrCast(@alignCast(runner));
        uring.inner_deinit(allocator);
    }

    fn queue_job(
        runner: *anyopaque,
        task: usize,
        job: AsyncIO.Submission,
    ) Errors.QueueJob!void {
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
        }) catch |e| switch (e) {
            error.SubmissionQueueFull => {
                try submit(runner);
                try queue_job(runner, task, job);
            },
            else => |err| return err,
        };
    }

    fn queue_timer(self: *AsyncIoUring, task: usize, duration: Io.Duration) Error!void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);
        item.job = .{
            .index = index,
            .task = task,
            .type = .{ .timer = .none },
        };

        // TODO: make copierble types none pointers
        const timespec_ptr = try self.allocator.create(linux.kernel_timespec);
        errdefer self.allocator.destroy(timespec_ptr);

        timespec_ptr.* = .{
            .sec = @intCast(@divFloor(duration.nanoseconds, std.time.ns_per_s)),
            .nsec = @intCast(@mod(duration.nanoseconds, std.time.ns_per_s)),
        };
        item.timespec = timespec_ptr;

        _ = try self.inner.timeout(index, timespec_ptr, 0, 0);
    }

    fn queue_open(
        self: *AsyncIoUring,
        task: usize,
        path: Path,
        flags: AsyncIO.OpenFlags,
    ) Error!void {
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

        const o_flags: linux.O = blk: {
            var o: linux.O = .{};

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
                posix.AT.FDCWD,
                inner.ptr,
                o_flags,
                @intCast(perms),
            ),
        }
    }

    fn queue_delete(self: *AsyncIoUring, task: usize, path: Path, is_dir: bool) Error!void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);
        item.job = .{
            .index = index,
            .type = .{
                .delete = .{
                    .path = path,
                    .is_dir = is_dir,
                },
            },
            .task = task,
        };

        const mode: u32 = if (is_dir) posix.AT.REMOVEDIR else 0;

        switch (path) {
            .rel => |inner| _ = try self.inner.unlinkat(index, inner.dir, inner.path.ptr, mode),
            .abs => |inner| _ = try self.inner.unlinkat(index, posix.AT.FDCWD, inner.ptr, mode),
        }
    }

    fn queue_mkdir(self: *AsyncIoUring, task: usize, path: Path, mode: isize) Error!void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);
        item.job = .{
            .index = index,
            .type = .{
                .mkdir = .{
                    .path = path,
                    .mode = mode,
                },
            },
            .task = task,
        };

        switch (path) {
            .rel => |inner| _ = try self.inner.mkdirat(index, inner.dir, inner.path.ptr, @intCast(mode)),
            .abs => |inner| _ = try self.inner.mkdirat(index, posix.AT.FDCWD, inner.ptr, @intCast(mode)),
        }
    }

    fn queue_stat(self: *AsyncIoUring, task: usize, fd: posix.fd_t) Error!void {
        const index = try self.jobs.borrow_hint(task);
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);
        item.job = .{
            .index = index,
            .type = .{ .stat = fd },
            .task = task,
        };

        const statx_ptr = try self.allocator.create(linux.Statx);
        errdefer self.allocator.destroy(statx_ptr);
        item.statx = statx_ptr;

        _ = try self.inner.statx(
            index,
            fd,
            "",
            linux.AT.EMPTY_PATH,
            linux.STATX.BASIC_STATS,
            statx_ptr,
        );
    }

    fn queue_read(self: *AsyncIoUring, task: usize, fd: posix.fd_t, buffer: []u8, offset: ?usize) Error!void {
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

    fn queue_write(self: *AsyncIoUring, task: usize, fd: posix.fd_t, buffer: []const u8, offset: ?usize) Error!void {
        // If we don't have an offset, set it as -1.
        const real_offset: usize = if (offset) |o| o else @bitCast(@as(isize, -1));

        const index = self.jobs.borrow_hint(task) catch @panic("OOM");
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

    fn queue_close(self: *AsyncIoUring, task: usize, fd: posix.fd_t) Error!void {
        const index = self.jobs.borrow_hint(task) catch @panic("OOM");
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);
        item.job = .{
            .index = index,
            .type = .{ .close = fd },
            .task = task,
        };

        _ = try self.inner.close(index, fd);
    }

    fn queue_accept(self: *AsyncIoUring, task: usize, socket: posix.socket_t, kind: Socket.Kind) Error!void {
        const index = self.jobs.borrow_hint(task) catch @panic("OOM");
        errdefer self.jobs.release(index);

        const item = self.jobs.get_ptr(index);
        item.job = .{
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
        var sockaddr, var socklen = item.job.type.accept.addr.toPosix();

        _ = try self.inner.accept(
            index,
            socket,
            &sockaddr,
            &socklen,
            0,
        );
    }

    fn queue_connect(
        self: *AsyncIoUring,
        task: usize,
        socket: posix.socket_t,
        addr: Socket.Address,
        kind: Socket.Kind,
    ) Error!void {
        const index = self.jobs.borrow_hint(task) catch @panic("OOM");
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
        const sockaddr, const socklen = item.job.type.connect.addr.toPosix();

        _ = try self.inner.connect(
            index,
            socket,
            &sockaddr,
            socklen,
        );
    }

    fn queue_recv(
        self: *AsyncIoUring,
        task: usize,
        socket: posix.socket_t,
        buffer: []u8,
    ) Error!void {
        const index = self.jobs.borrow_hint(task) catch @panic("OOM");
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

    fn queue_send(self: *AsyncIoUring, task: usize, socket: posix.socket_t, buffer: []const u8) Error!void {
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

    inline fn queue_wake(self: *AsyncIoUring) Error!void {
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

    fn wake(runner: *anyopaque) Errors.Wake!void {
        const uring: *AsyncIoUring = @ptrCast(@alignCast(runner));
        const bytes: []const u8 = "00000000";
        var i: usize = 0;
        while (i < bytes.len) i += try syscall.write(uring.wake_event_fd, bytes);
    }

    fn submit(runner: *anyopaque) Errors.Submit!void {
        const uring: *AsyncIoUring = @ptrCast(@alignCast(runner));

        _ = while (true) {
            break uring.inner.submit() catch |e| switch (e) {
                error.SignalInterrupt => continue,
                else => |err| return err,
            };
        };
    }

    fn reap(
        runner: *anyopaque,
        completions: []results.Completion,
        wait: bool,
    ) Errors.Reap![]results.Completion {
        const uring: *AsyncIoUring = @ptrCast(@alignCast(runner));
        // either wait for atleast 1 or just take whats there.
        const uring_nr: u32 = if (wait) 1 else 0;

        const count = while (true) {
            break uring.inner.copy_cqes(uring.cqes[0..], uring_nr) catch |e| {
                switch (e) {
                    error.SignalInterrupt => continue,
                    else => |err| return err,
                }
            };
        };

        for (uring.cqes[0..count], 0..) |cqe, i| {
            var job_with_data: JobBundle = uring.jobs.get(cqe.user_data);
            const job: *Job = &job_with_data.job;
            uring.jobs.release(job.index);

            const result: results.Result = blk: {
                if (cqe.res < 0) {
                    log.debug("{d} - other status on SQE: {t}", .{
                        job.index,
                        @as(linux.E, @enumFromInt(-cqe.res)),
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
                                    .actual = .{
                                        .handle = cqe.res,
                                        .addr = inner.addr,
                                        .kind = inner.kind,
                                    },
                                },
                            },
                            .udp => unreachable,
                        };

                        const AcceptError = results.AcceptError;
                        const result: results.AcceptResult = result: {
                            const e: linux.E = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                .AGAIN => .{ .err = AcceptError.WouldBlock },
                                .BADF => .{ .err = AcceptError.InvalidFd },
                                .CONNABORTED => .{ .err = AcceptError.ConnectionAborted },
                                .FAULT => .{ .err = AcceptError.InvalidAddress },
                                .INVAL => .{ .err = AcceptError.NotListening },
                                .MFILE => .{ .err = AcceptError.ProcessFdQuotaExceeded },
                                .NFILE => .{ .err = AcceptError.SystemFdQuotaExceeded },
                                .NOBUFS, .NOMEM => .{ .err = AcceptError.OutOfMemory },
                                else => .{ .err = AcceptError.Unexpected },
                            };
                        };

                        break :blk .{ .accept = result };
                    },
                    .connect => {
                        if (cqe.res >= 0) break :blk .{
                            .connect = .actual,
                        };
                        const ConnectError = results.ConnectError;
                        const result: results.ConnectResult = result: {
                            const e: linux.E = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                .ACCES, .PERM => .{ .err = ConnectError.AccessDenied },
                                .ADDRINUSE => .{ .err = ConnectError.AddressInUse },
                                .ADDRNOTAVAIL => .{ .err = ConnectError.AddressNotAvailable },
                                .AFNOSUPPORT => .{ .err = ConnectError.AddressFamilyNotSupported },
                                .AGAIN, .ALREADY, .INPROGRESS => .{
                                    .err = ConnectError.WouldBlock,
                                },
                                .BADF => .{ .err = ConnectError.InvalidFd },
                                .CONNREFUSED => .{ .err = ConnectError.ConnectionRefused },
                                .FAULT => .{ .err = ConnectError.InvalidAddress },
                                .ISCONN => .{ .err = ConnectError.AlreadyConnected },
                                .NETUNREACH => .{ .err = ConnectError.NetworkUnreachable },
                                .NOTSOCK => .{ .err = ConnectError.NotASocket },
                                .PROTOTYPE => .{ .err = ConnectError.ProtocolFamilyNotSupported },
                                .TIMEDOUT => .{ .err = ConnectError.TimedOut },
                                else => .{ .err = ConnectError.Unexpected },
                            };
                        };

                        break :blk .{ .connect = result };
                    },
                    .recv => {
                        if (cqe.res > 0) break :blk .{
                            .recv = .{
                                .actual = @intCast(cqe.res),
                            },
                        };

                        const RecvError = results.RecvError;
                        if (cqe.res == 0) break :blk .{ .recv = .{ .err = RecvError.Closed } };

                        const result: results.RecvResult = result: {
                            const e: linux.E = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                .NOTSOCK, .INVAL, .FAULT, .BADF => unreachable,
                                .AGAIN => .{ .err = RecvError.WouldBlock },
                                .CONNRESET => .{ .err = RecvError.Closed },
                                .CONNREFUSED => .{ .err = RecvError.ConnectionRefused },
                                .NOMEM => .{ .err = RecvError.SystemResources },
                                .NOTCONN => .{ .err = RecvError.SocketNotConnected },
                                else => .{ .err = RecvError.Unexpected },
                            };
                        };

                        break :blk .{ .recv = result };
                    },
                    .send => {
                        if (cqe.res >= 0) break :blk .{ .send = .{ .actual = @intCast(cqe.res) } };

                        const SendError = results.SendError;
                        const result: results.SendResult = result: {
                            const e: linux.E = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                .OPNOTSUPP,
                                .FAULT,
                                .NOTCONN,
                                .ISCONN,
                                .INVAL,
                                .DESTADDRREQ,
                                => unreachable,
                                .BADF => .{ .err = SendError.InvalidFd },
                                .ACCES => .{ .err = SendError.AccessDenied },
                                .AGAIN => .{ .err = SendError.WouldBlock },
                                .ALREADY => .{ .err = SendError.FastOpenAlreadyInProgress },
                                .CONNRESET, .PIPE => .{ .err = SendError.Closed },
                                .MSGSIZE => .{ .err = SendError.MessageOversize },
                                .NOBUFS,
                                .NOMEM,
                                => .{
                                    .err = SendError.SystemResources,
                                },
                                else => .{ .err = SendError.Unexpected },
                            };
                        };

                        break :blk .{ .send = result };
                    },
                    .mkdir => {
                        if (cqe.res == 0) break :blk .{ .mkdir = .{ .actual = {} } };

                        const MkdirError = results.MkdirError;
                        const result: results.MkdirResult = result: {
                            const e: linux.E = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                .ACCES => .{ .err = MkdirError.AccessDenied },
                                .EXIST => .{ .err = MkdirError.AlreadyExists },
                                .LOOP, .MLINK => .{ .err = MkdirError.Loop },
                                .NAMETOOLONG => .{ .err = MkdirError.NameTooLong },
                                .NOENT => .{ .err = MkdirError.NotFound },
                                .NOSPC => .{ .err = MkdirError.NoSpace },
                                .NOTDIR => .{ .err = MkdirError.NotADirectory },
                                .ROFS => .{ .err = MkdirError.ReadOnlyFileSystem },
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

                        const OpenError = results.OpenError;
                        const result: results.InnerOpenResult = result: {
                            const e: linux.E = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                .ACCES, .PERM => .{ .err = OpenError.AccessDenied },
                                .BADF => .{ .err = OpenError.InvalidFd },
                                .BUSY => .{ .err = OpenError.Busy },
                                .DQUOT => .{ .err = OpenError.DiskQuotaExceeded },
                                .EXIST => .{ .err = OpenError.AlreadyExists },
                                .FAULT => .{ .err = OpenError.InvalidAddress },
                                .FBIG, .OVERFLOW => .{ .err = OpenError.FileTooBig },
                                .INVAL => .{ .err = OpenError.InvalidArguments },
                                .ISDIR => .{ .err = OpenError.IsDirectory },
                                .LOOP => .{ .err = OpenError.Loop },
                                .MFILE => .{ .err = OpenError.ProcessFdQuotaExceeded },
                                .NAMETOOLONG => .{ .err = OpenError.NameTooLong },
                                .NFILE => .{ .err = OpenError.SystemFdQuotaExceeded },
                                .NODEV, .NXIO => .{ .err = OpenError.DeviceNotFound },
                                .NOENT => .{ .err = OpenError.NotFound },
                                .NOMEM => .{ .err = OpenError.OutOfMemory },
                                .NOSPC => .{ .err = OpenError.NoSpace },
                                .NOTDIR => .{ .err = OpenError.NotADirectory },
                                .OPNOTSUPP => .{ .err = OpenError.OperationNotSupported },
                                .ROFS => .{ .err = OpenError.ReadOnlyFileSystem },
                                .TXTBSY => .{ .err = OpenError.FileLocked },
                                .AGAIN => .{ .err = OpenError.WouldBlock },
                                else => .{ .err = OpenError.Unexpected },
                            };
                        };

                        break :blk .{ .open = result };
                    },
                    .delete => {
                        if (cqe.res == 0) break :blk .{ .delete = .{ .actual = {} } };

                        const DeleteError = results.DeleteError;
                        const result: results.DeleteResult = result: {
                            const e: linux.E = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                // unlink
                                .ACCES => .{ .err = DeleteError.AccessDenied },
                                .BUSY => .{ .err = DeleteError.Busy },
                                .FAULT => .{ .err = DeleteError.InvalidAddress },
                                .IO => .{ .err = DeleteError.IoError },
                                .ISDIR, .PERM => .{ .err = DeleteError.IsDirectory },
                                .LOOP => .{ .err = DeleteError.Loop },
                                .NAMETOOLONG => .{ .err = DeleteError.NameTooLong },
                                .NOENT => .{ .err = DeleteError.NotFound },
                                .NOMEM => .{ .err = DeleteError.OutOfMemory },
                                .NOTDIR => .{ .err = DeleteError.IsNotDirectory },
                                .ROFS => .{ .err = DeleteError.ReadOnlyFileSystem },
                                .BADF => .{ .err = DeleteError.InvalidFd },
                                // rmdir
                                .INVAL => .{ .err = DeleteError.InvalidArguments },
                                .NOTEMPTY => .{ .err = DeleteError.NotEmpty },
                                else => .{ .err = DeleteError.Unexpected },
                            };
                        };

                        break :blk .{ .delete = result };
                    },
                    .read => {
                        if (cqe.res > 0) break :blk .{
                            .read = .{
                                .actual = @intCast(cqe.res),
                            },
                        };
                        const ReadError = results.ReadError;
                        if (cqe.res == 0) break :blk .{
                            .read = .{
                                .err = ReadError.EndOfFile,
                            },
                        };

                        const result: results.ReadResult = result: {
                            const e: linux.E = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                .AGAIN => .{ .err = ReadError.WouldBlock },
                                .BADF => .{ .err = ReadError.InvalidFd },
                                .FAULT => .{ .err = ReadError.InvalidAddress },
                                .INVAL => .{ .err = ReadError.InvalidArguments },
                                .IO => .{ .err = ReadError.IoError },
                                .ISDIR => .{ .err = ReadError.IsDirectory },
                                else => .{ .err = ReadError.Unexpected },
                            };
                        };

                        break :blk .{ .read = result };
                    },
                    .write => {
                        if (cqe.res > 0) break :blk .{ .write = .{ .actual = @intCast(cqe.res) } };

                        const WriteError = results.WriteError;
                        const result: results.WriteResult = result: {
                            const e: linux.E = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                .INVAL => unreachable,
                                .AGAIN => .{ .err = WriteError.WouldBlock },
                                .BADF => .{ .err = WriteError.InvalidFd },
                                .DESTADDRREQ => .{ .err = WriteError.NoDestinationAddress },
                                .DQUOT => .{ .err = WriteError.DiskQuotaExceeded },
                                .FAULT => .{ .err = WriteError.InvalidAddress },
                                .FBIG => .{ .err = WriteError.FileTooBig },
                                .IO => .{ .err = WriteError.IoError },
                                .NOSPC => .{ .err = WriteError.NoSpace },
                                .PERM => .{ .err = WriteError.AccessDenied },
                                .PIPE => .{ .err = WriteError.BrokenPipe },
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
                                .size = statx.size,
                                .mode = statx.mode,
                                .accessed = .{
                                    .nanoseconds = (statx.atime.sec * std.time.ns_per_s) + statx.atime.nsec,
                                },
                                .modified = .{
                                    .nanoseconds = (statx.mtime.sec * std.time.ns_per_s) + statx.mtime.nsec,
                                },
                                .changed = .{
                                    .nanoseconds = (statx.ctime.sec * std.time.ns_per_s) + statx.ctime.nsec,
                                },
                            };
                            break :blk .{ .stat = .{ .actual = stat } };
                        }

                        const StatError = results.StatError;
                        const result: results.StatResult = result: {
                            const e: linux.E = @enumFromInt(-cqe.res);
                            break :result switch (e) {
                                .ACCES => .{ .err = StatError.AccessDenied },
                                .BADF => .{ .err = StatError.InvalidFd },
                                .FAULT => .{ .err = StatError.InvalidAddress },
                                .INVAL => .{ .err = StatError.InvalidArguments },
                                .LOOP => .{ .err = StatError.Loop },
                                .NAMETOOLONG => .{ .err = StatError.NameTooLong },
                                .NOENT => .{ .err = StatError.NotFound },
                                .NOMEM => .{ .err = StatError.OutOfMemory },
                                .NOTDIR => .{ .err = StatError.NotADirectory },
                                else => .{ .err = StatError.Unexpected },
                            };
                        };

                        break :blk .{ .stat = result };
                    },
                }
            };

            completions[i] = .{
                .result = result,
                .task = job.task,
            };
        }

        return completions[0..count];
    }

    pub fn to_async(self: *AsyncIoUring) AsyncIO {
        return .{
            .runner = self,
            .features = .all(),
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
