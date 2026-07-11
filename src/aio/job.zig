pub const Job = struct {
    type: union(enum) {
        wake,
        timer: TimerJob,
        open: OpenJob,
        mkdir: MkdirJob,
        delete: DeleteJob,
        stat: fs.File.Handle,
        read: ReadJob,
        write: WriteJob,
        close: fs.File.Handle,
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
    path: fs.Path,
    kind: enum { file, dir },
    flags: AsyncIO.OpenFlags,
};

const MkdirJob = struct {
    path: fs.Path,
    mode: isize,
};

const DeleteJob = struct {
    path: fs.Path,
    is_dir: bool,
};

const ReadJob = struct {
    fd: fs.File.Handle,
    buffer: []u8,
    offset: ?usize,
};

const WriteJob = struct {
    fd: fs.File.Handle,
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

const std = @import("std");
const Io = std.Io;

const Socket = @import("../net/lib.zig").Socket;
const tardy = @import("../root.zig");
const fs = tardy.fs;
const AsyncIO = tardy.AsyncIO;
