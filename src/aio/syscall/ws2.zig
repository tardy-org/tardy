// https://github.com/ryuapp/zig-mirror/blob/aa0249d74e573742db3567f589fc6e4a00e1fff8/lib/std/os/windows/ws2_32.zig
// https://github.com/ryuapp/zig-mirror/blob/aa0249d74e573742db3567f589fc6e4a00e1fff8/lib/std/os/windows.zig
const std = @import("std");
const windows = std.os.windows;
const ws2_32 = windows.ws2_32;
const math = std.math;
const builtin = @import("builtin");
const native_arch = builtin.cpu.arch;

pub const WSA_FLAG = struct {
    pub const OVERLAPPED = 1;
    pub const NO_HANDLE_INHERIT = 128;
};
pub const FIONBIO = -2147195266;
pub const INVALID_SOCKET: windows.HANDLE = @ptrFromInt(~@as(usize, 0));
pub const SOCKET_ERROR = -1;

pub const WSAPOLLFD = extern struct {
    fd: windows.HANDLE,
    events: windows.SHORT,
    revents: windows.SHORT,
};

pub const POLL = struct {
    // Event flag definitions for WSAPoll().
    pub const RDNORM = 0x0100;
    pub const RDBAND = 0x0200;
    pub const IN = (RDNORM | RDBAND);
    pub const PRI = 0x0400;

    pub const WRNORM = 0x0010;
    pub const OUT = (WRNORM);
    pub const WRBAND = 0x0020;

    pub const ERR = 0x0001;
    pub const HUP = 0x0002;
    pub const NVAL = 0x0004;
};

pub extern "ws2_32" fn getsockname(
    s: windows.HANDLE,
    name: *ws2_32.sockaddr,
    namelen: *i32,
) callconv(.winapi) i32;

pub extern "ws2_32" fn socket(
    af: i32,
    @"type": i32,
    protocol: i32,
) callconv(.winapi) windows.HANDLE;

pub const WSABUF = extern struct {
    len: windows.ULONG,
    buf: [*]u8,
};
pub const LPWSAOVERLAPPED_COMPLETION_ROUTINE = *const fn (
    dwError: u32,
    cbTransferred: u32,
    lpOverlapped: *OVERLAPPED,
    dwFlags: u32,
) callconv(.winapi) void;
pub extern "ws2_32" fn WSARecvFrom(
    s: windows.HANDLE,
    lpBuffers: [*]WSABUF,
    dwBuffercount: u32,
    lpNumberOfBytesRecvd: ?*u32,
    lpFlags: *u32,
    lpFrom: ?*ws2_32.sockaddr,
    lpFromlen: ?*i32,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?LPWSAOVERLAPPED_COMPLETION_ROUTINE,
) callconv(.winapi) i32;

pub fn recvfrom(
    s: windows.HANDLE,
    buf: [*]u8,
    len: usize,
    flags: u32,
    from: ?*ws2_32.sockaddr,
    from_len: ?*ws2_32.socklen_t,
) !u32 {
    var buffer: WSABUF = .{ .len = @intCast(len), .buf = buf };
    var bytes_received: windows.DWORD = undefined;
    var flags_inout = flags;
    if (WSARecvFrom(
        s,
        @ptrCast(&buffer),
        1,
        &bytes_received,
        &flags_inout,
        from,
        @ptrCast(from_len),
        null,
        null,
    ) == SOCKET_ERROR) {
        switch (WSAGetLastError()) {
            .NOTINITIALISED => unreachable,
            .EINVAL => unreachable,
            .ENETDOWN => unreachable,
            .ECONNRESET => return error.ConnectionResetByPeer,
            .EMSGSIZE => return error.MessageTooBig,
            .ENOTCONN => return error.SocketNotConnected,
            .EWOULDBLOCK => return error.WouldBlock,
            .ETIMEDOUT => return error.ConnectionTimedOut,
            else => |err| return unexpectedWSAError(err),
        }
    } else {
        return @intCast(bytes_received);
    }
}

pub extern "ws2_32" fn WSASendTo(
    s: windows.HANDLE,
    lpBuffers: [*]WSABUF,
    dwBufferCount: u32,
    lpNumberOfBytesSent: ?*u32,
    dwFlags: u32,
    lpTo: ?*const ws2_32.sockaddr,
    iToLen: i32,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRounte: ?LPWSAOVERLAPPED_COMPLETION_ROUTINE,
) callconv(.winapi) i32;

