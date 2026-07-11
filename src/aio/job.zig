const std = @import("std");
const Io = std.Io;

const Path = @import("../fs/lib.zig").Path;
const File = @import("../fs/file.zig").File;
const Socket = @import("../net/lib.zig").Socket;
const tardy = @import("../root.zig");

const AsyncIO = tardy.AsyncIO;

pub const Job = struct {
    type: union(enum) {
        wake,
        timer: TimerJob,
        open: OpenJob,
        mkdir: MkdirJob,
        delete: DeleteJob,
        stat: File.Handle,
        read: ReadJob,
        write: WriteJob,
        close: File.Handle,
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
    fd: Socket.Handle,
    ns: Io.Duration,
};

const OpenJob = struct {
    path: Path,
    kind: enum { file, dir },
    flags: AsyncIO.OpenFlags,
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
    fd: File.Handle,
    buffer: []u8,
    offset: ?usize,
};

const WriteJob = struct {
    fd: File.Handle,
    buffer: []const u8,
    offset: ?usize,
};

const AcceptJob = struct {
    socket: Socket.Handle,
    addr: Socket.Address,
    kind: Socket.Kind,
};

const ConnectJob = struct {
    socket: Socket.Handle,
    addr: Socket.Address,
    // TODO: kind isn't needed anymore as we are using a union
    kind: Socket.Kind,
};

const SendJob = struct {
    socket: Socket.Handle,
    buffer: []const u8,
};

const RecvJob = struct {
    socket: Socket.Handle,
    buffer: []u8,
};
