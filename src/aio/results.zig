pub fn Resulted(comptime T: type, comptime E: type) type {
    return union(enum) {
        const Resulted_t = @This();
        actual: T,
        err: E,

        pub fn unwrap(result: *const Resulted_t) E!T {
            switch (result.*) {
                .actual => |actual| return actual,
                .err => |err| return err,
            }
        }
    };
}

pub const Errors = struct {
    pub const Accept = error{
        WouldBlock,
        InvalidFd,
        ConnectionAborted,
        InvalidAddress,
        Interrupted,
        NotListening,
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        OutOfMemory,
        SystemResources,
        SocketNotListening,
        BlockedByFirewall,
        ProtocolFailure,
        Unexpected,
    };

    pub const Connect = error{
        AccessDenied,
        AddressInUse,
        AddressNotAvailable,
        AddressFamilyNotSupported,
        WouldBlock,
        InvalidFd,
        ConnectionRefused,
        InvalidAddress,
        Interrupted,
        AlreadyConnected,
        NetworkUnreachable,
        NotASocket,
        ProtocolFamilyNotSupported,
        TimedOut,
        Unexpected,
    };

    pub const Recv = error{
        Closed,
        WouldBlock,
        SocketNotConnected,
        SystemResources,
        ConnectionRefused,
        ConnectionResetByPeer,
        BrokenPipe,
        ConnectionTimedOut,
        MessageTooBig,
        Unexpected,
    };

    pub const Send = error{
        Closed,
        AccessDenied,
        WouldBlock,
        // TODO: remove after finding out why secsock
        // sometimes returns InvalidFd on send
        InvalidFd,
        FastOpenAlreadyInProgress,
        ConnectionRefused,
        ConnectionResetByPeer,
        MessageOversize,
        SystemResources,
        BrokenPipe,
        NetworkDown,
        Unexpected,
    };

    pub const Open = error{
        AccessDenied,
        InvalidFd,
        Busy,
        DiskQuotaExceeded,
        AlreadyExists,
        InvalidAddress,
        FileTooBig,
        Interrupted,
        InvalidArguments,
        IsDirectory,
        Loop,
        ProcessFdQuotaExceeded,
        NameTooLong,
        SystemFdQuotaExceeded,
        DeviceNotFound,
        NotFound,
        OutOfMemory,
        NoSpace,
        NotADirectory,
        OperationNotSupported,
        ReadOnlyFileSystem,
        FileLocked,
        WouldBlock,
        Unexpected,
    };

    pub const Read = error{
        AccessDenied,
        EndOfFile,
        WouldBlock,
        InvalidFd,
        InvalidAddress,
        Interrupted,
        InvalidArguments,
        IoError,
        IsDirectory,
        Unexpected,
    };

    pub const Write = error{
        WouldBlock,
        InvalidFd,
        NoDestinationAddress,
        DiskQuotaExceeded,
        InvalidAddress,
        FileTooBig,
        Interrupted,
        IoError,
        NoSpace,
        AccessDenied,
        BrokenPipe,
        Unexpected,
    };

    pub const Stat = error{
        AccessDenied,
        InvalidFd,
        InvalidAddress,
        InvalidArguments,
        Loop,
        NameTooLong,
        NotFound,
        OutOfMemory,
        NotADirectory,
        Unexpected,
        PermissionDenied,
    };

    pub const Mkdir = error{
        AccessDenied,
        AlreadyExists,
        Loop,
        NameTooLong,
        NotFound,
        NoSpace,
        NotADirectory,
        ReadOnlyFileSystem,
        Unexpected,
    };

    pub const Delete = error{
        AccessDenied,
        Busy,
        InvalidAddress,
        IoError,
        IsDirectory,
        Loop,
        NameTooLong,
        NotFound,
        OutOfMemory,
        IsNotDirectory,
        ReadOnlyFileSystem,
        InvalidArguments,
        NotEmpty,
        InvalidFd,
        Unexpected,
    };

    pub const CreateDir = Errors.Mkdir || Errors.Open || error{InternalFailure};
    pub const DeleteTree = Errors.Open || Errors.Delete || error{InternalFailure};
};

pub const Results = struct {
    pub const Accept = Resulted(Socket, Errors.Accept);

    pub const Connect = Resulted(void, Errors.Connect);
    pub const Recv = Resulted(usize, Errors.Recv);

    pub const Send = Resulted(usize, Errors.Send);

    pub const Open = Resulted(
        union(enum) { file: fs.File, dir: fs.Dir },
        Errors.Open,
    );
    pub const OpenFile = Resulted(fs.File, Errors.Open);
    pub const OpenDir = Resulted(fs.Dir, Errors.Open);

    pub const Mkdir = Resulted(void, Errors.Mkdir);
    pub const CreateDir = Resulted(fs.Dir, Errors.CreateDir);

    pub const Delete = Resulted(void, Errors.Delete);
    pub const DeleteTree = Resulted(void, Errors.DeleteTree);

    pub const Read = Resulted(usize, Errors.Read);
    pub const Write = Resulted(usize, Errors.Write);

    pub const Stat = Resulted(fs.Stat, Errors.Stat);
};

pub const Result = union(enum) {
    /// If we have returned a stat object.
    stat: Results.Stat,
    accept: Results.Accept,
    connect: Results.Connect,
    recv: Results.Recv,
    send: Results.Send,
    open: Results.Open,
    mkdir: Results.Mkdir,
    delete: Results.Delete,
    read: Results.Read,
    write: Results.Write,
    /// If we have returned a ptr.
    ptr: ?*anyopaque,
    close,
    /// If we want to wake the runtime up.
    wake,
    none,

    comptime {
        debug.assert(@sizeOf(Result) == 144);
    }
};

pub const Completion = struct {
    task_index: usize,
    result: Result,
};

const std = @import("std");
const debug = std.debug;

const tardy = @import("../root.zig");
const fs = tardy.fs;
const Socket = tardy.net.Socket;
