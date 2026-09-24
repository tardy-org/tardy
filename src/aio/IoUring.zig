pub const IoUring = @This();

uring: *linux.IoUring,
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

pub fn init(gpa: mem.Allocator, options: AsyncIO.Options) (OoM || Errors.Init)!IoUring {
    // Extra job for the wake event_fd.
    const size = options.initial_task_size + 1;

    const wake_event_fd: posix.fd_t = @intCast(
        linux.eventfd(0, linux.EFD.CLOEXEC),
    );
    errdefer syscall.close(wake_event_fd);

    const wake_event_buffer = try gpa.alloc(u8, 8);
    errdefer gpa.free(wake_event_buffer);

    const submit_size: u16 = @min(
        // 4096 is the max uring submit size.
        4096,
        math.ceilPowerOfTwo(
            u16,
            @intCast(options.aio_reap_size_max),
        ) catch 4096,
    );

    const uring = blk: {
        if (options.parent_async) |parent| {
            const parent_uring: *IoUring = @ptrCast(
                @alignCast(parent.runner),
            );
            debug.assert(parent_uring.uring.fd >= 0);

            // Initialize using the WQ from the parent ring.
            const flags: u32 = base_flags | linux.IORING_SETUP_ATTACH_WQ;
            var params = mem.zeroInit(
                linux.io_uring_params,
                .{
                    .flags = flags,
                    .wq_fd = @as(u32, @intCast(parent_uring.uring.fd)),
                },
            );

            const uring = try gpa.create(linux.IoUring);
            errdefer gpa.destroy(uring);

            uring.* = try .init_params(submit_size, &params);
            errdefer uring.deinit();

            break :blk uring;
        } else {
            // Initalize IO Uring
            const uring = try gpa.create(linux.IoUring);
            errdefer gpa.destroy(uring);

            uring.* = try .init(submit_size, base_flags);
            errdefer uring.deinit();

            break :blk uring;
        }
    };
    errdefer gpa.destroy(uring);
    errdefer uring.deinit();

    var jobs: pool.Pool(JobBundle) = try .init(
        gpa,
        size,
        options.pooling,
    );
    errdefer jobs.deinit(gpa);

    const job_index = jobs.borrow_assume_unset(0);
    const item = jobs.get_ptr(job_index);
    item.job = .{
        .job_index = job_index,
        .type = .wake,
        .task_index = undefined,
    };
    _ = try uring.read(
        job_index,
        wake_event_fd,
        .{ .buffer = wake_event_buffer },
        0,
    );

    const cqes = try gpa.alloc(
        linux.io_uring_cqe,
        options.aio_reap_size_max,
    );
    errdefer gpa.free(cqes);

    return .{
        .uring = uring,
        .wake_event_fd = wake_event_fd,
        .wake_event_buffer = wake_event_buffer,
        .jobs = jobs,
        .cqes = cqes,
    };
}

pub fn inner_deinit(io_uring: *IoUring, gpa: mem.Allocator) void {
    syscall.close(io_uring.wake_event_fd);
    io_uring.uring.deinit();
    io_uring.jobs.deinit(gpa);
    gpa.free(io_uring.wake_event_buffer);
    gpa.free(io_uring.cqes);
    gpa.destroy(io_uring.uring);
}

fn deinit(runner: *anyopaque, gpa: mem.Allocator) void {
    const uring: *IoUring = @ptrCast(@alignCast(runner));
    uring.inner_deinit(gpa);
}