pub fn sendto(
    s: windows.HANDLE,
    buf: [*]const u8,
    len: usize,
    flags: u32,
    to: ?*const ws2_32.sockaddr,
    to_len: ws2_32.socklen_t,
) i32 {
    var buffer: WSABUF = .{ .len = @truncate(len), .buf = @constCast(buf) };
    var bytes_send: windows.DWORD = undefined;
    if (WSASendTo(
        s,
        @ptrCast(&buffer),
        1,
        &bytes_send,
        flags,
        to,
        @intCast(to_len),
        null,
        null,
    ) == SOCKET_ERROR) {
        return SOCKET_ERROR;
    } else {
        return @intCast(bytes_send);
    }
}

extern "kernel32" fn WriteFile(
    in_hFile: windows.HANDLE,
    in_lpBuffer: [*]const u8,
    in_nNumberOfBytesToWrite: windows.DWORD,
    out_lpNumberOfBytesWritten: ?*windows.DWORD,
    in_out_lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) windows.BOOL;

const WriteFileError = error{
    SystemResources,
    BrokenPipe,
    NotOpenForWriting,
    /// The process cannot access the file because another process has locked
    /// a portion of the file.
    LockViolation,
    /// The specified network name is no longer available.
    ConnectionResetByPeer,
    /// Known to be possible when:
    /// - Unable to write to disconnected virtual com port (Windows)
    AccessDenied,
    Unexpected,
};

const MAX_PROTOCOL_CHAIN = 7;

const WSAPROTOCOLCHAIN = extern struct {
    ChainLen: c_int,
    ChainEntries: [MAX_PROTOCOL_CHAIN]windows.DWORD,
};
const WSAPROTOCOL_LEN = 255;

const WSAPROTOCOL_INFOW = extern struct {
    dwServiceFlags1: windows.DWORD,
    dwServiceFlags2: windows.DWORD,
    dwServiceFlags3: windows.DWORD,
    dwServiceFlags4: windows.DWORD,
    dwProviderFlags: windows.DWORD,
    ProviderId: windows.GUID,
    dwCatalogEntryId: windows.DWORD,
    ProtocolChain: WSAPROTOCOLCHAIN,
    iVersion: c_int,
    iAddressFamily: c_int,
    iMaxSockAddr: c_int,
    iMinSockAddr: c_int,
    iSocketType: c_int,
    iProtocol: c_int,
    iProtocolMaxOffset: c_int,
    iNetworkByteOrder: c_int,
    iSecurityScheme: c_int,
    dwMessageSize: windows.DWORD,
    dwProviderReserved: windows.DWORD,
    szProtocol: [WSAPROTOCOL_LEN + 1]windows.WCHAR,
};

pub extern "ws2_32" fn WSASocketW(
    af: i32,
    @"type": i32,
    protocol: i32,
    lpProtocolInfo: ?*WSAPROTOCOL_INFOW,
    g: u32,
    dwFlags: u32,
) callconv(.winapi) windows.HANDLE;

pub fn unexpectedWSAError(err: WinsockError) std.posix.UnexpectedError {
    @branchHint(.cold);
    if (std.options.unexpected_error_tracing) {
        std.debug.print("error.Unexpected: GetLastError({d}): {t}\n", .{ err, err });
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    }
    return error.Unexpected;
}

extern "ws2_32" fn closesocket(
    s: windows.HANDLE,
) callconv(.winapi) i32;

pub fn closesock(s: windows.HANDLE) !void {
    switch (closesocket(s)) {
        0 => {},
        SOCKET_ERROR => switch (WSAGetLastError()) {
            else => |err| return unexpectedWSAError(err),
        },
        else => unreachable,
    }
}

pub extern "ws2_32" fn ioctlsocket(
    s: windows.HANDLE,
    cmd: i32,
    mode: *u32,
) callconv(.winapi) i32;

pub extern "ws2_32" fn bind(
    s: windows.HANDLE,
    name: *const ws2_32.sockaddr,
    namelen: i32,
) callconv(.winapi) i32;

pub extern "ws2_32" fn listen(
    s: windows.HANDLE,
    backlog: i32,
) callconv(.winapi) i32;

pub extern "ws2_32" fn accept(
    s: windows.HANDLE,
    addr: ?*ws2_32.sockaddr,
    addrlen: ?*i32,
) callconv(.winapi) windows.HANDLE;

extern "ws2_32" fn WSAStartup(
    wVersionRequired: windows.WORD,
    lpWSAData: *WSADATA,
) callconv(.winapi) WinsockError;

