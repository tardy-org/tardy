const std = @import("std");

const Path = @import("../fs/lib.zig").Path;
const Timespec = @import("../lib.zig").Timespec;
const Socket = @import("../net/lib.zig").Socket;
const AsyncOpenFlags = @import("lib.zig").AsyncOpenFlags;

pub const Job = struct {
    type: union(enum) {
        wake,
        timer: TimerJob,
        open: OpenJob,
        mkdir: MkdirJob,
        delete: DeleteJob,
        stat: std.posix.fd_t,
        read: ReadJob,
        write: WriteJob,
        close: std.posix.fd_t,
        accept: AcceptJob,
        connect: ConnectJob,
        send: SendJob,
        recv: RecvJob,
    },

    index: usize = 0,
    task: usize = 0,
};

const TimerJob = union(enum) {
    none,
    fd: std.posix.fd_t,
    ns: i128,
};

const OpenJob = struct {
    path: Path,
    kind: enum { file, dir },
    flags: AsyncOpenFlags,
};

const MkdirJob = struct {
    path: Path,
    mode: isize,
};

const DeleteJob = struct {
    path: Path,
    is_dir: bool,
};

const ReadJob = struct {
    fd: std.posix.fd_t,
    buffer: []u8,
    offset: ?usize,
};

const WriteJob = struct {
    fd: std.posix.fd_t,
    buffer: []const u8,
    offset: ?usize,
};

const AcceptJob = struct {
    socket: std.posix.socket_t,
    addr: Socket.Address,
    kind: Socket.Kind,
};

const ConnectJob = struct {
    socket: std.posix.socket_t,
    addr: Socket.Address,
    kind: Socket.Kind,
};

const SendJob = struct {
    socket: std.posix.socket_t,
    buffer: []const u8,
};

const RecvJob = struct {
    socket: std.posix.socket_t,
    buffer: []u8,
};