fn queue_job(
    runner: *anyopaque,
    gpa: mem.Allocator,
    task_index: usize,
    job: AsyncIO.Submission,
) Errors.QueueJob!void {
    const uring: *IoUring = @ptrCast(@alignCast(runner));
    (switch (job) {
        .timer => |timer| uring.queue_timer(
            gpa,
            task_index,
            timer,
        ),
        .open => |open| uring.queue_open(
            gpa,
            task_index,
            open.path,
            open.flags,
        ),
        .delete => |delete| uring.queue_delete(
            gpa,
            task_index,
            delete.path,
            delete.is_dir,
        ),
        .mkdir => |mkdir| uring.queue_mkdir(
            gpa,
            task_index,
            mkdir.path,
            mkdir.mode,
        ),
        .stat => |stat| uring.queue_stat(
            gpa,
            task_index,
            stat,
        ),
        .read => |read| uring.queue_read(
            gpa,
            task_index,
            read.fd,
            read.buffer,
            read.offset,
        ),
        .write => |write| uring.queue_write(
            gpa,
            task_index,
            write.fd,
            write.buffer,
            write.offset,
        ),
        .close => |close| uring.queue_close(
            gpa,
            task_index,
            close,
        ),
        .accept => |accept| uring.queue_accept(
            gpa,
            task_index,
            accept.socket,
        ),
        .connect => |connect| uring.queue_connect(
            gpa,
            task_index,
            connect.socket,
        ),
        .recv => |recv| uring.queue_recv(
            gpa,
            task_index,
            recv.socket,
            recv.buffer,
        ),
        .send => |send| uring.queue_send(
            gpa,
            task_index,
            send.socket,
            send.buffer,
        ),
    }) catch |err| switch (err) {
        error.SubmissionQueueFull => {
            try submit(runner);
            try queue_job(runner, gpa, task_index, job);
        },
        else => |e| return e,
    };
}

fn queue_timer(
    io_uring: *IoUring,
    gpa: mem.Allocator,
    task_index: usize,
    duration: Io.Duration,
) Errors.Timer!void {
    const job_index = try io_uring.jobs.borrow_hint(gpa, task_index);
    errdefer io_uring.jobs.release(job_index);

    const item = io_uring.jobs.get_ptr(job_index);
    item.job = .{
        .job_index = job_index,
        .task_index = task_index,
        .type = .{ .timer = .none },
    };

    // TODO: make copierble types none pointers
    const timespec_ptr = try gpa.create(linux.kernel_timespec);
    errdefer gpa.destroy(timespec_ptr);

    timespec_ptr.* = .{
        .sec = @intCast(@divFloor(duration.nanoseconds, std.time.ns_per_s)),
        .nsec = @intCast(@mod(duration.nanoseconds, std.time.ns_per_s)),
    };
    item.timespec = timespec_ptr;

    _ = try io_uring.uring.timeout(
        job_index,
        timespec_ptr,
        0,
        0,
    );
}

fn queue_open(
    io_uring: *IoUring,
    gpa: mem.Allocator,
    task_index: usize,
    path: fs.Path,
    flags: AsyncIO.OpenFlags,
) Errors.Open!void {
    const job_index = try io_uring.jobs.borrow_hint(gpa, task_index);
    errdefer io_uring.jobs.release(job_index);

    const item = io_uring.jobs.get_ptr(job_index);
    item.job = .{
        .job_index = job_index,
        .type = .{
            .open = .{
                .path = path,
                .kind = if (flags.directory) .dir else .file,
                .flags = flags,
            },
        },
        .task_index = task_index,
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
        .rel => |rel| _ = try io_uring.uring.openat(
            job_index,
            rel.dir,
            rel.path.ptr,
            o_flags,
            @intCast(perms),
        ),
        .abs => |abs| _ = try io_uring.uring.openat(
            job_index,
            posix.AT.FDCWD,
            abs.ptr,
            o_flags,
            @intCast(perms),
        ),
    }
}

fn queue_delete(
    io_uring: *IoUring,
    gpa: mem.Allocator,
    task_index: usize,
    path: fs.Path,
    is_dir: bool,
) Errors.Delete!void {
    const job_index = try io_uring.jobs.borrow_hint(gpa, task_index);
    errdefer io_uring.jobs.release(job_index);

    const item = io_uring.jobs.get_ptr(job_index);
    item.job = .{
        .job_index = job_index,
        .type = .{
            .delete = .{
                .path = path,
                .is_dir = is_dir,
            },
        },
        .task_index = task_index,
    };

    const mode: u32 = if (is_dir) posix.AT.REMOVEDIR else 0;

    switch (path) {
        .rel => |rel| _ = try io_uring.uring.unlinkat(
            job_index,
            rel.dir,
            rel.path.ptr,
            mode,
        ),
        .abs => |abs| _ = try io_uring.uring.unlinkat(
            job_index,
            posix.AT.FDCWD,
            abs.ptr,
            mode,
        ),
    }
}