pub fn wsaStartup(major_version: windows.WORD, minor_version: windows.WORD) !void {
    var wsa_data: WSADATA = undefined;
    const version = minor_version << 8 | major_version;
    const status = WSAStartup(version, &wsa_data);
    switch (status) {
        .SUCCESS => return,
        .SYSNOTREADY => return error.NetworkDown,
        else => unreachable,
    }
}

pub fn wsaCleanup() !void {
    return switch (WSACleanup()) {
        0 => {},
        SOCKET_ERROR => switch (WSAGetLastError()) {
            .NOTINITIALISED => unreachable,
            .ENETDOWN => unreachable,
            .EINPROGRESS => return error.BlockingOperationInProgress,
            else => |err| return unexpectedWSAError(err),
        },
        else => unreachable,
    };
}

extern "ws2_32" fn WSACleanup() callconv(.winapi) i32;

pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) WinsockError;

pub fn writeFile(
    handle: windows.HANDLE,
    bytes: []const u8,
    offset: ?u64,
) WriteFileError!usize {
    var bytes_written: windows.DWORD = undefined;
    var overlapped_data: OVERLAPPED = undefined;
    const overlapped: ?*OVERLAPPED = if (offset) |off| blk: {
        overlapped_data = .{
            .Internal = 0,
            .InternalHigh = 0,
            .DUMMYUNIONNAME = .{
                .DUMMYSTRUCTNAME = .{
                    .Offset = @truncate(off),
                    .OffsetHigh = @truncate(off >> 32),
                },
            },
            .hEvent = null,
        };
        break :blk &overlapped_data;
    } else null;

    const adjusted_len = math.cast(u32, bytes.len) orelse math.maxInt(u32);

    if (WriteFile(
        handle,
        bytes.ptr,
        adjusted_len,
        &bytes_written,
        overlapped,
    ) == .FALSE) {
        switch (GetLastError()) {
            .INVALID_USER_BUFFER => return error.SystemResources,
            .NOT_ENOUGH_MEMORY => return error.SystemResources,
            .OPERATION_ABORTED => unreachable,
            .NOT_ENOUGH_QUOTA => return error.SystemResources,
            .IO_PENDING => unreachable,
            .NO_DATA => return error.BrokenPipe,
            .INVALID_HANDLE => return error.NotOpenForWriting,
            .LOCK_VIOLATION => return error.LockViolation,
            .NETNAME_DELETED => return error.ConnectionResetByPeer,
            .ACCESS_DENIED => return error.AccessDenied,
            .WORKING_SET_QUOTA => return error.SystemResources,
            else => |err| return windows.unexpectedError(err),
        }
    }
    return bytes_written;
}

const OVERLAPPED = extern struct {
    Internal: windows.ULONG_PTR,
    InternalHigh: windows.ULONG_PTR,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: windows.DWORD,
            OffsetHigh: windows.DWORD,
        },
        Pointer: ?windows.PVOID,
    },
    hEvent: ?windows.HANDLE,
};

fn GetLastError() windows.Win32Error {
    return @enumFromInt(teb().LastErrorValue);
}

fn teb() *TEB {
    return switch (native_arch) {
        .thumb => asm (
            \\ mrc p15, 0, %[ptr], c13, c0, 2
            : [ptr] "=r" (-> *TEB),
        ),
        .aarch64 => asm (
            \\ mov %[ptr], x18
            : [ptr] "=r" (-> *TEB),
        ),
        .x86 => asm (
            \\ movl %%fs:0x18, %[ptr]
            : [ptr] "=r" (-> *TEB),
        ),
        .x86_64 => asm (
            \\ movq %%gs:0x30, %[ptr]
            : [ptr] "=r" (-> *TEB),
        ),
        else => @compileError("unsupported arch"),
    };
}

const TEB = extern struct {
    NtTib: windows.NT_TIB,
    EnvironmentPointer: windows.PVOID,
    ClientId: windows.CLIENT_ID,
    ActiveRpcHandle: windows.PVOID,
    ThreadLocalStoragePointer: windows.PVOID,
    ProcessEnvironmentBlock: *windows.PEB,
    LastErrorValue: windows.ULONG,
    Reserved2: [399 * @sizeOf(windows.PVOID) - @sizeOf(windows.ULONG)]u8,
    Reserved3: [1952]u8,
    TlsSlots: [64]windows.PVOID,
    Reserved4: [8]u8,
    Reserved5: [26]windows.PVOID,
    ReservedForOle: windows.PVOID,
    Reserved6: [4]windows.PVOID,
    TlsExpansionSlots: windows.PVOID,
};

