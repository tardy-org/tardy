// vendored from https://codeberg.com/ziglang/zig/blob/ee574f665c4e3d1be4950b307ce3ff8324f13f46/lib/std/posix.zig

pub fn close(handle: posix.fd_t) void {
    switch (posix.errno(system.close(handle))) {
        .BADF => unreachable, // Always a race condition.
        .INTR => return, // This is still a success.
        else => return,
    }
}

pub const WriteError = error{
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    DeviceBusy,
    InvalidArgument,

    /// File descriptor does not hold the required rights to write to it.
    AccessDenied,
    PermissionDenied,
    BrokenPipe,
    SystemResources,
    Canceled,
    NotOpenForWriting,

    /// The process cannot access the file because another process has locked
    /// a portion of the file. Windows-only.
    LockViolation,

    /// This error occurs when no global event loop is configured,
    /// and reading from the file descriptor would block.
    WouldBlock,

    /// Connection reset by peer.
    ConnectionResetByPeer,

    /// This error occurs in Linux if the process being written to
    /// no longer exists.
    ProcessNotFound,
    /// This error occurs when a device gets disconnected before or mid-flush
    /// while it's being written to - errno(6): No such device or address.
    NoDevice,

    /// The socket type requires that message be sent atomically, and the size of the message
    /// to be sent made this impossible. The message is not transmitted.
    MessageOversize,
} || UnexpectedError;

