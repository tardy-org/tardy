/// Async Io
pub const AsyncIO = @This();

runner: *anyopaque,
vtable: VTable,
features: Features = .{ .bitmask = 0 },

attached: bool = false,
completions: []results.Completion = undefined,
mutex: Io.Mutex = .init,

// List of Async features that this Async I/O backend has.
// Stored as a bitmask.

/// This provides the completions that the backend will utilize when
/// submitting and reaping. This MUST be called before any other
/// methods on this AsyncIO instance.
pub fn attach(self: *AsyncIO, completions: []results.Completion) void {
    self.completions = completions;
    self.attached = true;
}

pub fn deinit(self: *AsyncIO, allocator: mem.Allocator, io: Io) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    self.vtable.deinit(self.runner, allocator);
}

pub fn queue_job(self: *AsyncIO, task: usize, sub: Submission) QueueJobError!void {
    debug.assert(self.attached);
    log.debug("queuing up job={t} at index={d}", .{ sub, task });
    try self.vtable.queue_job(self.runner, task, sub);
}

pub fn wake(self: *AsyncIO, io: Io) !void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    debug.assert(self.attached);
    try self.vtable.wake(self.runner);
}

pub fn reap(self: *AsyncIO, wait: bool) ![]results.Completion {
    debug.assert(self.attached);
    return try self.vtable.reap(self.runner, self.completions, wait);
}

pub fn submit(self: *AsyncIO) !void {
    debug.assert(self.attached);
    try self.vtable.submit(self.runner);
}

pub const Kind = union(enum) {
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

    pub fn init(impl: anytype) Kind {
        return comptime switch (impl) {
            .auto => .auto,
            .io_uring => .io_uring,
            .poll => .poll,
            .epoll => .epoll,
            .kqueue => .kqueue,
        };
    }

    pub fn Impl(comptime aio: Kind) type {
        return comptime sw: switch (aio) {
            .io_uring => IoUring,
            .epoll => Epoll,
            .poll => Poll,
            .kqueue => Kqueue,
            .custom => |inner| {
                debug.assert(std.meta.hasMethod(inner, "init"));
                debug.assert(std.meta.hasMethod(inner, "inner_deinit"));
                debug.assert(std.meta.hasMethod(inner, "queue_job"));
                debug.assert(std.meta.hasMethod(inner, "to_async"));
                return inner;
            },
            .auto => continue :sw native(),
        };
    }
};

pub fn native() Kind {
    comptime switch (builtin.target.os.tag) {
        .linux => {
            if (builtin.os.isAtLeast(
                .linux,
                .{ .major = 5, .minor = 1, .patch = 0 },
            ) orelse false) {
                return Kind.io_uring;
            }

            return Kind.epoll;
        },
        .windows => return Kind.poll,
        .ios, .macos, .watchos, .tvos, .visionos => return Kind.kqueue,
        .freebsd, .openbsd, .netbsd, .dragonfly => return Kind.kqueue,
        .illumos => return Kind.poll,
        else => @compileError("Unsupported platform! Provide a custom Async I/O backend."),
    };
}

pub const Options = struct {
    /// The parent AsyncIO that this should
    /// inherit parameters from.
    parent_async: ?*const AsyncIO = null,
    // Pooling
    pooling: core.pool.Kind,
    size_tasks_initial: usize,
    /// Maximum number of completions reaped.
    size_aio_reap_max: usize,
};

const Op = enum(u16) {
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

pub const Features = struct {
    bitmask: u16,

    pub fn init(features: []const Op) Features {
        var mask: u16 = 0;
        for (features) |op| mask |= @intFromEnum(op);
        return .{ .bitmask = mask };
    }

    pub fn all() Features {
        const mask: u16 = comptime blk: {
            var value: u16 = 0;
            for (std.meta.tags(Op)) |op| value |= @intFromEnum(op);
            break :blk value;
        };

        return .{ .bitmask = mask };
    }

    pub fn has_capability(self: Features, op: Op) bool {
        return (self.bitmask & @intFromEnum(op)) != 0;
    }
};

pub const Submission = union(Op) {
    timer: Io.Duration,
    open: struct {
        path: fs.Path,
        flags: OpenFlags,
    },
    delete: struct {
        path: fs.Path,
        is_dir: bool,
    },
    mkdir: struct {
        path: fs.Path,
        mode: isize,
    },
    stat: fs.File.Handle,
    read: struct {
        fd: fs.File.Handle,
        buffer: []u8,
        offset: ?usize,
    },
    write: struct {
        fd: fs.File.Handle,
        buffer: []const u8,
        offset: ?usize,
    },
    close: net.Socket.Handle,
    accept: struct {
        socket: net.Socket.Handle,
        kind: net.Socket.Kind,
    },
    connect: struct {
        socket: net.Socket.Handle,
        addr: net.Socket.Address,
        kind: net.Socket.Kind,
    },
    recv: struct {
        socket: net.Socket.Handle,
        buffer: []u8,
    },
    send: struct {
        socket: net.Socket.Handle,
        buffer: []const u8,
    },
};

pub const FileMode = enum {
    read,
    write,
    read_write,
};

/// These are the OpenFlags used internally.
/// This allows us to abstract out various different FS calls
/// that are all backed by the same underlying call.
pub const OpenFlags = struct {
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

pub const QueueJobError = IoUring.Errors.QueueJob ||
    Poll.Errors.QueueJob || Epoll.Errors.QueueJob ||
    Kqueue.Errors.QueueJob;

const VTable = struct {
    queue_job: *const fn (*anyopaque, usize, Submission) QueueJobError!void,
    deinit: *const fn (*anyopaque, mem.Allocator) void,
    wake: *const fn (*anyopaque) anyerror!void,
    reap: *const fn (*anyopaque, []results.Completion, bool) anyerror![]results.Completion,
    submit: *const fn (*anyopaque) anyerror!void,
};

const log = std.log.scoped(.@"tardy/AsyncIO");

const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const Io = std.Io;
const builtin = @import("builtin");

pub const Epoll = @import("aio/Epoll.zig");
pub const IoUring = @import("aio/IoUring.zig");
pub const job = @import("aio/job.zig");
pub const Kqueue = @import("aio/Kqueue.zig");
pub const Poll = @import("aio/Poll.zig");
pub const syscall = @import("aio/syscall.zig");
const tardy = @import("root.zig");
const results = tardy.results;
const core = tardy.core;
const fs = tardy.fs;
const net = tardy.net;
