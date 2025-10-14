const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Value;
const builtin = @import("builtin");

const PoolKind = @import("../core/pool.zig").PoolKind;
const Path = @import("../fs/lib.zig").Path;
const Timespec = @import("../lib.zig").Timespec;
const Socket = @import("../net/lib.zig").Socket;
const Completion = @import("completion.zig").Completion;

const log = std.log.scoped(.@"tardy/aio");
pub const AsyncKind = enum {
    auto,
    io_uring,
    epoll,
    kqueue,
    poll,
    custom,
};

pub const AsyncType = union(AsyncKind) {
    /// Attempts to automatically match
    /// the best backend.
    ///
    /// Linux: io_uring
    /// Windows: poll
    /// Darwin & BSD: kqueue
    /// Solaris: poll
    /// POSIX-compliant: poll
    auto,
    /// Available on Linux >= 5.1
    ///
    /// Utilizes the io_uring API for handling I/O.
    io_uring,
    /// Available on Linux >= 2.5.45
    ///
    /// Utilizes the epoll API for handling I/O.
    epoll,
    /// Available on Darwin & BSD systems
    ///
    /// Utilizes the kqueue APO for handling I/O.
    kqueue,
    /// Available on all POSIX targets.
    ///
    /// Utilizes the poll API for handling I/O.
    poll,
    /// Available on all targets.
    custom: type,
};

pub fn auto_async_match() AsyncType {
    switch (comptime builtin.target.os.tag) {
        .linux => {
            if (comptime builtin.os.isAtLeast(
                .linux,
                .{ .major = 5, .minor = 1, .patch = 0 },
            ) orelse false) {
                return AsyncType.io_uring;
            }

            return AsyncType.epoll;
        },
        .windows => return AsyncType.poll,
        .ios, .macos, .watchos, .tvos, .visionos => return AsyncType.kqueue,
        .freebsd, .openbsd, .netbsd, .dragonfly => return AsyncType.kqueue,
        .solaris, .illumos => return AsyncType.poll,
        else => @compileError("Unsupported platform! Provide a custom Async I/O backend."),
    }
}

pub fn async_to_type(comptime aio: AsyncType) type {
    return comptime switch (aio) {
        .io_uring => @import("../aio/apis/io_uring.zig").AsyncIoUring,
        .epoll => @import("../aio/apis/epoll.zig").AsyncEpoll,
        .poll => @import("../aio/apis/poll.zig").AsyncPoll,
        .kqueue => @import("../aio/apis/kqueue.zig").AsyncKqueue,
        .custom => |inner| {
            assert(std.meta.hasMethod(inner, "init"));
            assert(std.meta.hasMethod(inner, "inner_deinit"));
            assert(std.meta.hasMethod(inner, "queue_job"));
            assert(std.meta.hasMethod(inner, "to_async"));
            return inner;
        },
        .auto => unreachable,
    };
}

pub const AsyncOptions = struct {
    /// The parent AsyncIO that this should
    /// inherit parameters from.
    parent_async: ?*const Async = null,
    // Pooling
    pooling: PoolKind,
    size_tasks_initial: usize,
    /// Maximum number of completions reaped.
    size_aio_reap_max: usize,
};

const AsyncOp = enum(u16) {
    timer = 1 << 0,
    open = 1 << 1,
    delete = 1 << 2,
    mkdir = 1 << 3,
    stat = 1 << 4,
    read = 1 << 5,
    write = 1 << 6,
    close = 1 << 7,
    accept = 1 << 8,
    connect = 1 << 9,
    recv = 1 << 10,
    send = 1 << 11,
};

pub const AsyncFeatures = struct {
    bitmask: u16,

    pub fn init(features: []const AsyncOp) AsyncFeatures {
        var mask: u16 = 0;
        for (features) |op| mask |= @intFromEnum(op);
        return .{ .bitmask = mask };
    }

    pub fn all() AsyncFeatures {
        const mask: u16 = comptime blk: {
            var value: u16 = 0;
            for (std.meta.tags(AsyncOp)) |op| value |= @intFromEnum(op);
            break :blk value;
        };

        return .{ .bitmask = mask };
    }

    pub fn has_capability(self: AsyncFeatures, op: AsyncOp) bool {
        return (self.bitmask & @intFromEnum(op)) != 0;
    }
};