fn queue_mkdir(
    io_uring: *IoUring,
    gpa: mem.Allocator,
    task_index: usize,
    path: fs.Path,
    mode: isize,
) Errors.Mkdir!void {
    const job_index = try io_uring.jobs.borrow_hint(gpa, task_index);
    errdefer io_uring.jobs.release(job_index);

    const item = io_uring.jobs.get_ptr(job_index);
    item.job = .{
        .job_index = job_index,
        .type = .{
            .mkdir = .{
                .path = path,
                .mode = mode,
            },
        },
        .task_index = task_index,
    };

    switch (path) {
        .rel => |rel| _ = try io_uring.uring.mkdirat(
            job_index,
            rel.dir,
            rel.path.ptr,
            @intCast(mode),
        ),
        .abs => |abs| _ = try io_uring.uring.mkdirat(
            job_index,
            posix.AT.FDCWD,
            abs.ptr,
            @intCast(mode),
        ),
    }
}

fn queue_stat(
    io_uring: *IoUring,
    gpa: mem.Allocator,
    task_index: usize,
    fd: posix.fd_t,
) Errors.Stat!void {
    const job_index = try io_uring.jobs.borrow_hint(gpa, task_index);
    errdefer io_uring.jobs.release(job_index);

    const item = io_uring.jobs.get_ptr(job_index);
    item.job = .{
        .job_index = job_index,
        .type = .{ .stat = fd },
        .task_index = task_index,
    };

    const statx_ptr = try gpa.create(linux.Statx);
    errdefer gpa.destroy(statx_ptr);
    item.statx = statx_ptr;

    _ = try io_uring.uring.statx(
        job_index,
        fd,
        "",
        linux.AT.EMPTY_PATH,
        linux.STATX.BASIC_STATS,
        statx_ptr,
    );
}

fn queue_read(
    io_uring: *IoUring,
    gpa: mem.Allocator,
    task_index: usize,
    fd: posix.fd_t,
    buffer: []u8,
    offset: ?usize,
) Errors.Read!void {
    const job_index = try io_uring.jobs.borrow_hint(gpa, task_index);
    errdefer io_uring.jobs.release(job_index);

    // If we don't have an offset, set it as -1.
    const real_offset: usize = if (offset) |o| o else @bitCast(@as(isize, -1));

    const item = io_uring.jobs.get_ptr(job_index);
    item.job = .{
        .job_index = job_index,
        .type = .{
            .read = .{
                .fd = fd,
                .buffer = buffer,
                .offset = real_offset,
            },
        },
        .task_index = task_index,
    };

    _ = try io_uring.uring.read(
        job_index,
        fd,
        .{ .buffer = buffer },
        real_offset,
    );
}

fn queue_write(
    io_uring: *IoUring,
    gpa: mem.Allocator,
    task_index: usize,
    fd: posix.fd_t,
    buffer: []const u8,
    offset: ?usize,
) Errors.Write!void {
    const job_index = io_uring.jobs.borrow_hint(
        gpa,
        task_index,
    ) catch @panic("OOM");
    errdefer io_uring.jobs.release(job_index);

    // If we don't have an offset, set it as -1.
    const real_offset: usize = if (offset) |o| o else @bitCast(@as(isize, -1));

    const item = io_uring.jobs.get_ptr(job_index);
    item.job = .{
        .job_index = job_index,
        .type = .{
            .write = .{
                .fd = fd,
                .buffer = buffer,
                .offset = real_offset,
            },
        },
        .task_index = task_index,
    };

    _ = try io_uring.uring.write(
        job_index,
        fd,
        buffer,
        real_offset,
    );
}

fn queue_close(
    io_uring: *IoUring,
    gpa: mem.Allocator,
    task_index: usize,
    fd: posix.fd_t,
) Errors.Close!void {
    const job_index = io_uring.jobs.borrow_hint(
        gpa,
        task_index,
    ) catch @panic("OoM");
    errdefer io_uring.jobs.release(job_index);

    const item = io_uring.jobs.get_ptr(job_index);
    item.job = .{
        .job_index = job_index,
        .type = .{ .close = fd },
        .task_index = task_index,
    };

    _ = try io_uring.uring.close(job_index, fd);
}