pub extern "ws2_32" fn WSAPoll(
    fdArray: [*]WSAPOLLFD,
    fds: u32,
    timeout: i32,
) callconv(.winapi) i32;

const WSADESCRIPTION_LEN = 256;
const WSASYS_STATUS_LEN = 128;

pub const WSADATA = if (@sizeOf(usize) == @sizeOf(u64))
    extern struct {
        wVersion: windows.WORD,
        wHighVersion: windows.WORD,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: *u8,
        szDescription: [WSADESCRIPTION_LEN + 1]u8,
        szSystemStatus: [WSASYS_STATUS_LEN + 1]u8,
    }
else
    extern struct {
        wVersion: windows.WORD,
        wHighVersion: windows.WORD,
        szDescription: [WSADESCRIPTION_LEN + 1]u8,
        szSystemStatus: [WSASYS_STATUS_LEN + 1]u8,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: *u8,
    };

/// https://docs.microsoft.com/en-au/windows/win32/winsock/windows-sockets-error-codes-2
pub const WinsockError = enum(u16) {
    SUCCESS = 0,
    /// Specified event object handle is invalid.
    /// An application attempts to use an event object, but the specified handle is not valid.
    INVALID_HANDLE = 6,
    /// Insufficient memory available.
    /// An application used a Windows Sockets function that directly maps to a Windows function.
    /// The Windows function is indicating a lack of required memory resources.
    NOT_ENOUGH_MEMORY = 8,
    /// One or more parameters are invalid.
    /// An application used a Windows Sockets function which directly maps to a Windows function.
    /// The Windows function is indicating a problem with one or more parameters.
    INVALID_PARAMETER = 87,
    /// Overlapped operation aborted.
    /// An overlapped operation was canceled due to the closure of the socket, or the execution of the SIO_FLUSH command in WSAIoctl.
    OPERATION_ABORTED = 995,
    /// Overlapped I/O event object not in signaled state.
    /// The application has tried to determine the status of an overlapped operation which is not yet completed.
    /// Applications that use WSAGetOverlappedResult (with the fWait flag set to FALSE) in a polling mode to determine when an overlapped operation has completed, get this error code until the operation is complete.
    IO_INCOMPLETE = 996,
    /// The application has initiated an overlapped operation that cannot be completed immediately.
    /// A completion indication will be given later when the operation has been completed.
    IO_PENDING = 997,
    /// Interrupted function call.
    /// A blocking operation was interrupted by a call to WSACancelBlockingCall.
    EINTR = 10004,
    /// File handle is not valid.
    /// The file handle supplied is not valid.
    EBADF = 10009,
    /// Permission denied.
    /// An attempt was made to access a socket in a way forbidden by its access permissions.
    /// An example is using a broadcast address for sendto without broadcast permission being set using setsockopt(SO.BROADCAST).
    /// Another possible reason for the WSAEACCES error is that when the bind function is called (on Windows NT 4.0 with SP4 and later), another application, service, or kernel mode driver is bound to the same address with exclusive access.
    /// Such exclusive access is a new feature of Windows NT 4.0 with SP4 and later, and is implemented by using the SO.EXCLUSIVEADDRUSE option.
    EACCES = 10013,
    /// Bad address.
    /// The system detected an invalid pointer address in attempting to use a pointer argument of a call.
    /// This error occurs if an application passes an invalid pointer value, or if the length of the buffer is too small.
    /// For instance, if the length of an argument, which is a sockaddr structure, is smaller than the sizeof(sockaddr).
    EFAULT = 10014,
    /// Invalid argument.
    /// Some invalid argument was supplied (for example, specifying an invalid level to the setsockopt function).
    /// In some instances, it also refers to the current state of the socket—for instance, calling accept on a socket that is not listening.
    EINVAL = 10022,
    /// Too many open files.
    /// Too many open sockets. Each implementation may have a maximum number of socket handles available, either globally, per process, or per thread.
    EMFILE = 10024,
    /// Resource temporarily unavailable.
    /// This error is returned from operations on nonblocking sockets that cannot be completed immediately, for example recv when no data is queued to be read from the socket.
    /// It is a nonfatal error, and the operation should be retried later.
    /// It is normal for WSAEWOULDBLOCK to be reported as the result from calling connect on a nonblocking SOCK.STREAM socket, since some time must elapse for the connection to be established.
    EWOULDBLOCK = 10035,
    /// Operation now in progress.
    /// A blocking operation is currently executing.
    /// Windows Sockets only allows a single blocking operation—per- task or thread—to be outstanding, and if any other function call is made (whether or not it references that or any other socket) the function fails with the WSAEINPROGRESS error.
    EINPROGRESS = 10036,
    /// Operation already in progress.
    /// An operation was attempted on a nonblocking socket with an operation already in progress—that is, calling connect a second time on a nonblocking socket that is already connecting, or canceling an asynchronous request (WSAAsyncGetXbyY) that has already been canceled or completed.
    EALREADY = 10037,
    /// Socket operation on nonsocket.
    /// An operation was attempted on something that is not a socket.
    /// Either the socket handle parameter did not reference a valid socket, or for select, a member of an fd_set was not valid.
    ENOTSOCK = 10038,
    /// Destination address required.
    /// A required address was omitted from an operation on a socket.
    /// For example, this error is returned if sendto is called with the remote address of ADDR_ANY.
    EDESTADDRREQ = 10039,
    /// Message too long.
    /// A message sent on a datagram socket was larger than the internal message buffer or some other network limit, or the buffer used to receive a datagram was smaller than the datagram itself.
    EMSGSIZE = 10040,
    /// Protocol wrong type for socket.
    /// A protocol was specified in the socket function call that does not support the semantics of the socket type requested.
    /// For example, the ARPA Internet UDP protocol cannot be specified with a socket type of SOCK.STREAM.
    EPROTOTYPE = 10041,
    /// Bad protocol option.
    /// An unknown, invalid or unsupported option or level was specified in a getsockopt or setsockopt call.
    ENOPROTOOPT = 10042,
    /// Protocol not supported.
    /// The requested protocol has not been configured into the system, or no implementation for it exists.
    /// For example, a socket call requests a SOCK.DGRAM socket, but specifies a stream protocol.
    EPROTONOSUPPORT = 10043,
    /// Socket type not supported.
    /// The support for the specified socket type does not exist in this address family.
    /// For example, the optional type SOCK.RAW might be selected in a socket call, and the implementation does not support SOCK.RAW sockets at all.
    ESOCKTNOSUPPORT = 10044,
    /// Operation not supported.
    /// The attempted operation is not supported for the type of object referenced.
    /// Usually this occurs when a socket descriptor to a socket that cannot support this operation is trying to accept a connection on a datagram socket.
    EOPNOTSUPP = 10045,
    /// Protocol family not supported.
    /// The protocol family has not been configured into the system or no implementation for it exists.
    /// This message has a slightly different meaning from WSAEAFNOSUPPORT.
    /// However, it is interchangeable in most cases, and all Windows Sockets functions that return one of these messages also specify WSAEAFNOSUPPORT.
    EPFNOSUPPORT = 10046,
    /// Address family not supported by protocol family.
    /// An address incompatible with the requested protocol was used.
    /// All sockets are created with an associated address family (that is, AF.INET for Internet Protocols) and a generic protocol type (that is, SOCK.STREAM).
    /// This error is returned if an incorrect protocol is explicitly requested in the socket call, or if an address of the wrong family is used for a socket, for example, in sendto.
    EAFNOSUPPORT = 10047,
    /// Address already in use.
    /// Typically, only one usage of each socket address (protocol/IP address/port) is permitted.
    /// This error occurs if an application attempts to bind a socket to an IP address/port that has already been used for an existing socket, or a socket that was not closed properly, or one that is still in the process of closing.
    /// For server applications that need to bind multiple sockets to the same port number, consider using setsockopt (SO.REUSEADDR).
    /// Client applications usually need not call bind at all—connect chooses an unused port automatically.
    /// When bind is called with a wildcard address (involving ADDR_ANY), a WSAEADDRINUSE error could be delayed until the specific address is committed.
    /// This could happen with a call to another function later, including connect, listen, WSAConnect, or WSAJoinLeaf.
    EADDRINUSE = 10048,
    /// Cannot assign requested address.
    /// The requested address is not valid in its context.
    /// This normally results from an attempt to bind to an address that is not valid for the local computer.
    /// This can also result from connect, sendto, WSAConnect, WSAJoinLeaf, or WSASendTo when the remote address or port is not valid for a remote computer (for example, address or port 0).
    EADDRNOTAVAIL = 10049,
    /// Network is down.
    /// A socket operation encountered a dead network.
    /// This could indicate a serious failure of the network system (that is, the protocol stack that the Windows Sockets DLL runs over), the network interface, or the local network itself.
    ENETDOWN = 10050,
    /// Network is unreachable.
    /// A socket operation was attempted to an unreachable network.
    /// This usually means the local software knows no route to reach the remote host.
    ENETUNREACH = 10051,
    /// Network dropped connection on reset.
    /// The connection has been broken due to keep-alive activity detecting a failure while the operation was in progress.
    /// It can also be returned by setsockopt if an attempt is made to set SO.KEEPALIVE on a connection that has already failed.
    ENETRESET = 10052,
    /// Software caused connection abort.
    /// An established connection was aborted by the software in your host computer, possibly due to a data transmission time-out or protocol error.
    ECONNABORTED = 10053,
    /// Connection reset by peer.
    /// An existing connection was forcibly closed by the remote host.
    /// This normally results if the peer application on the remote host is suddenly stopped, the host is rebooted, the host or remote network interface is disabled, or the remote host uses a hard close (see setsockopt for more information on the SO.LINGER option on the remote socket).
    /// This error may also result if a connection was broken due to keep-alive activity detecting a failure while one or more operations are in progress.
    /// Operations that were in progress fail with WSAENETRESET. Subsequent operations fail with WSAECONNRESET.
    ECONNRESET = 10054,
    /// No buffer space available.
    /// An operation on a socket could not be performed because the system lacked sufficient buffer space or because a queue was full.
    ENOBUFS = 10055,
    /// Socket is already connected.
    /// A connect request was made on an already-connected socket.
    /// Some implementations also return this error if sendto is called on a connected SOCK.DGRAM socket (for SOCK.STREAM sockets, the to parameter in sendto is ignored) although other implementations treat this as a legal occurrence.
    EISCONN = 10056,
    /// Socket is not connected.
    /// A request to send or receive data was disallowed because the socket is not connected and (when sending on a datagram socket using sendto) no address was supplied.
    /// Any other type of operation might also return this error—for example, setsockopt setting SO.KEEPALIVE if the connection has been reset.
    ENOTCONN = 10057,
    /// Cannot send after socket shutdown.
    /// A request to send or receive data was disallowed because the socket had already been shut down in that direction with a previous shutdown call.
    /// By calling shutdown a partial close of a socket is requested, which is a signal that sending or receiving, or both have been discontinued.
    ESHUTDOWN = 10058,
    /// Too many references.
    /// Too many references to some kernel object.
    ETOOMANYREFS = 10059,
    /// Connection timed out.
    /// A connection attempt failed because the connected party did not properly respond after a period of time, or the established connection failed because the connected host has failed to respond.
    ETIMEDOUT = 10060,
    /// Connection refused.
    /// No connection could be made because the target computer actively refused it.
    /// This usually results from trying to connect to a service that is inactive on the foreign host—that is, one with no server application running.
    ECONNREFUSED = 10061,
    /// Cannot translate name.
    /// Cannot translate a name.
    ELOOP = 10062,
    /// Name too long.
    /// A name component or a name was too long.
    ENAMETOOLONG = 10063,
    /// Host is down.
    /// A socket operation failed because the destination host is down. A socket operation encountered a dead host.
    /// Networking activity on the local host has not been initiated.
    /// These conditions are more likely to be indicated by the error WSAETIMEDOUT.
    EHOSTDOWN = 10064,
    /// No route to host.
    /// A socket operation was attempted to an unreachable host. See WSAENETUNREACH.
    EHOSTUNREACH = 10065,
    /// Directory not empty.
    /// Cannot remove a directory that is not empty.
    ENOTEMPTY = 10066,
    /// Too many processes.
    /// A Windows Sockets implementation may have a limit on the number of applications that can use it simultaneously.
    /// WSAStartup may fail with this error if the limit has been reached.
    EPROCLIM = 10067,
    /// User quota exceeded.
    /// Ran out of user quota.
    EUSERS = 10068,
    /// Disk quota exceeded.
    /// Ran out of disk quota.
    EDQUOT = 10069,
    /// Stale file handle reference.
    /// The file handle reference is no longer available.
    ESTALE = 10070,
    /// Item is remote.
    /// The item is not available locally.
    EREMOTE = 10071,
    /// Network subsystem is unavailable.
    /// This error is returned by WSAStartup if the Windows Sockets implementation cannot function at this time because the underlying system it uses to provide network services is currently unavailable.
    /// Users should check:
    ///   - That the appropriate Windows Sockets DLL file is in the current path.
    ///   - That they are not trying to use more than one Windows Sockets implementation simultaneously.
    ///   - If there is more than one Winsock DLL on your system, be sure the first one in the path is appropriate for the network subsystem currently loaded.
    ///   - The Windows Sockets implementation documentation to be sure all necessary components are currently installed and configured correctly.
    SYSNOTREADY = 10091,
    /// Winsock.dll version out of range.
    /// The current Windows Sockets implementation does not support the Windows Sockets specification version requested by the application.
    /// Check that no old Windows Sockets DLL files are being accessed.
    VERNOTSUPPORTED = 10092,
    /// Successful WSAStartup not yet performed.
    /// Either the application has not called WSAStartup or WSAStartup failed.
    /// The application may be accessing a socket that the current active task does not own (that is, trying to share a socket between tasks), or WSACleanup has been called too many times.
    NOTINITIALISED = 10093,
    /// Graceful shutdown in progress.
    /// Returned by WSARecv and WSARecvFrom to indicate that the remote party has initiated a graceful shutdown sequence.
    EDISCON = 10101,
    /// No more results.
    /// No more results can be returned by the WSALookupServiceNext function.
    ENOMORE = 10102,
    /// Call has been canceled.
    /// A call to the WSALookupServiceEnd function was made while this call was still processing. The call has been canceled.
    ECANCELLED = 10103,
    /// Procedure call table is invalid.
    /// The service provider procedure call table is invalid.
    /// A service provider returned a bogus procedure table to Ws2_32.dll.
    /// This is usually caused by one or more of the function pointers being NULL.
    EINVALIDPROCTABLE = 10104,
    /// Service provider is invalid.
    /// The requested service provider is invalid.
    /// This error is returned by the WSCGetProviderInfo and WSCGetProviderInfo32 functions if the protocol entry specified could not be found.
    /// This error is also returned if the service provider returned a version number other than 2.0.
    EINVALIDPROVIDER = 10105,
    /// Service provider failed to initialize.
    /// The requested service provider could not be loaded or initialized.
    /// This error is returned if either a service provider's DLL could not be loaded (LoadLibrary failed) or the provider's WSPStartup or NSPStartup function failed.
    EPROVIDERFAILEDINIT = 10106,
    /// System call failure.
    /// A system call that should never fail has failed.
    /// This is a generic error code, returned under various conditions.
    /// Returned when a system call that should never fail does fail.
    /// For example, if a call to WaitForMultipleEvents fails or one of the registry functions fails trying to manipulate the protocol/namespace catalogs.
    /// Returned when a provider does not return SUCCESS and does not provide an extended error code.
    /// Can indicate a service provider implementation error.
    SYSCALLFAILURE = 10107,
    /// Service not found.
    /// No such service is known. The service cannot be found in the specified name space.
    SERVICE_NOT_FOUND = 10108,
    /// Class type not found.
    /// The specified class was not found.
    TYPE_NOT_FOUND = 10109,
    /// No more results.
    /// No more results can be returned by the WSALookupServiceNext function.
    E_NO_MORE = 10110,
    /// Call was canceled.
    /// A call to the WSALookupServiceEnd function was made while this call was still processing. The call has been canceled.
    E_CANCELLED = 10111,
    /// Database query was refused.
    /// A database query failed because it was actively refused.
    EREFUSED = 10112,
    /// Host not found.
    /// No such host is known. The name is not an official host name or alias, or it cannot be found in the database(s) being queried.
    /// This error may also be returned for protocol and service queries, and means that the specified name could not be found in the relevant database.
    HOST_NOT_FOUND = 11001,
    /// Nonauthoritative host not found.
    /// This is usually a temporary error during host name resolution and means that the local server did not receive a response from an authoritative server. A retry at some time later may be successful.
    TRY_AGAIN = 11002,
    /// This is a nonrecoverable error.
    /// This indicates that some sort of nonrecoverable error occurred during a database lookup.
    /// This may be because the database files (for example, BSD-compatible HOSTS, SERVICES, or PROTOCOLS files) could not be found, or a DNS request was returned by the server with a severe error.
    NO_RECOVERY = 11003,
    /// Valid name, no data record of requested type.
    /// The requested name is valid and was found in the database, but it does not have the correct associated data being resolved for.
    /// The usual example for this is a host name-to-address translation attempt (using gethostbyname or WSAAsyncGetHostByName) which uses the DNS (Domain Name Server).
    /// An MX record is returned but no A record—indicating the host itself exists, but is not directly reachable.
    NO_DATA = 11004,
    /// QoS receivers.
    /// At least one QoS reserve has arrived.
    QOS_RECEIVERS = 11005,
    /// QoS senders.
    /// At least one QoS send path has arrived.
    QOS_SENDERS = 11006,
    /// No QoS senders.
    /// There are no QoS senders.
    QOS_NO_SENDERS = 11007,
    /// QoS no receivers.
    /// There are no QoS receivers.
    QOS_NO_RECEIVERS = 11008,
    /// QoS request confirmed.
    /// The QoS reserve request has been confirmed.
    QOS_REQUEST_CONFIRMED = 11009,
    /// QoS admission error.
    /// A QoS error occurred due to lack of resources.
    QOS_ADMISSION_FAILURE = 11010,
    /// QoS policy failure.
    /// The QoS request was rejected because the policy system couldn't allocate the requested resource within the existing policy.
    QOS_POLICY_FAILURE = 11011,
    /// QoS bad style.
    /// An unknown or conflicting QoS style was encountered.
    QOS_BAD_STYLE = 11012,
    /// QoS bad object.
    /// A problem was encountered with some part of the filterspec or the provider-specific buffer in general.
    QOS_BAD_OBJECT = 11013,
    /// QoS traffic control error.
    /// An error with the underlying traffic control (TC) API as the generic QoS request was converted for local enforcement by the TC API.
    /// This could be due to an out of memory error or to an internal QoS provider error.
    QOS_TRAFFIC_CTRL_ERROR = 11014,
    /// QoS generic error.
    /// A general QoS error.
    QOS_GENERIC_ERROR = 11015,
    /// QoS service type error.
    /// An invalid or unrecognized service type was found in the QoS flowspec.
    QOS_ESERVICETYPE = 11016,
    /// QoS flowspec error.
    /// An invalid or inconsistent flowspec was found in the QOS structure.
    QOS_EFLOWSPEC = 11017,
    /// Invalid QoS provider buffer.
    /// An invalid QoS provider-specific buffer.
    QOS_EPROVSPECBUF = 11018,
    /// Invalid QoS filter style.
    /// An invalid QoS filter style was used.
    QOS_EFILTERSTYLE = 11019,
    /// Invalid QoS filter type.
    /// An invalid QoS filter type was used.
    QOS_EFILTERTYPE = 11020,
    /// Incorrect QoS filter count.
    /// An incorrect number of QoS FILTERSPECs were specified in the FLOWDESCRIPTOR.
    QOS_EFILTERCOUNT = 11021,
    /// Invalid QoS object length.
    /// An object with an invalid ObjectLength field was specified in the QoS provider-specific buffer.
    QOS_EOBJLENGTH = 11022,
    /// Incorrect QoS flow count.
    /// An incorrect number of flow descriptors was specified in the QoS structure.
    QOS_EFLOWCOUNT = 11023,
    /// Unrecognized QoS object.
    /// An unrecognized object was found in the QoS provider-specific buffer.
    QOS_EUNKOWNPSOBJ = 11024,
    /// Invalid QoS policy object.
    /// An invalid policy object was found in the QoS provider-specific buffer.
    QOS_EPOLICYOBJ = 11025,
    /// Invalid QoS flow descriptor.
    /// An invalid QoS flow descriptor was found in the flow descriptor list.
    QOS_EFLOWDESC = 11026,
    /// Invalid QoS provider-specific flowspec.
    /// An invalid or inconsistent flowspec was found in the QoS provider-specific buffer.
    QOS_EPSFLOWSPEC = 11027,
    /// Invalid QoS provider-specific filterspec.
    /// An invalid FILTERSPEC was found in the QoS provider-specific buffer.
    QOS_EPSFILTERSPEC = 11028,
    /// Invalid QoS shape discard mode object.
    /// An invalid shape discard mode object was found in the QoS provider-specific buffer.
    QOS_ESDMODEOBJ = 11029,
    /// Invalid QoS shaping rate object.
    /// An invalid shaping rate object was found in the QoS provider-specific buffer.
    QOS_ESHAPERATEOBJ = 11030,
    /// Reserved policy QoS element type.
    /// A reserved policy element was found in the QoS provider-specific buffer.
    QOS_RESERVED_PETYPE = 11031,
    _,
};