pub const AsyncSubmission = union(AsyncOp) {
    timer: Timespec,
    open: struct {
        path: Path,
        flags: AsyncOpenFlags,
    },
    delete: struct {
        path: Path,
        is_dir: bool,
    },
    mkdir: struct {
        path: Path,
        mode: isize,
    },
    stat: std.posix.fd_t,
    read: struct {
        fd: std.posix.fd_t,
        buffer: []u8,
        offset: ?usize,
    },
    write: struct {
        fd: std.posix.fd_t,
        buffer: []const u8,
        offset: ?usize,
    },
    close: std.posix.fd_t,
    accept: struct {
        socket: std.posix.socket_t,
        kind: Socket.Kind,
    },
    connect: struct {
        socket: std.posix.socket_t,
        addr: std.net.Address,
        kind: Socket.Kind,
    },
    recv: struct {
        socket: std.posix.socket_t,
        buffer: []u8,
    },
    send: struct {
        socket: std.posix.socket_t,
        buffer: []const u8,
    },
};

pub const Async = struct {
    const VTable = struct {
        queue_job: *const fn (*anyopaque, usize, AsyncSubmission) anyerror!void,
        deinit: *const fn (*anyopaque, std.mem.Allocator) void,
        wake: *const fn (*anyopaque, *anyopaque) anyerror!void,
        reap: *const fn (*anyopaque, []Completion, bool) anyerror![]Completion,
        submit: *const fn (*anyopaque) anyerror!void,
    };

    runner: *anyopaque,
    vtable: VTable,
    features: AsyncFeatures = .{ .bitmask = 0 },

    attached: bool = false,
    completions: []Completion = undefined,
    mutex: std.Thread.Mutex = .{},

    // List of Async features that this Async I/O backend has.
    // Stored as a bitmask.

    /// This provides the completions that the backend will utilize when
    /// submitting and reaping. This MUST be called before any other
    /// methods on this AsyncIO instance.
    pub fn attach(self: *Async, completions: []Completion) void {
        self.completions = completions;
        self.attached = true;
    }

    pub fn deinit(self: *Async, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.vtable.deinit(self.runner, allocator);
    }

    pub fn queue_job(self: *Async, task: usize, job: AsyncSubmission) !void {
        assert(self.attached);
        log.debug("queuing up job={t} at index={d}", .{ job, task });
        try self.vtable.queue_job(self.runner, task, job);
    }

    pub fn wake(self: *Async, target_runner: *anyopaque) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        assert(self.attached);
        try self.vtable.wake(self.runner, target_runner);
    }

    pub fn reap(self: *Async, wait: bool) ![]Completion {
        assert(self.attached);
        return try self.vtable.reap(self.runner, self.completions, wait);
    }

    pub fn submit(self: *Async) !void {
        assert(self.attached);
        try self.vtable.submit(self.runner);
    }
};

pub const FileMode = enum {
    read,
    write,
    read_write,
};

/// These are the OpenFlags used internally.
/// This allows us to abstract out various different FS calls
/// that are all backed by the same underlying call.
pub const AsyncOpenFlags = struct {
    mode: FileMode = .read,
    /// Permissions used for creating files.
    perms: ?isize = null,
    /// Open the file for appending.
    /// This will force writing permissions.
    append: bool = false,
    /// Create the file if it doesn't exist.
    create: bool = false,
    /// Truncate the file to the start.
    truncate: bool = false,
    /// Fail if the file already exists.
    exclusive: bool = false,
    /// Open the file for non-blocking I/O.
    non_block: bool = true,
    /// Ensure data is physically written to disk immediately.
    sync: bool = false,
    /// Ensure that the file is a directory.
    directory: bool = false,
};
