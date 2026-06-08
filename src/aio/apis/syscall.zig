// vendored from https://github.com/ryuapp/zig-mirror/blob/dba1bf935390ddb0184a4dc72245454de6c06fd2/lib/std/posix.zig
// https://github.com/ryuapp/zig-mirror/commit/9ac1386c10736bc249f3891f34f23424531917a5#diff-503dcf04ec9ce2a1818ec55644fa34ff5918e86bd38a565c0186b201c06dd540
// https://github.com/ryuapp/zig-mirror/blob/aa0249d74e573742db3567f589fc6e4a00e1fff8/lib/std/os/windows.zig
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
const SOCK = system.SOCK;
const F = system.F;
const O = system.O;
const math = std.math;
const debug = std.debug;
pub const ReadError = std.Io.File.Reader.Error;
pub const TimerFdGetError = UnexpectedError;
const builtin = @import("builtin");
const native_os = builtin.os.tag;

const tardy = @import("../../lib.zig");
const Socket = tardy.Socket;
const afd = @import("syscall/afd.zig");
pub const ws2 = @import("syscall/ws2.zig");

pub fn close(handle: posix.fd_t) void {
    if (native_os == .windows) return windows.CloseHandle(handle);
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
} || UnexpectedError || net.Stream.Writer.Error;

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
    if (native_os == .windows) {
        return ws2.writeFile(fd, bytes, null);
    }

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
    ProtocolUnsupportedByAddressFamily,

    /// The socket type is not supported by the protocol.
    SocketTypeNotSupported,
} || UnexpectedError;

pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!socket_t {
    if (native_os == .windows) {
        var flags: u32 = ws2.WSA_FLAG.OVERLAPPED;
        // set SOCK.CLOEXEC by default
        flags |= ws2.WSA_FLAG.NO_HANDLE_INHERIT;

        const rc = while (true) {
            const rc = ws2.WSASocketW(
                @intCast(domain),
                @intCast(socket_type),
                @intCast(protocol),
                null,
                0,
                flags,
            );
            if (rc == ws2.INVALID_SOCKET) {
                switch (ws2.WSAGetLastError()) {
                    .EAFNOSUPPORT => return error.AddressFamilyUnsupported,
                    .EMFILE => return error.ProcessFdQuotaExceeded,
                    .ENOBUFS => return error.SystemResources,
                    .EPROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
                    .NOTINITIALISED => unreachable,
                    else => |err| return ws2.unexpectedWSAError(err),
                }
            }
            break rc;
        };

        errdefer ws2.closesock(rc) catch unreachable;

        // set SOCK.NONBLOCK by default
        var mode: c_ulong = 1; // nonblocking
        if (ws2.SOCKET_ERROR == ws2.ioctlsocket(rc, ws2.FIONBIO, &mode)) {
            switch (ws2.WSAGetLastError()) {
                // have not identified any error codes that should be handled yet
                else => unreachable,
            }
        }
        return rc;
    }

    const have_sock_flags = !builtin.target.os.tag.isDarwin() and native_os != .haiku;
    const filtered_sock_type = if (!have_sock_flags)
        socket_type & ~@as(u32, SOCK.NONBLOCK | SOCK.CLOEXEC)
    else
        socket_type;
    const rc = system.socket(domain, filtered_sock_type, protocol);
    switch (posix.errno(rc)) {
        .SUCCESS => {
            const fd: posix.socket_t = @intCast(rc);
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
        .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
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
} || IpAddress.BindError;

pub fn bind(sock: posix.socket_t, addr: *const Socket.Address) (BindError || afd.BindError)!void {
    const sock_any, const sock_len = addr.toPosix();
    if (native_os == .windows) {
        const rc = ws2.bind(sock, &sock_any, @intCast(sock_len));
        if (rc == ws2.SOCKET_ERROR) {
            switch (ws2.WSAGetLastError()) {
                .NOTINITIALISED => unreachable, // not initialized WSA
                .EADDRNOTAVAIL => unreachable,
                .ENOTSOCK => unreachable,
                .EFAULT => unreachable, // invalid pointers
                .EINVAL => unreachable,
                .ENETDOWN => unreachable,
                .EACCES => return error.AccessDenied,
                .EADDRINUSE => return error.AddressInUse,
                .ENOBUFS => return error.SystemResources,
                else => |err| return ws2.unexpectedWSAError(err),
            }
            unreachable;
        }
        return;
    }

    const rc = system.bind(sock, &sock_any, sock_len);
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
} || IpAddress.ListenError || std.Io.net.UnixAddress.ListenError;

pub fn listen(sock: socket_t, backlog: u31) ListenError!void {
    if (native_os == .windows) {
        const rc = ws2.listen(sock, backlog);
        if (rc == ws2.SOCKET_ERROR) {
            switch (ws2.WSAGetLastError()) {
                .NOTINITIALISED => unreachable, // not initialized WSA
                .ENETDOWN => unreachable,
                .EISCONN => unreachable,
                .EINVAL => unreachable,
                .EOPNOTSUPP => unreachable,
                .EADDRINUSE => return error.AddressInUse,
                .EMFILE, .ENOBUFS => return error.SystemResources,
                .ENOTSOCK => return error.FileDescriptorNotASocket,
                .EINPROGRESS => unreachable,
                else => |err| return ws2.unexpectedWSAError(err),
            }
        }
        return;
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

pub const AcceptError = error{
    /// The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,
    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,
    /// Not enough free memory. This often means that the memory allocation is limited
    /// by the socket buffer limits, not by the system memory.
    SystemResources,
    /// Either `listen` was never called, or `shutdown` was called (possibly while
    /// this call was blocking). This allows `shutdown` to be used as a concurrent
    /// cancellation mechanism.
    SocketNotListening,
    /// No connection is already queued and ready to be accepted, and
    /// the socket is configured as non-blocking.
    WouldBlock,
    /// An incoming connection was indicated, but was subsequently terminated by the
    /// remote peer prior to accepting the call.
    ConnectionAborted,
    /// Firewall rules forbid connection.
    BlockedByFirewall,
    ProtocolFailure,
} || UnexpectedError;

pub fn accept(
    sock: socket_t,
    addr: ?*Socket.Address,
    flags: u32,
) AcceptError!Socket.Handle {
    var sockaddr: posix.sockaddr, var addr_len: u32 = blk: {
        if (addr) |addr_|
            break :blk addr_.toPosix()
        else {
            const sockaddr: posix.sockaddr = undefined;
            break :blk .{ sockaddr, 0 };
        }
    };

    if (native_os == .windows) while (true) {
        const rc = ws2.accept(sock, if (addr_len == 0) null else &sockaddr, if (addr_len == 0) null else @ptrCast(&addr_len));
        errdefer ws2.closesock(rc) catch unreachable;

        if (rc == ws2.INVALID_SOCKET) {
            switch (ws2.WSAGetLastError()) {
                .NOTINITIALISED => unreachable, // not initialized WSA
                .ECONNRESET => unreachable,
                .EFAULT => unreachable,
                .ENETDOWN => unreachable,
                .ENOTSOCK => unreachable,
                .ENOBUFS => unreachable,
                .EOPNOTSUPP => unreachable,
                .EINVAL => return error.SocketNotListening,
                .EMFILE => return error.ProcessFdQuotaExceeded,
                .EWOULDBLOCK => return error.WouldBlock,
                else => |err| return ws2.unexpectedWSAError(err),
            }
        } else {
            return rc;
        }
    };

    const have_accept4 = !(builtin.target.os.tag.isDarwin() or native_os == .windows or native_os == .haiku);
    // Unsupported flag(s)
    debug.assert(0 == (flags & ~@as(u32, SOCK.NONBLOCK | SOCK.CLOEXEC)));

    defer if (addr) |addr_| {
        addr_.* = Socket.Address.fromAny(&sockaddr);
    };

    const accepted_sock: socket_t = while (true) {
        const rc = if (have_accept4)
            system.accept4(sock, &sockaddr, &addr_len, flags)
        else
            system.accept(sock, &sockaddr, &addr_len);

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
    };
    errdefer close(accepted_sock);

    if (!have_accept4) {
        try setSockFlags(accepted_sock, flags);
    }

    return accepted_sock;
}

pub const GetSockNameError = error{
    /// Insufficient resources were available in the system to perform the operation.
    SystemResources,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    /// Socket hasn't been bound yet
    SocketNotBound,

    FileDescriptorNotASocket,
} || UnexpectedError;

pub fn getsockname(sock: socket_t, addr: *posix.sockaddr, addrlen: *posix.socklen_t) GetSockNameError!void {
    // Add a windows native implemenation
    if (native_os == .windows) {
        const rc = ws2.getsockname(sock, addr, @ptrCast(addrlen));
        if (rc == ws2.SOCKET_ERROR) {
            switch (ws2.WSAGetLastError()) {
                .NOTINITIALISED => unreachable,
                .ENETDOWN => return error.NetworkSubsystemFailed,
                .EFAULT => unreachable, // addr or addrlen have invalid pointers or addrlen points to an incorrect value
                .ENOTSOCK => return error.FileDescriptorNotASocket,
                .EINVAL => return error.SocketNotBound,
                else => |err| return ws2.unexpectedWSAError(err),
            }
        }
        return;
    }
    const rc = system.getsockname(sock, addr, addrlen);
    switch (posix.errno(rc)) {
        .SUCCESS => return,
        .BADF => unreachable, // always a race condition
        .FAULT => unreachable,
        .INVAL => unreachable, // invalid parameters
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .NOBUFS => return error.SystemResources,
        else => |err| return posix.unexpectedErrno(err),
    }
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

    /// The UDP message was too big for the buffer and part of it has been discarded
    MessageTooBig,

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
    // TODO: explore a windows native approach but we can currently go through C
    // if (native_os == .windows) {
    //     @compileError("recvfrom currently unsupported on windows");
    // }

    while (true) {
        const rc = system.recvfrom(
            sockfd,
            buf.ptr,
            buf.len,
            flags,
            src_addr,
            addrlen,
        );
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

pub const ConnectError = IpAddress.ConnectError || net.UnixAddress.ConnectError;

pub fn connect(
    sock: socket_t,
    sock_addr: *const Socket.Address,
) ConnectError!void {
    if (native_os == .windows) {
        return afd.netConnectIpWindows(
            sock,
            sock_addr,
        ) catch |err| switch (err) {
            error.Canceled => unreachable,
            else => |e| return e,
        };
    }
    const sock_any, const sock_len = sock_addr.toPosix();
    while (true) {
        switch (posix.errno(system.connect(sock, &sock_any, sock_len))) {
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
pub fn setsockopt(fd: socket_t, level: i32, optname: u32, optval_bytes: []const u8) (SetSockOptError || afd.SetSockError)!void {
    if (native_os == .windows) {
        return afd.setSocketOptionAfd(
            fd,
            level,
            optname,
            optval_bytes,
        ) catch |err| switch (err) {
            error.Canceled => unreachable,
            else => |e| e,
        };
    } else {
        switch (posix.errno(system.setsockopt(
            fd,
            level,
            optname,
            optval_bytes.ptr,
            @intCast(optval_bytes.len),
        ))) {
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

pub const SendError = error{
    /// (For UNIX domain sockets, which are identified by pathname) Write permission is  denied
    /// on  the destination socket file, or search permission is denied for one of the
    /// directories the path prefix.  (See path_resolution(7).)
    /// (For UDP sockets) An attempt was made to send to a network/broadcast address as  though
    /// it was a unicast address.
    AccessDenied,
    /// The socket is marked nonblocking and the requested operation would block, and
    /// there is no global event loop configured.
    /// It's also possible to get this error under the following condition:
    /// (Internet  domain datagram sockets) The socket referred to by sockfd had not previously
    /// been bound to an address and, upon attempting to bind it to an ephemeral port,  it  was
    /// determined that all port numbers in the ephemeral port range are currently in use.  See
    /// the discussion of /proc/sys/net/ipv4/ip_local_port_range in ip(7).
    WouldBlock,

    /// Another Fast Open is already in progress.
    FastOpenAlreadyInProgress,

    /// Connection reset by peer.
    ConnectionResetByPeer,

    /// The  socket  type requires that message be sent atomically, and the size of the message
    /// to be sent made this impossible. The message is not transmitted.
    MessageOversize,

    /// The output queue for a network interface was full.  This generally indicates  that  the
    /// interface  has  stopped sending, but may be caused by transient congestion.  (Normally,
    /// this does not occur in Linux.  Packets are just silently dropped when  a  device  queue
    /// overflows.)
    /// This is also caused when there is not enough kernel memory available.
    SystemResources,

    /// The  local  end  has been shut down on a connection oriented socket.  In this case, the
    /// process will also receive a SIGPIPE unless MSG.NOSIGNAL is set.
    BrokenPipe,

    /// The local network interface used to reach the destination is down.
    NetworkDown,

    /// The destination address is not listening.
    ConnectionRefused,
} || UnexpectedError;

/// Transmit a message to another socket.
///
/// The `send` call may be used only when the socket is in a connected state (so that the intended
/// recipient  is  known).   The  only  difference  between `send` and `write` is the presence of
/// flags.  With a zero flags argument, `send` is equivalent to  `write`.   Also,  the  following
/// call
///
///     send(sockfd, buf, len, flags);
///
/// is equivalent to
///
///     sendto(sockfd, buf, len, flags, NULL, 0);
///
/// There is no  indication  of  failure  to  deliver.
///
/// When the message does not fit into the send buffer of  the  socket,  `send`  normally  blocks,
/// unless  the socket has been placed in nonblocking I/O mode.  In nonblocking mode it would fail
/// with `SendError.WouldBlock`.  The `select` call may be used  to  determine when it is
/// possible to send more data.
pub fn send(
    /// The file descriptor of the sending socket.
    sockfd: socket_t,
    buf: []const u8,
    flags: u32,
) SendError!usize {
    return sendto(sockfd, buf, flags, null, 0) catch |err| switch (err) {
        error.AddressFamilyUnsupported => unreachable,
        error.SymLinkLoop => unreachable,
        error.NameTooLong => unreachable,
        error.FileNotFound => unreachable,
        error.NotDir => unreachable,
        error.NetworkUnreachable => unreachable,
        error.AddressUnavailable => unreachable,
        error.SocketUnconnected => unreachable,
        error.UnreachableAddress => unreachable,
        else => |e| return e,
    };
}

pub const SendToError = SendMsgError || error{
    /// The destination address is not reachable by the bound address.
    UnreachableAddress,
    /// The destination address is not listening.
    ConnectionRefused,
    /// Network is unreachable.
    NetworkUnreachable,
};

/// Transmit a message to another socket.
///
/// The `sendto` call may be used only when the socket is in a connected state (so that the intended
/// recipient  is  known). The  following call
///
///     send(sockfd, buf, len, flags);
///
/// is equivalent to
///
///     sendto(sockfd, buf, len, flags, NULL, 0);
///
/// If  sendto()  is used on a connection-mode (`SOCK.STREAM`, `SOCK.SEQPACKET`) socket, the arguments
/// `dest_addr` and `addrlen` are asserted to be `null` and `0` respectively, and asserted
/// that the socket was actually connected.
/// Otherwise, the address of the target is given by `dest_addr` with `addrlen` specifying  its  size.
///
/// If the message is too long to pass atomically through the underlying protocol,
/// `SendError.MessageOversize` is returned, and the message is not transmitted.
///
/// There is no  indication  of  failure  to  deliver.
///
/// When the message does not fit into the send buffer of  the  socket,  `sendto`  normally  blocks,
/// unless  the socket has been placed in nonblocking I/O mode.  In nonblocking mode it would fail
/// with `SendError.WouldBlock`.  The `select` call may be used  to  determine when it is
/// possible to send more data.
pub fn sendto(
    /// The file descriptor of the sending socket.
    sockfd: socket_t,
    /// Message to send.
    buf: []const u8,
    flags: u32,
    dest_addr: ?*const posix.sockaddr,
    addrlen: posix.socklen_t,
) SendToError!usize {
    // TODO: explore a windows native approach
    // if (native_os == .windows) @compileError("sendto unsupported on windows");
    while (true) {
        const rc = system.sendto(
            sockfd,
            buf.ptr,
            buf.len,
            flags,
            dest_addr,
            addrlen,
        );
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .ACCES => return error.AccessDenied,
            .AGAIN => return error.WouldBlock,
            .ALREADY => return error.FastOpenAlreadyInProgress,
            .BADF => unreachable, // always a race condition
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .DESTADDRREQ => unreachable, // The socket is not connection-mode, and no peer address is set.
            .FAULT => unreachable, // An invalid user space address was specified for an argument.
            .INTR => continue,
            .INVAL => return error.UnreachableAddress,
            .ISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
            .MSGSIZE => return error.MessageOversize,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .OPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
            .PIPE => return error.BrokenPipe,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .HOSTUNREACH => return error.NetworkUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTCONN => return error.SocketUnconnected,
            .NETDOWN => return error.NetworkDown,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub const SendMsgError = SendError || error{
    /// The passed address didn't have the correct address family in its sa_family field.
    AddressFamilyUnsupported,

    /// Returned when socket is AF.UNIX and the given path has a symlink loop.
    SymLinkLoop,

    /// Returned when socket is AF.UNIX and the given path length exceeds `max_path_bytes` bytes.
    NameTooLong,

    /// Returned when socket is AF.UNIX and the given path does not point to an existing file.
    FileNotFound,
    NotDir,

    /// The socket is not connected (connection-oriented sockets only).
    SocketUnconnected,
    AddressUnavailable,
};

pub fn sendmsg(
    /// The file descriptor of the sending socket.
    sockfd: socket_t,
    /// Message header and iovecs
    msg: *const posix.msghdr_const,
    flags: u32,
) SendMsgError!usize {
    while (true) {
        const rc = system.sendmsg(sockfd, msg, flags);
        // TODO: make windows.ws2_32 easily usable like the previous api
        if (native_os == .windows)
            @compileError("sendmsg currently unsupported on windows")
        else {
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),

                .ACCES => return error.AccessDenied,
                .AGAIN => return error.WouldBlock,
                .ALREADY => return error.FastOpenAlreadyInProgress,
                .BADF => unreachable, // always a race condition
                .CONNRESET => return error.ConnectionResetByPeer,
                .DESTADDRREQ => unreachable, // The socket is not connection-mode, and no peer address is set.
                .FAULT => unreachable, // An invalid user space address was specified for an argument.
                .INTR => continue,
                .INVAL => unreachable, // Invalid argument passed.
                .ISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
                .MSGSIZE => return error.MessageOversize,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
                .OPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
                .PIPE => return error.BrokenPipe,
                .AFNOSUPPORT => return error.AddressFamilyUnsupported,
                .LOOP => return error.SymLinkLoop,
                .NAMETOOLONG => return error.NameTooLong,
                .NOENT => return error.FileNotFound,
                .NOTDIR => return error.NotDir,
                .HOSTUNREACH => return error.NetworkUnreachable,
                .NETUNREACH => return error.NetworkUnreachable,
                .NOTCONN => return error.SocketUnconnected,
                .NETDOWN => return error.NetworkDown,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }
}

pub const PipeError = error{
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
} || UnexpectedError;

/// Creates a unidirectional data channel that can be used for interprocess communication.
pub fn pipe() PipeError![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    switch (posix.errno(system.pipe(&fds))) {
        .SUCCESS => return fds,
        .INVAL => unreachable, // Invalid parameters to pipe()
        .FAULT => unreachable, // Invalid fds pointer
        .NFILE => return error.SystemFdQuotaExceeded,
        .MFILE => return error.ProcessFdQuotaExceeded,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn pipe2(flags: O) PipeError![2]posix.fd_t {
    if (@TypeOf(system.pipe2) != void) {
        var fds: [2]posix.fd_t = undefined;
        switch (posix.errno(system.pipe2(&fds, flags))) {
            .SUCCESS => return fds,
            .INVAL => unreachable, // Invalid flags
            .FAULT => unreachable, // Invalid fds pointer
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    const fds: [2]posix.fd_t = try pipe();
    errdefer {
        close(fds[0]);
        close(fds[1]);
    }

    // https://github.com/ziglang/zig/issues/18882
    if (@as(u32, @bitCast(flags)) == 0)
        return fds;

    // CLOEXEC is special, it's a file descriptor flag and must be set using
    // F.SETFD.
    if (flags.CLOEXEC) {
        for (fds) |fd| {
            switch (posix.errno(system.fcntl(fd, F.SETFD, @as(u32, posix.FD_CLOEXEC)))) {
                .SUCCESS => {},
                .INVAL => unreachable, // Invalid flags
                .BADF => unreachable, // Always a race condition
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    const new_flags: u32 = f: {
        var new_flags = flags;
        new_flags.CLOEXEC = false;
        break :f @bitCast(new_flags);
    };
    // Set every other flag affecting the file status using F.SETFL.
    if (new_flags != 0) {
        for (fds) |fd| {
            switch (posix.errno(system.fcntl(fd, F.SETFL, new_flags))) {
                .SUCCESS => {},
                .INVAL => unreachable, // Invalid flags
                .BADF => unreachable, // Always a race condition
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }
    return fds;
}

fn setSockFlags(sock: socket_t, flags: u32) !void {
    if ((flags & SOCK.CLOEXEC) != 0) {
        if (native_os == .windows) {
            // https://marc.info/?l=postgresql-hackers&m=176247669521571
            // https://github.com/bytecodealliance/rustix/pull/909
            // https://etherealwake.com/2021/01/portable-sockets-basics/
            //
            // CLOEXEC matches WSA_FLAG_NO_HANDLE_INHERIT
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
        // TODO: currently incorrect
        if (native_os == .windows) {
            // AFD-internal option — not the same as the Winsock SO_ values
            const AFD_SO_NONBLOCKING = 0x08; // AFD-level optname
            try afd.setSocketOptionAfd(sock, windows.ws2_32.SOL.SOCKET, AFD_SO_NONBLOCKING, 1);
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

pub const PollError = error{
    /// The network subsystem has failed.
    NetworkDown,

    /// The kernel had no space to allocate file descriptor tables.
    SystemResources,
} || UnexpectedError;

pub const pollfd = if (native_os != .windows) posix.pollfd else ws2.WSAPOLLFD;

pub const POLL = if (native_os != .windows) posix.POLL else ws2.POLL;

pub fn poll(fds: []pollfd, timeout: i32) PollError!usize {
    if (native_os == .windows) {
        while (true) switch (ws2.WSAPoll(
            fds.ptr,
            @intCast(fds.len),
            timeout,
        )) {
            ws2.SOCKET_ERROR => switch (ws2.WSAGetLastError()) {
                .NOTINITIALISED => unreachable,
                .ENETDOWN => return error.NetworkDown,
                .ENOBUFS => return error.SystemResources,
                else => |err| return ws2.unexpectedWSAError(err),
            },
            else => |rc| return @intCast(rc),
        };
    }

    while (true) {
        const fds_count = std.math.cast(posix.nfds_t, fds.len) orelse return error.SystemResources;
        const rc = system.poll(fds.ptr, fds_count, timeout);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .FAULT => unreachable,
            .INTR => continue,
            .INVAL => unreachable,
            .NOMEM => return error.SystemResources,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
    unreachable;
}

/// Returns the number of bytes that were read, which can be less than
/// buf.len. If 0 bytes were read, that means EOF.
/// If `fd` is opened in non blocking mode, the function will return error.WouldBlock
/// when EAGAIN is received.
///
/// Linux has a limit on how many bytes may be transferred in one `read` call, which is `0x7ffff000`
/// on both 64-bit and 32-bit systems. This is due to using a signed C int as the return value, as
/// well as stuffing the errno codes into the last `4096` values. This is noted on the `read` man page.
/// The limit on Darwin is `0x7fffffff`, trying to read more than that returns EINVAL.
/// The corresponding POSIX limit is `maxInt(isize)`.
pub fn read(fd: posix.fd_t, buf: []u8) (ReadError || net.Stream.Reader.Error)!usize {
    if (buf.len == 0) return 0;
    if (native_os == .windows) {
        var bufs: [][]u8 = undefined;
        bufs[0] = buf;

        return afd.netReadWindows(fd, bufs) catch |err| switch (err) {
            error.Canceled => unreachable,
            else => |s| return s,
        };
    }

    // Prevents EINVAL.
    const max_count = switch (native_os) {
        .linux => 0x7ffff000,
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => std.math.maxInt(i32),
        else => std.math.maxInt(isize),
    };
    while (true) {
        const rc = system.read(fd, buf.ptr, @min(buf.len, max_count));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => unreachable,
            .FAULT => unreachable,
            .AGAIN => return error.WouldBlock,
            .CANCELED => return error.Canceled,
            .BADF => return error.Unexpected, // use after free
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketUnconnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.Unexpected,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn now(clock: Io.Clock) Io.Timestamp {
    return switch (native_os) {
        .windows => nowWindows(clock),
        else => nowPosix(clock),
    };
}

fn nowPosix(clock: Io.Clock) Io.Timestamp {
    const clock_id: posix.clockid_t = clockToPosix(clock);
    var timespec: posix.timespec = undefined;
    switch (posix.errno(posix.system.clock_gettime(clock_id, &timespec))) {
        .SUCCESS => return timestampFromPosix(&timespec),
        else => return .zero,
    }
}

fn nowWindows(clock: Io.Clock) Io.Timestamp {
    switch (clock) {
        .real => {
            // RtlGetSystemTimePrecise() has a granularity of 100 nanoseconds
            // and uses the NTFS/Windows epoch, which is 1601-01-01.
            const epoch_ns = std.time.epoch.windows * std.time.ns_per_s;
            return .{ .nanoseconds = @as(i96, windows.ntdll.RtlGetSystemTimePrecise()) * 100 + epoch_ns };
        },
        .awake, .boot => {
            // We don't need to cache QPF as it's internally just a memory read to KUSER_SHARED_DATA
            // (a read-only page of info updated and mapped by the kernel to all processes):
            // https://docs.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddk/ns-ntddk-kuser_shared_data
            // https://www.geoffchappell.com/studies/windows/km/ntoskrnl/inc/api/ntexapi_x/kuser_shared_data/index.htm
            const qpf: u64 = qpf: {
                var qpf: windows.LARGE_INTEGER = undefined;
                debug.assert(windows.ntdll.RtlQueryPerformanceFrequency(&qpf).toBool());
                break :qpf @bitCast(qpf);
            };

            // QPC on windows doesn't fail on >= XP/2000 and includes time suspended.
            const qpc: u64 = qpc: {
                var qpc: windows.LARGE_INTEGER = undefined;
                debug.assert(windows.ntdll.RtlQueryPerformanceCounter(&qpc).toBool());
                break :qpc @bitCast(qpc);
            };

            // 10Mhz (1 qpc tick every 100ns) is a common enough QPF value that we can optimize on it.
            // https://github.com/microsoft/STL/blob/785143a0c73f030238ef618890fd4d6ae2b3a3a0/stl/inc/chrono#L694-L701
            const common_qpf = 10_000_000;
            if (qpf == common_qpf) return .{ .nanoseconds = qpc * (std.time.ns_per_s / common_qpf) };

            // Convert to ns using fixed point.
            const scale = @as(u64, std.time.ns_per_s << 32) / @as(u32, @intCast(qpf));
            const result = (@as(u96, qpc) * scale) >> 32;
            return .{ .nanoseconds = @intCast(result) };
        },
        .cpu_process => {
            const handle = windows.GetCurrentProcess();
            var times: windows.KERNEL_USER_TIMES = undefined;

            // https://github.com/reactos/reactos/blob/master/ntoskrnl/ps/query.c#L442-L485
            if (windows.ntdll.NtQueryInformationProcess(
                handle,
                .Times,
                &times,
                @sizeOf(windows.KERNEL_USER_TIMES),
                null,
            ) != .SUCCESS) return .zero;

            const sum = @as(i96, times.UserTime) + @as(i96, times.KernelTime);
            return .{ .nanoseconds = sum * 100 };
        },
        .cpu_thread => {
            const handle = windows.GetCurrentThread();
            var times: windows.KERNEL_USER_TIMES = undefined;

            // https://github.com/reactos/reactos/blob/master/ntoskrnl/ps/query.c#L2971-L3019
            if (windows.ntdll.NtQueryInformationThread(
                handle,
                .Times,
                &times,
                @sizeOf(windows.KERNEL_USER_TIMES),
                null,
            ) != .SUCCESS) return .zero;

            const sum = @as(i96, times.UserTime) + @as(i96, times.KernelTime);
            return .{ .nanoseconds = sum * 100 };
        },
    }
}

fn clockToPosix(clock: Io.Clock) posix.clockid_t {
    return switch (clock) {
        .real => posix.CLOCK.REALTIME,
        .awake => switch (native_os) {
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => posix.CLOCK.UPTIME_RAW,
            else => posix.CLOCK.MONOTONIC,
        },
        .boot => switch (native_os) {
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => posix.CLOCK.MONOTONIC_RAW,
            // On freebsd derivatives, use MONOTONIC_FAST as currently there's
            // no precision tradeoff.
            .freebsd, .dragonfly => posix.CLOCK.MONOTONIC_FAST,
            // On linux, use BOOTTIME instead of MONOTONIC as it ticks while
            // suspended.
            .linux => posix.CLOCK.BOOTTIME,
            // On other posix systems, MONOTONIC is generally the fastest and
            // ticks while suspended.
            else => posix.CLOCK.MONOTONIC,
        },
        .cpu_process => posix.CLOCK.PROCESS_CPUTIME_ID,
        .cpu_thread => posix.CLOCK.THREAD_CPUTIME_ID,
    };
}

fn timestampFromPosix(timespec: *const posix.timespec) Io.Timestamp {
    return .{
        .nanoseconds = @intCast(
            @as(i128, timespec.sec) * std.time.ns_per_s + timespec.nsec,
        ),
    };
}

pub const EpollCreateError = error{
    /// The  per-user   limit   on   the   number   of   epoll   instances   imposed   by
    /// /proc/sys/fs/epoll/max_user_instances  was encountered.  See epoll(7) for further
    /// details.
    /// Or, The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,

    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,

    /// There was insufficient memory to create the kernel object.
    SystemResources,
} || UnexpectedError;

pub fn epoll_create1(flags: u32) EpollCreateError!i32 {
    const rc = system.epoll_create1(flags);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INVAL => unreachable,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub const EpollCtlError = error{
    /// op was EPOLL_CTL_ADD, and the supplied file descriptor fd is  already  registered
    /// with this epoll instance.
    FileDescriptorAlreadyPresentInSet,
    /// fd refers to an epoll instance and this EPOLL_CTL_ADD operation would result in a
    /// circular loop of epoll instances monitoring one another.
    OperationCausesCircularLoop,
    /// op was EPOLL_CTL_MOD or EPOLL_CTL_DEL, and fd is not registered with  this  epoll
    /// instance.
    FileDescriptorNotRegistered,
    /// There was insufficient memory to handle the requested op control operation.
    SystemResources,
    /// The  limit  imposed  by /proc/sys/fs/epoll/max_user_watches was encountered while
    /// trying to register (EPOLL_CTL_ADD) a new file descriptor on  an  epoll  instance.
    /// See epoll(7) for further details.
    UserResourceLimitReached,
    /// The target file fd does not support epoll.  This error can occur if fd refers to,
    /// for example, a regular file or a directory.
    FileDescriptorIncompatibleWithEpoll,
} || UnexpectedError;

pub fn epoll_ctl(epfd: i32, op: u32, fd: i32, event: ?*system.epoll_event) EpollCtlError!void {
    const rc = system.epoll_ctl(epfd, op, fd, event);
    return switch (posix.errno(rc)) {
        .SUCCESS => {},
        .BADF => unreachable, // always a race condition if this happens
        .EXIST => error.FileDescriptorAlreadyPresentInSet,
        .INVAL => unreachable,
        .LOOP => error.OperationCausesCircularLoop,
        .NOENT => error.FileDescriptorNotRegistered,
        .NOMEM => error.SystemResources,
        .NOSPC => error.UserResourceLimitReached,
        .PERM => error.FileDescriptorIncompatibleWithEpoll,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub const EventFdError = error{
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
} || UnexpectedError;

pub fn eventfd(initval: u32, flags: u32) EventFdError!i32 {
    const rc = system.eventfd(initval, flags);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INVAL => unreachable, // invalid parameters
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NODEV => error.SystemResources,
        .NOMEM => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub const TimerFdCreateError = error{
    PermissionDenied,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    SystemResources,
} || UnexpectedError;

pub fn timerfd_create(clock_id: system.timerfd_clockid_t, flags: system.TFD) TimerFdCreateError!posix.fd_t {
    const rc = system.timerfd_create(clock_id, @bitCast(flags));
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INVAL => unreachable,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NODEV => error.NoDevice,
        .NOMEM => error.SystemResources,
        .PERM => error.PermissionDenied,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub const TimerFdSetError = error{Canceled} || UnexpectedError;

pub fn timerfd_settime(
    fd: i32,
    flags: system.TFD.TIMER,
    new_value: *const system.itimerspec,
    old_value: ?*system.itimerspec,
) TimerFdSetError!void {
    const rc = system.timerfd_settime(fd, @bitCast(flags), new_value, old_value);
    return switch (posix.errno(rc)) {
        .SUCCESS => {},
        .BADF => unreachable,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .CANCELED => error.Canceled,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn timerfd_gettime(fd: i32) TimerFdGetError!system.itimerspec {
    var curr_value: system.itimerspec = undefined;
    const rc = system.timerfd_gettime(fd, &curr_value);
    return switch (posix.errno(rc)) {
        .SUCCESS => return curr_value,
        .BADF => unreachable,
        .FAULT => unreachable,
        .INVAL => unreachable,
        else => |err| posix.unexpectedErrno(err),
    };
}

/// Waits for an I/O event on an epoll file descriptor.
/// Returns the number of file descriptors ready for the requested I/O,
/// or zero if no file descriptor became ready during the requested timeout milliseconds.
pub fn epoll_wait(epfd: i32, events: []system.epoll_event, timeout: i32) usize {
    while (true) {
        // TODO get rid of the @intCast
        const rc = system.epoll_wait(epfd, events.ptr, @intCast(events.len), timeout);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF => unreachable,
            .FAULT => unreachable,
            .INVAL => unreachable,
            else => unreachable,
        }
    }
}

pub const KQueueError = error{
    /// The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,

    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,
} || UnexpectedError;

pub fn kqueue() KQueueError!i32 {
    const rc = system.kqueue();
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub const KEventError = error{
    /// The process does not have permission to register a filter.
    AccessDenied,

    /// The event could not be found to be modified or deleted.
    EventNotFound,

    /// No memory was available to register the event.
    SystemResources,

    /// The specified process to attach to does not exist.
    ProcessNotFound,

    /// changelist or eventlist had too many items on it.
    /// TODO remove this possibility
    Overflow,
};

pub fn kevent(
    kq: i32,
    changelist: []const posix.Kevent,
    eventlist: []posix.Kevent,
    timeout: ?*const posix.timespec,
) KEventError!usize {
    while (true) {
        const rc = system.kevent(
            kq,
            changelist.ptr,
            math.cast(c_int, changelist.len) orelse return error.Overflow,
            eventlist.ptr,
            math.cast(c_int, eventlist.len) orelse return error.Overflow,
            timeout,
        );
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .ACCES => error.AccessDenied,
            .FAULT => unreachable,
            .BADF => unreachable, // Always a race condition.
            .INTR => continue,
            .INVAL => unreachable,
            .NOENT => error.EventNotFound,
            .NOMEM => error.SystemResources,
            .SRCH => error.ProcessNotFound,
            else => unreachable,
        };
    }
}