fn queue_accept(
    io_uring: *IoUring,
    gpa: mem.Allocator,
    task_index: usize,
    socket: *const net.Socket,
) Errors.Accept!void {
    const job_index = io_uring.jobs.borrow_hint(
        gpa,
        task_index,
    ) catch @panic("OoM");
    errdefer io_uring.jobs.release(job_index);

    var client: net.Socket.Address = .init(socket.addr.family());

    _ = try io_uring.uring.accept(
        job_index,
        socket.handle,
        &client.any,
        &client.len,
        0,
    );

    const item = io_uring.jobs.get_ptr(job_index);
    item.job = .{
        .job_index = job_index,
        .type = .{
            .accept = .{
                .socket = .{
                    .handle = math.maxInt(net.Socket.Handle),
                    .addr = client,
                    .kind = socket.kind,
                },
            },
        },
        .task_index = task_index,
    };
}

fn queue_connect(
    io_uring: *IoUring,
    gpa: mem.Allocator,
    task_index: usize,
    socket: *const net.Socket,
) Errors.Connect!void {
    const job_index = io_uring.jobs.borrow_hint(
        gpa,
        task_index,
    ) catch @panic("OoM");
    errdefer io_uring.jobs.release(job_index);

    const item = io_uring.jobs.get_ptr(job_index);
    item.job = .{
        .job_index = job_index,
        .type = .{
            .connect = .{ .socket = socket },
        },
        .task_index = task_index,
    };

    const addr = item.job.type.connect.socket.addr;
    _ = try io_uring.uring.connect(
        job_index,
        socket.handle,
        &addr.any,
        addr.len,
    );
}

fn queue_recv(
    io_uring: *IoUring,
    gpa: mem.Allocator,
    task_index: usize,
    socket: posix.socket_t,
    buffer: []u8,
) Errors.Recv!void {
    const job_index = io_uring.jobs.borrow_hint(
        gpa,
        task_index,
    ) catch @panic("OOM");
    errdefer io_uring.jobs.release(job_index);

    const item = io_uring.jobs.get_ptr(job_index);
    item.job = .{
        .job_index = job_index,
        .type = .{
            .recv = .{
                .socket = socket,
                .buffer = buffer,
            },
        },
        .task_index = task_index,
    };

    // IoUring is already async so if MSG.DONTWAIT is set, io_uring fail with -EAGAIN
    // immediately when bytes aren't available on the socket to be received instead of
    // automatically kernel polling for readiness. So if used then we have to manually
    // requeue and resubmit the I/O request in reap without DONTWAIT
    _ = try io_uring.uring.recv(
        job_index,
        socket,
        .{ .buffer = buffer },
        0,
    );
}

fn queue_send(
    io_uring: *IoUring,
    gpa: mem.Allocator,
    task_index: usize,
    socket: posix.socket_t,
    buffer: []const u8,
) Errors.Send!void {
    const job_index = try io_uring.jobs.borrow_hint(gpa, task_index);
    errdefer io_uring.jobs.release(job_index);

    const item = io_uring.jobs.get_ptr(job_index);
    item.job = .{
        .job_index = job_index,
        .type = .{
            .send = .{
                .socket = socket,
                .buffer = buffer,
            },
        },
        .task_index = task_index,
    };

    _ = try io_uring.uring.send(
        job_index,
        socket,
        buffer,
        0,
    );
}

fn queue_wake(io_uring: *IoUring, gpa: mem.Allocator) Errors.Wake!void {
    const job_index = try io_uring.jobs.borrow(gpa);
    errdefer io_uring.jobs.release(job_index);

    if (io_uring.wake_event_fd == cross.fd.INVALID_FD) return;

    const item = io_uring.jobs.get_ptr(job_index);
    item.job = .{
        .job_index = job_index,
        .type = .wake,
        .task_index = undefined,
    };

    _ = try io_uring.uring.read(
        job_index,
        io_uring.wake_event_fd,
        .{ .buffer = io_uring.wake_event_buffer },
        0,
    );
}

fn wake(runner: *anyopaque) syscall.Errors.Write!void {
    const uring: *IoUring = @ptrCast(@alignCast(runner));
    const bytes: []const u8 = "00000000";

    var i: usize = 0;
    while (i < bytes.len) i += try syscall.write(
        uring.wake_event_fd,
        bytes[i..],
    );
}