/// Write to a file descriptor.
/// Retries when interrupted by a signal.
/// Returns the number of bytes written. If nonzero bytes were supplied, this will be nonzero.
///
/// Note that a successful write() may transfer fewer than count bytes.  Such partial  writes  can
/// occur  for  various reasons; for example, because there was insufficient space on the disk
/// device to write all of the requested bytes, or because a blocked write() to a socket,  pipe,  or
/// similar  was  interrupted by a signal handler after it had transferred some, but before it had
/// transferred all of the requested bytes.  In the event of a partial write, the caller can  make
/// another  write() call to transfer the remaining bytes.  The subsequent call will either
/// transfer further bytes or may result in an error (e.g., if the disk is now full).
///
/// For POSIX systems, if `fd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.
/// On Windows, if the application has a global event loop enabled, I/O Completion Ports are
/// used to perform the I/O. `error.WouldBlock` is not possible on Windows.
///
/// Linux has a limit on how many bytes may be transferred in one `write` call, which is `0x7ffff000`
/// on both 64-bit and 32-bit systems. This is due to using a signed C int as the return value, as
/// well as stuffing the errno codes into the last `4096` values. This is noted on the `write` man page.
/// The limit on Darwin is `0x7fffffff`, trying to read more than that returns EINVAL.
/// The corresponding POSIX limit is `maxInt(isize)`.
pub fn write(fd: posix.fd_t, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;
    if (native_os == .windows) @compileError("unsupported OS");
    if (native_os == .wasi) @compileError("unsupported OS");

    const max_count = switch (native_os) {
        .linux => 0x7ffff000,
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => math.maxInt(i32),
        else => math.maxInt(isize),
    };
    while (true) {
        const rc = system.write(fd, bytes.ptr, @min(bytes.len, max_count));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => return error.InvalidArgument,
            .FAULT => unreachable,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting, // can be a race condition.
            .DESTADDRREQ => unreachable, // `connect` was never called.
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BUSY => return error.DeviceBusy,
            .NXIO => return error.NoDevice,
            .MSGSIZE => return error.MessageOversize,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub const FcntlError = error{
    PermissionDenied,
    FileBusy,
    ProcessFdQuotaExceeded,
    Locked,
    DeadLock,
    LockedRegionLimitExceeded,
} || UnexpectedError;

pub fn fcntl(fd: posix.fd_t, cmd: i32, arg: usize) FcntlError!usize {
    while (true) {
        const rc = system.fcntl(fd, cmd, arg);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN, .ACCES => return error.Locked,
            .BADF => unreachable,
            .BUSY => return error.FileBusy,
            .INVAL => unreachable, // invalid parameters
            .PERM => return error.PermissionDenied,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NOTDIR => unreachable, // invalid parameter
            .DEADLK => return error.DeadLock,
            .NOLCK => return error.LockedRegionLimitExceeded,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub const SocketError = error{
    /// Permission to create a socket of the specified type and/or
    /// pro‐tocol is denied.
    AccessDenied,

    /// The implementation does not support the specified address family.
    AddressFamilyUnsupported,

    /// Unknown protocol, or protocol family not available.
    ProtocolFamilyNotAvailable,

    /// The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,

    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,

    /// Insufficient memory is available. The socket cannot be created until sufficient
    /// resources are freed.
    SystemResources,

    /// The protocol type or the specified protocol is not supported within this domain.
    ProtocolNotSupported,

    /// The socket type is not supported by the protocol.
    SocketTypeNotSupported,
} || UnexpectedError;

pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!socket_t {
    const have_sock_flags = !builtin.target.os.tag.isDarwin() and native_os != .haiku;
    const filtered_sock_type = if (!have_sock_flags)
        socket_type & ~@as(u32, SOCK.NONBLOCK | SOCK.CLOEXEC)
    else
        socket_type;
    const rc = system.socket(domain, filtered_sock_type, protocol);
    switch (posix.errno(rc)) {
        .SUCCESS => {
            const fd: posix.fd_t = @intCast(rc);
            errdefer close(fd);
            if (!have_sock_flags) {
                try setSockFlags(fd, socket_type);
            }
            return fd;
        },
        .ACCES => return error.AccessDenied,
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .INVAL => return error.ProtocolFamilyNotAvailable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolNotSupported,
        .PROTOTYPE => return error.SocketTypeNotSupported,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub const BindError = error{
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    NotDir,
    ReadOnlyFileSystem,
    AccessDenied,
} || std.Io.net.IpAddress.BindError;

pub fn bind(sock: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) BindError!void {
    if (native_os == .windows) @compileError("TODO: Implement bind for windows");

    const rc = system.bind(sock, addr, len);
    switch (posix.errno(rc)) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .ADDRINUSE => return error.AddressInUse,
        .BADF => unreachable, // always a race condition if this error is returned
        .INVAL => unreachable, // invalid parameters
        .NOTSOCK => unreachable, // invalid `sockfd`
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .FAULT => unreachable, // invalid `addr` pointer
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub const ListenError = error{
    FileDescriptorNotASocket,
    OperationUnsupported,
} || std.Io.net.IpAddress.ListenError || std.Io.net.UnixAddress.ListenError;

pub fn listen(sock: socket_t, backlog: u31) ListenError!void {
    if (native_os == .windows) {
        @compileError("use std.Io instead");
    } else {
        const rc = system.listen(sock, backlog);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .ADDRINUSE => return error.AddressInUse,
            .BADF => unreachable,
            .NOTSOCK => return error.FileDescriptorNotASocket,
            .OPNOTSUPP => return error.OperationUnsupported,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub const AcceptError = std.Io.net.Server.AcceptError;

pub fn accept(
    sock: socket_t,
    addr: ?*posix.sockaddr,
    addr_size: ?*posix.socklen_t,
    flags: u32,
) AcceptError!socket_t {
    const have_accept4 = !(builtin.target.os.tag.isDarwin() or native_os == .windows or native_os == .haiku);
    debug.assert(0 == (flags & ~@as(u32, SOCK.NONBLOCK | SOCK.CLOEXEC))); // Unsupported flag(s)

    const accepted_sock: socket_t = while (true) {
        const rc = if (have_accept4)
            system.accept4(sock, addr, addr_size, flags)
        else
            system.accept(sock, addr, addr_size);

        if (native_os == .windows) {
            @compileError("use std.Io instead");
        } else {
            switch (posix.errno(rc)) {
                .SUCCESS => break @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .BADF => unreachable, // always a race condition
                .CONNABORTED => return error.ConnectionAborted,
                .FAULT => unreachable,
                .INVAL => return error.SocketNotListening,
                .NOTSOCK => unreachable,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .OPNOTSUPP => unreachable,
                .PROTO => return error.ProtocolFailure,
                .PERM => return error.BlockedByFirewall,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    };

    errdefer switch (native_os) {
        .windows => @compileError("use std.Io instead"),
        else => close(accepted_sock),
    };
    if (!have_accept4) {
        try setSockFlags(accepted_sock, flags);
    }
    return accepted_sock;
}

pub const RecvFromError = error{
    /// The socket is marked nonblocking and the requested operation would block, and
    /// there is no global event loop configured.
    WouldBlock,

    /// A remote host refused to allow the network connection, typically because it is not
    /// running the requested service.
    ConnectionRefused,

    /// Could not allocate kernel memory.
    SystemResources,

    ConnectionResetByPeer,
    ConnectionTimedOut,

    /// The socket has not been bound.
    SocketNotBound,

    /// The UDP message was too big for the buffer and part of it has been discarded
    MessageTooBig,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    /// The socket is not connected (connection-oriented sockets only).
    SocketNotConnected,

    /// The other end closed the socket unexpectedly or a read is executed on a shut down socket
    BrokenPipe,
} || UnexpectedError;

pub fn recv(sock: socket_t, buf: []u8, flags: u32) RecvFromError!usize {
    return recvfrom(sock, buf, flags, null, null);
}

/// If `sockfd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.
pub fn recvfrom(
    sockfd: socket_t,
    buf: []u8,
    flags: u32,
    src_addr: ?*posix.sockaddr,
    addrlen: ?*posix.socklen_t,
) RecvFromError!usize {
    while (true) {
        if (native_os == .windows) {
            @compileError("TODO: implement recvfrom");
        } else {
            const rc = system.recvfrom(sockfd, buf.ptr, buf.len, flags, src_addr, addrlen);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .BADF => unreachable, // always a race condition
                .FAULT => unreachable,
                .INVAL => unreachable,
                .NOTCONN => return error.SocketNotConnected,
                .NOTSOCK => unreachable,
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .NOMEM => return error.SystemResources,
                .CONNREFUSED => return error.ConnectionRefused,
                .CONNRESET => return error.ConnectionResetByPeer,
                .TIMEDOUT => return error.ConnectionTimedOut,
                .PIPE => return error.BrokenPipe,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }
}

pub const ConnectError = std.Io.net.IpAddress.ConnectError || std.Io.net.UnixAddress.ConnectError;

pub fn connect(sock: socket_t, sock_addr: *const posix.sockaddr, len: posix.socklen_t) ConnectError!void {
    if (native_os == .windows) @compileError("use std.Io instead");

    while (true) {
        switch (posix.errno(system.connect(sock, sock_addr, len))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRNOTAVAIL => return error.AddressUnavailable,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            .ALREADY => return error.ConnectionPending,
            .BADF => unreachable, // sockfd is not a valid open file descriptor.
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .FAULT => unreachable, // The socket structure address is outside the user's address space.
            .INTR => continue,
            .ISCONN => @panic("AlreadyConnected"), // The socket is already connected.
            .HOSTUNREACH => return error.NetworkUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .PROTOTYPE => unreachable, // The socket type does not support the requested communications protocol.
            .TIMEDOUT => return error.Timeout,
            .NOENT => return error.FileNotFound, // Returned when socket is AF.UNIX and the given path does not exist.
            .CONNABORTED => unreachable, // Tried to reuse socket that previously received error.ConnectionRefused.
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub const SetSockOptError = error{
    /// The socket is already connected, and a specified option cannot be set while the socket is connected.
    AlreadyConnected,

    /// The option is not supported by the protocol.
    InvalidProtocolOption,

    /// The send and receive timeout values are too big to fit into the timeout fields in the socket structure.
    TimeoutTooBig,

    /// Insufficient resources are available in the system to complete the call.
    SystemResources,

    /// Setting the socket option requires more elevated permissions.
    PermissionDenied,

    OperationUnsupported,
    NetworkDown,
    FileDescriptorNotASocket,
    SocketNotBound,
    NoDevice,
} || UnexpectedError;

/// Set a socket's options.
pub fn setsockopt(fd: socket_t, level: i32, optname: u32, opt: []const u8) SetSockOptError!void {
    if (native_os == .windows) {
        try setSocketOptionAfd(fd, level, optname, opt);
    } else {
        switch (posix.errno(system.setsockopt(fd, level, optname, opt.ptr, @intCast(opt.len)))) {
            .SUCCESS => {},
            .BADF => unreachable, // always a race condition
            .NOTSOCK => unreachable, // always a race condition
            .INVAL => unreachable,
            .FAULT => unreachable,
            .DOM => return error.TimeoutTooBig,
            .ISCONN => return error.AlreadyConnected,
            .NOPROTOOPT => return error.InvalidProtocolOption,
            .NOMEM => return error.SystemResources,
            .NOBUFS => return error.SystemResources,
            .PERM => return error.PermissionDenied,
            .NODEV => return error.NoDevice,
            .OPNOTSUPP => return error.OperationUnsupported,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn setSockFlags(sock: socket_t, flags: u32) !void {
    if ((flags & SOCK.CLOEXEC) != 0) {
        if (native_os == .windows) {
            // TODO: Find out if this is supported for sockets
        } else {
            var fd_flags = fcntl(sock, F.GETFD, 0) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                error.DeadLock => unreachable,
                error.LockedRegionLimitExceeded => unreachable,
                else => |e| return e,
            };
            fd_flags |= system.FD_CLOEXEC;
            _ = fcntl(sock, F.SETFD, fd_flags) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                error.DeadLock => unreachable,
                error.LockedRegionLimitExceeded => unreachable,
                else => |e| return e,
            };
        }
    }
    if ((flags & SOCK.NONBLOCK) != 0) {
        if (native_os == .windows) {
            // AFD-internal option — not the same as the Winsock SO_ values
            const AFD_SO_NONBLOCKING = 0x08; // AFD-level optname
            try setSocketOptionAfd(sock, windows.ws2_32.SOL.SOCKET, AFD_SO_NONBLOCKING, 1);
        } else {
            var fl_flags = fcntl(sock, F.GETFL, 0) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                error.DeadLock => unreachable,
                error.LockedRegionLimitExceeded => unreachable,
                else => |e| return e,
            };
            fl_flags |= 1 << @bitOffsetOf(O, "NONBLOCK");
            _ = fcntl(sock, F.SETFL, fl_flags) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                error.DeadLock => unreachable,
                error.LockedRegionLimitExceeded => unreachable,
                else => |e| return e,
            };
        }
    }
}

fn setSocketOptionAfd(wsocket: net.Socket.Handle, level: i32, opt_name: u32, opt_val: anytype) !void {
    try socketOptionAfd(wsocket, .set, level, opt_name, @ptrCast(@constCast(&opt_val)));
}

fn socketOptionAfd(wsocket: net.Socket.Handle, mode: windows.AFD.SOCKOPT_INFO.Mode, level: i32, opt_name: u32, opt_val: []u8) !void {
    switch ((try deviceIoControl(&.{
        .file = .{ .handle = wsocket, .flags = .{ .nonblocking = true } },
        .code = windows.IOCTL.AFD.SOCKOPT,
        .in = @ptrCast(&windows.AFD.SOCKOPT_INFO{
            .mode = mode,
            .level = level,
            .optname = opt_name,
            .optval = opt_val.ptr,
            .optlen = opt_val.len,
        }),
    })).u.Status) {
        .SUCCESS => return,
        .CANCELLED => unreachable,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => |status| return windows.unexpectedStatus(status),
    }
}

fn flagApc(userdata: ?*anyopaque, _: *windows.IO_STATUS_BLOCK, _: windows.ULONG) align(apc_align) callconv(.winapi) void {
    const flag: *bool = @ptrCast(userdata);
    flag.* = true;
}

pub fn waitForApcOrAlert() void {
    const infinite_timeout: windows.LARGE_INTEGER = std.math.minInt(windows.LARGE_INTEGER);
    _ = windows.ntdll.NtDelayExecution(.TRUE, &infinite_timeout);
}

fn deviceIoControl(o: *const Io.Operation.DeviceIoControl) Io.Cancelable!Io.Operation.DeviceIoControl.Result {
    if (native_os == .windows) {
        const NtControlFile = switch (o.code.DeviceType) {
            .FILE_SYSTEM, .NAMED_PIPE => &windows.ntdll.NtFsControlFile,
            else => &windows.ntdll.NtDeviceIoControlFile,
        };
        var iosb: windows.IO_STATUS_BLOCK = undefined;
        if (o.file.flags.nonblocking) {
            var done: bool = false;
            switch (NtControlFile(
                o.file.handle,
                null, // event
                flagApc,
                &done, // APC context
                &iosb,
                o.code,
                if (o.in.len > 0) o.in.ptr else null,
                @intCast(o.in.len),
                if (o.out.len > 0) o.out.ptr else null,
                @intCast(o.out.len),
            )) {
                // We must wait for the APC routine.
                .PENDING, .SUCCESS => while (!done) {
                    // Once we get here we must not return from the function until the
                    // operation completes, thereby releasing reference to io_status_block.
                    waitForApcOrAlert();
                },
                else => |status| iosb.u.Status = status,
            }
        } else {
            while (true) switch (NtControlFile(
                o.file.handle,
                null, // event
                null, // APC routine
                null, // APC context
                &iosb,
                o.code,
                if (o.in.len > 0) o.in.ptr else null,
                @intCast(o.in.len),
                if (o.out.len > 0) o.out.ptr else null,
                @intCast(o.out.len),
            )) {
                .PENDING => unreachable, // unrecoverable: wrong asynchronous flag
                .CANCELLED => {
                    continue;
                },
                else => |status| {
                    iosb.u.Status = status;
                    break;
                },
            };
        }
        return iosb;
    } else {
        while (true) {
            const rc = system.ioctl(o.file.handle, @bitCast(o.code), @intFromPtr(o.arg));
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    if (@TypeOf(rc) == usize) return @bitCast(@as(u32, @truncate(rc)));
                    return rc;
                },
                .INTR => {
                    continue;
                },
                else => |err| {
                    return -@as(i32, @intFromEnum(err));
                },
            }
        }
    }
}

fn openSocketAfd(family: ws2_32.ADDRESS_FAMILY, options: IpAddress.BindOptions) !net.Socket.Handle {
    const mode, const protocol = try Threaded.posixSocketModeProtocol(family, options.mode, options.protocol);
    var handle: windows.HANDLE = undefined;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    while (true) switch (windows.ntdll.NtCreateFile(
        &handle,
        .{
            .STANDARD = .{ .RIGHTS = .{ .WRITE_DAC = true }, .SYNCHRONIZE = true },
            .GENERIC = .{ .WRITE = true, .READ = true },
        },
        &.{
            .ObjectName = @constCast(&windows.UNICODE_STRING.init(
                windows.AFD.DEVICE_NAME ++ .{ '\\', 'E', 'n', 'd', 'p', 'o', 'i', 'n', 't' },
            )),
        },
        &iosb,
        null,
        .{},
        .{ .READ = true, .WRITE = true },
        .OPEN_IF,
        .{ .IO = .ASYNCHRONOUS },
        &windows.AFD.OPEN_PACKET.FULL_EA_INFORMATION{ .Value = .{
            .EndpointType = .{
                .CONNECTIONLESS = switch (options.mode) {
                    .stream, .seqpacket, .rdm => false,
                    .dgram, .raw => true,
                },
                .MESSAGEMODE = options.mode != .stream,
                .RAW = options.mode == .raw,
            },
            .GroupID = 0,
            .AddressFamily = family,
            .SocketType = @bitCast(mode),
            .Protocol = @bitCast(protocol),
            .TransportDeviceNameLength = 0,
            .TransportDeviceName = undefined,
        } },
        @sizeOf(windows.AFD.OPEN_PACKET.FULL_EA_INFORMATION),
    )) {
        .SUCCESS => {
            return handle;
        },
        .CANCELLED => {
            continue;
        },
        .PROTOCOL_NOT_SUPPORTED => return error.AddressFamilyUnsupported,
        .NO_SUCH_FILE => return error.ProtocolUnsupportedByAddressFamily,
        else => |status| return windows.statusBug(status),
    };
}

const default_fn_align = switch (builtin.mode) {
    .Debug, .ReleaseSafe, .ReleaseFast => switch (builtin.cpu.arch) {
        else => |arch| @compileError("Unsupported architecture: " ++ @tagName(arch)),
        .arm, .thumb => 4,
        .aarch64, .x86, .x86_64 => 16,
    },
    .ReleaseSmall => 1,
};

pub const apc_align = @max(default_fn_align, 2);

const std = @import("std");
pub const UnexpectedError = std.Io.UnexpectedError;
const posix = std.posix;
const system = posix.system;
const linux = std.os.linux;
const windows = std.os.windows;
const wasi = std.os.wasi;
const Io = std.Io;
const net = Io.net;
const socket_t = net.Socket.Handle;
const ws2_32 = windows.ws2_32;
const IpAddress = net.IpAddress;
const Threaded = Io.Threaded;
const SOCK = system.SOCK;
const F = system.F;
const O = system.O;
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const math = std.math;
const debug = std.debug;