fn submit(runner: *anyopaque) Errors.Submit!void {
    const uring: *IoUring = @ptrCast(@alignCast(runner));

    _ = while (true) {
        break uring.uring.submit() catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => |e| return e,
        };
    };
}

fn reap(
    runner: *anyopaque,
    gpa: mem.Allocator,
    completions: []results.Completion,
    wait: bool,
) Errors.Reap![]results.Completion {
    const uring: *IoUring = @ptrCast(@alignCast(runner));
    // either wait for atleast 1 or just take whats there.
    const uring_nr: u32 = if (wait) 1 else 0;

    const count = while (true) {
        break uring.uring.copy_cqes(uring.cqes[0..], uring_nr) catch |err|
            switch (err) {
                error.SignalInterrupt => continue,
                else => |e| return e,
            };
    };

    for (uring.cqes[0..count], 0..) |cqe, cqe_index| {
        var job_with_data: JobBundle = uring.jobs.get(cqe.user_data);
        const job: *Job = &job_with_data.job;
        uring.jobs.release(job.job_index);

        const result: results.Result = blk: {
            if (cqe.res < 0) {
                log.debug("{d} - task={t} has error status on SQE: {t}", .{
                    job.job_index,
                    job.type,
                    @as(linux.E, @fromBackingInt(@intCast(-cqe.res))),
                });
            }
            switch (job.type) {
                .wake => {
                    // requeue a wake I/O
                    try uring.queue_wake(gpa);
                    break :blk .wake;
                },
                .timer => {
                    defer gpa.destroy(job_with_data.timespec);
                    break :blk .none;
                },
                .close => break :blk .close,
                .accept => |accept| {
                    if (cqe.res >= 0) log.debug(
                        "new accept client_fd is {} with address ({f})",
                        .{ cqe.res, accept.socket.addr },
                    );

                    switch (accept.socket.kind) {
                        .tcp, .unix => break :blk .{
                            .accept = .{
                                .actual = .{
                                    .handle = cqe.res,
                                    .addr = accept.socket.addr,
                                    .kind = accept.socket.kind,
                                },
                            },
                        },
                        .udp => unreachable,
                    }

                    const result: results.Results.Accept = result: {
                        const err: linux.E = @fromBackingInt(@intCast(-cqe.res));
                        break :result switch (err) {
                            .AGAIN => .{
                                .err = error.WouldBlock,
                            },
                            .BADF => .{
                                .err = error.InvalidFd,
                            },
                            .CONNABORTED => .{
                                .err = error.ConnectionAborted,
                            },
                            .FAULT => .{
                                .err = error.InvalidAddress,
                            },
                            .INVAL => .{
                                .err = error.NotListening,
                            },
                            .MFILE => .{
                                .err = error.ProcessFdQuotaExceeded,
                            },
                            .NFILE => .{
                                .err = error.SystemFdQuotaExceeded,
                            },
                            .NOBUFS, .NOMEM => .{
                                .err = error.OutOfMemory,
                            },
                            else => .{
                                .err = error.Unexpected,
                            },
                        };
                    };

                    break :blk .{ .accept = result };
                },
                .connect => {
                    if (cqe.res == 0) break :blk .{
                        .connect = .actual,
                    };

                    const result: results.Results.Connect = result: {
                        const err: linux.E = @fromBackingInt(@intCast(-cqe.res));
                        break :result switch (err) {
                            .ACCES, .PERM => .{
                                .err = error.AccessDenied,
                            },
                            .ADDRINUSE => .{
                                .err = error.AddressInUse,
                            },
                            .ADDRNOTAVAIL => .{
                                .err = error.AddressNotAvailable,
                            },
                            .AFNOSUPPORT => .{
                                .err = error.AddressFamilyNotSupported,
                            },
                            .AGAIN, .ALREADY, .INPROGRESS => .{
                                .err = error.WouldBlock,
                            },
                            .BADF => .{
                                .err = error.InvalidFd,
                            },
                            .CONNREFUSED => .{
                                .err = error.ConnectionRefused,
                            },
                            .FAULT => .{
                                .err = error.InvalidAddress,
                            },
                            .ISCONN => .{
                                .err = error.AlreadyConnected,
                            },
                            .NETUNREACH => .{
                                .err = error.NetworkUnreachable,
                            },
                            .NOTSOCK => .{
                                .err = error.NotASocket,
                            },
                            .PROTOTYPE => .{
                                .err = error.ProtocolFamilyNotSupported,
                            },
                            .TIMEDOUT => .{
                                .err = error.TimedOut,
                            },
                            else => .{
                                .err = error.Unexpected,
                            },
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

                    if (cqe.res == 0) break :blk .{ .recv = .{ .err = error.Closed } };

                    const result: results.Results.Recv = result: {
                        const err: linux.E = @fromBackingInt(@intCast(-cqe.res));
                        break :result switch (err) {
                            .NOTSOCK, .INVAL, .FAULT, .BADF => unreachable,
                            .AGAIN => .{
                                .err = error.WouldBlock,
                            },
                            .CONNRESET => .{
                                .err = error.Closed,
                            },
                            .CONNREFUSED => .{
                                .err = error.ConnectionRefused,
                            },
                            .NOMEM => .{
                                .err = error.SystemResources,
                            },
                            .NOTCONN => .{
                                .err = error.SocketNotConnected,
                            },
                            else => .{
                                .err = error.Unexpected,
                            },
                        };
                    };

                    break :blk .{ .recv = result };
                },
                .send => {
                    if (cqe.res >= 0) break :blk .{ .send = .{ .actual = @intCast(cqe.res) } };

                    const result: results.Results.Send = result: {
                        const err: linux.E = @fromBackingInt(@intCast(-cqe.res));
                        break :result switch (err) {
                            .OPNOTSUPP,
                            .FAULT,
                            .NOTCONN,
                            .ISCONN,
                            .INVAL,
                            .DESTADDRREQ,
                            => unreachable,
                            .BADF => .{
                                .err = error.InvalidFd,
                            },
                            .ACCES => .{
                                .err = error.AccessDenied,
                            },
                            .AGAIN => .{
                                .err = error.WouldBlock,
                            },
                            .ALREADY => .{
                                .err = error.FastOpenAlreadyInProgress,
                            },
                            .CONNRESET, .PIPE => .{
                                .err = error.Closed,
                            },
                            .MSGSIZE => .{
                                .err = error.MessageOversize,
                            },
                            .NOBUFS,
                            .NOMEM,
                            => .{
                                .err = error.SystemResources,
                            },
                            else => .{
                                .err = error.Unexpected,
                            },
                        };
                    };

                    break :blk .{ .send = result };
                },
                .mkdir => {
                    if (cqe.res == 0) break :blk .{
                        .mkdir = .{ .actual = {} },
                    };

                    const result: results.Results.Mkdir = result: {
                        const err: linux.E = @fromBackingInt(@intCast(-cqe.res));
                        break :result switch (err) {
                            .ACCES => .{
                                .err = error.AccessDenied,
                            },
                            .EXIST => .{
                                .err = error.AlreadyExists,
                            },
                            .LOOP, .MLINK => .{
                                .err = error.Loop,
                            },
                            .NAMETOOLONG => .{
                                .err = error.NameTooLong,
                            },
                            .NOENT => .{
                                .err = error.NotFound,
                            },
                            .NOSPC => .{
                                .err = error.NoSpace,
                            },
                            .NOTDIR => .{
                                .err = error.NotADirectory,
                            },
                            .ROFS => .{
                                .err = error.ReadOnlyFileSystem,
                            },
                            else => .{
                                .err = error.Unexpected,
                            },
                        };
                    };

                    break :blk .{ .mkdir = result };
                },
                .open => |open| {
                    if (cqe.res >= 0) switch (open.kind) {
                        .file => break :blk .{
                            .open = .{
                                .actual = .{ .file = .{
                                    .handle = @intCast(cqe.res),
                                } },
                            },
                        },
                        .dir => break :blk .{
                            .open = .{
                                .actual = .{ .dir = .{
                                    .handle = @intCast(cqe.res),
                                } },
                            },
                        },
                    };

                    const result: results.Results.Open = result: {
                        const err: linux.E = @fromBackingInt(@intCast(-cqe.res));
                        break :result switch (err) {
                            .ACCES, .PERM => .{
                                .err = error.AccessDenied,
                            },
                            .BADF => .{
                                .err = error.InvalidFd,
                            },
                            .BUSY => .{
                                .err = error.Busy,
                            },
                            .DQUOT => .{
                                .err = error.DiskQuotaExceeded,
                            },
                            .EXIST => .{
                                .err = error.AlreadyExists,
                            },
                            .FAULT => .{
                                .err = error.InvalidAddress,
                            },
                            .FBIG, .OVERFLOW => .{
                                .err = error.FileTooBig,
                            },
                            .INVAL => .{
                                .err = error.InvalidArguments,
                            },
                            .ISDIR => .{
                                .err = error.IsDirectory,
                            },
                            .LOOP => .{
                                .err = error.Loop,
                            },
                            .MFILE => .{
                                .err = error.ProcessFdQuotaExceeded,
                            },
                            .NAMETOOLONG => .{
                                .err = error.NameTooLong,
                            },
                            .NFILE => .{
                                .err = error.SystemFdQuotaExceeded,
                            },
                            .NODEV, .NXIO => .{
                                .err = error.DeviceNotFound,
                            },
                            .NOENT => .{
                                .err = error.NotFound,
                            },
                            .NOMEM => .{
                                .err = error.OutOfMemory,
                            },
                            .NOSPC => .{
                                .err = error.NoSpace,
                            },
                            .NOTDIR => .{
                                .err = error.NotADirectory,
                            },
                            .OPNOTSUPP => .{
                                .err = error.OperationNotSupported,
                            },
                            .ROFS => .{
                                .err = error.ReadOnlyFileSystem,
                            },
                            .TXTBSY => .{
                                .err = error.FileLocked,
                            },
                            .AGAIN => .{
                                .err = error.WouldBlock,
                            },
                            else => .{
                                .err = error.Unexpected,
                            },
                        };
                    };

                    break :blk .{
                        .open = result,
                    };
                },
                .delete => {
                    if (cqe.res == 0) break :blk .{
                        .delete = .{ .actual = {} },
                    };

                    const result: results.Results.Delete = result: {
                        const err: linux.E = @fromBackingInt(@intCast(-cqe.res));
                        break :result switch (err) {
                            // unlink
                            .ACCES => .{
                                .err = error.AccessDenied,
                            },
                            .BUSY => .{
                                .err = error.Busy,
                            },
                            .FAULT => .{
                                .err = error.InvalidAddress,
                            },
                            .IO => .{
                                .err = error.IoError,
                            },
                            .ISDIR, .PERM => .{
                                .err = error.IsDirectory,
                            },
                            .LOOP => .{
                                .err = error.Loop,
                            },
                            .NAMETOOLONG => .{
                                .err = error.NameTooLong,
                            },
                            .NOENT => .{
                                .err = error.NotFound,
                            },
                            .NOMEM => .{
                                .err = error.OutOfMemory,
                            },
                            .NOTDIR => .{
                                .err = error.IsNotDirectory,
                            },
                            .ROFS => .{
                                .err = error.ReadOnlyFileSystem,
                            },
                            .BADF => .{
                                .err = error.InvalidFd,
                            },
                            // rmdir
                            .INVAL => .{
                                .err = error.InvalidArguments,
                            },
                            .NOTEMPTY => .{
                                .err = error.NotEmpty,
                            },
                            else => .{
                                .err = error.Unexpected,
                            },
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
                    if (cqe.res == 0) break :blk .{
                        .read = .{
                            .err = error.EndOfFile,
                        },
                    };

                    const result: results.Results.Read = result: {
                        const err: linux.E = @fromBackingInt(@intCast(-cqe.res));
                        break :result switch (err) {
                            .AGAIN => .{
                                .err = error.WouldBlock,
                            },
                            .BADF => .{
                                .err = error.InvalidFd,
                            },
                            .FAULT => .{
                                .err = error.InvalidAddress,
                            },
                            .INVAL => .{
                                .err = error.InvalidArguments,
                            },
                            .IO => .{
                                .err = error.IoError,
                            },
                            .ISDIR => .{
                                .err = error.IsDirectory,
                            },
                            else => .{
                                .err = error.Unexpected,
                            },
                        };
                    };

                    break :blk .{ .read = result };
                },
                .write => {
                    if (cqe.res > 0) break :blk .{
                        .write = .{
                            .actual = @intCast(cqe.res),
                        },
                    };

                    const result: results.Results.Write = result: {
                        const err: linux.E = @fromBackingInt(@intCast(-cqe.res));
                        break :result switch (err) {
                            .INVAL => unreachable,
                            .AGAIN => .{
                                .err = error.WouldBlock,
                            },
                            .BADF => .{
                                .err = error.InvalidFd,
                            },
                            .DESTADDRREQ => .{
                                .err = error.NoDestinationAddress,
                            },
                            .DQUOT => .{
                                .err = error.DiskQuotaExceeded,
                            },
                            .FAULT => .{
                                .err = error.InvalidAddress,
                            },
                            .FBIG => .{
                                .err = error.FileTooBig,
                            },
                            .IO => .{
                                .err = error.IoError,
                            },
                            .NOSPC => .{
                                .err = error.NoSpace,
                            },
                            .PERM => .{
                                .err = error.AccessDenied,
                            },
                            .PIPE => .{
                                .err = error.BrokenPipe,
                            },
                            else => .{
                                .err = error.Unexpected,
                            },
                        };
                    };

                    break :blk .{ .write = result };
                },
                .stat => {
                    defer gpa.destroy(job_with_data.statx);

                    if (cqe.res == 0) {
                        const statx = job_with_data.statx;
                        const stat: fs.Stat = .{
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
                        break :blk .{ .stat = .{
                            .actual = stat,
                        } };
                    }

                    const result: results.Results.Stat = result: {
                        const err: linux.E = @fromBackingInt(@intCast(-cqe.res));
                        break :result switch (err) {
                            .ACCES => .{
                                .err = error.AccessDenied,
                            },
                            .BADF => .{
                                .err = error.InvalidFd,
                            },
                            .FAULT => .{
                                .err = error.InvalidAddress,
                            },
                            .INVAL => .{
                                .err = error.InvalidArguments,
                            },
                            .LOOP => .{
                                .err = error.Loop,
                            },
                            .NAMETOOLONG => .{
                                .err = error.NameTooLong,
                            },
                            .NOENT => .{
                                .err = error.NotFound,
                            },
                            .NOMEM => .{
                                .err = error.OutOfMemory,
                            },
                            .NOTDIR => .{
                                .err = error.NotADirectory,
                            },
                            else => .{
                                .err = error.Unexpected,
                            },
                        };
                    };

                    break :blk .{ .stat = result };
                },
            }
        };

        completions[cqe_index] = .{
            .result = result,
            .task_index = job.task_index,
        };
    }

    return completions[0..count];
}

pub fn to_async(io_uring: *IoUring) AsyncIO {
    return .{
        .runner = io_uring,
        .features = .all(),
        .vtable = &.{
            .queue_job = queue_job,
            .deinit = deinit,
            .wake = wake,
            .submit = submit,
            .reap = reap,
        },
    };
}

pub const Errors = struct {
    const Error = error{SubmissionQueueFull} || pool.Error;

    pub const Reap = Submit || Error;
    pub const QueueJob = Error || Submit;
    pub const Wake = Error;
    pub const Delete = Error;
    pub const Stat = Error;
    pub const Connect = Error;
    pub const Accept = Error;
    pub const Recv = Error;
    pub const Send = Error;
    pub const Timer = Error;
    pub const Open = Error;
    pub const Mkdir = Error;
    pub const Read = Error;
    pub const Write = Error;
    pub const Close = Error;

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
        // The kernel believes our `io_uring.fd` does not refer to an io_uring instance,
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

const log = std.log.scoped(.@"tardy/aio/IoUring");

const JobBundle = struct {
    job: Job,
    statx: *linux.Statx = undefined,
    timespec: *linux.kernel_timespec = undefined,
};

const std = @import("std");
const debug = std.debug;
const OoM = mem.Allocator.Error;
const linux = std.os.linux;
const math = std.math;
const Io = std.Io;
const mem = std.mem;
const posix = std.posix;
const builtin = @import("builtin");

const tardy = @import("../root.zig");
const results = tardy.results;
const pool = tardy.core.pool;
const cross = tardy.cross;
const fs = tardy.fs;
const net = tardy.net;
const AsyncIO = tardy.AsyncIO;
const Job = @import("job.zig").Job;
const syscall = @import("syscall.zig");
