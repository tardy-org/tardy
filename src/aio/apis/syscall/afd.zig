// TODO: this is a transitional layer to be removed after a Zig 0.16.0
// compatible release of tardy is released
// https://github.com/ryuapp/zig-mirror/commit/9ac1386c10736bc249f3891f34f23424531917a5
// https://github.com/ryuapp/zig-mirror/blob/b600b6e5e08bc443ef9742b36d51c95715c8150a/lib/std/os/windows/ws2_32.zig
const std = @import("std");
const windows = std.os.windows;
const ws2_32 = windows.ws2_32;
const tardy = @import("../../../lib.zig");
const Socket = tardy.Socket;
const Io = std.Io;
const mem = std.mem;
const Threaded = Io.Threaded;
const net = std.Io.net;
const IpAddress = net.IpAddress;
const builtin = @import("builtin");
const native_os = builtin.os.tag;

pub const max_iovecs_len = 8;

pub fn netReadWindows(socket_handle: windows.HANDLE, data: [][]u8) net.Stream.Reader.Error!usize {
    var iovecs: [max_iovecs_len]windows.AFD.WSABUF(.@"var") = undefined;
    var len: u32 = 0;
    for (data) |buf| {
        if (iovecs.len - len == 0) break;
        addAfdBuf(.@"var", &iovecs, &len, buf);
    }

    const iosb = try deviceIoControl(&.{
        .file = .{ .handle = socket_handle, .flags = .{ .nonblocking = true } },
        .code = windows.IOCTL.AFD.RECEIVE,
        .in = @ptrCast(&windows.AFD.RECV_INFO{
            .BufferArray = &iovecs,
            .BufferCount = len,
            .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
            .TdiFlags = .{ .NORMAL = true },
        }),
    });
    switch (iosb.u.Status) {
        .SUCCESS => return iosb.Information,
        .CANCELLED => unreachable,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        .CONNECTION_RESET => return error.ConnectionResetByPeer,
        else => |status| return windows.unexpectedStatus(status),
    }
}

pub fn netWriteWindows(
    handle: net.Socket.Handle,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) net.Stream.Writer.Error!usize {
    var iovecs: [max_iovecs_len]windows.AFD.WSABUF(.@"const") = undefined;
    var len: u32 = 0;
    addAfdBuf(.@"const", &iovecs, &len, header);
    for (data[0 .. data.len - 1]) |bytes| addAfdBuf(.@"const", &iovecs, &len, bytes);
    const pattern = data[data.len - 1];
    var backup_buffer: [64]u8 = undefined;
    if (iovecs.len - len != 0) switch (splat) {
        0 => {},
        1 => addAfdBuf(.@"const", &iovecs, &len, pattern),
        else => switch (pattern.len) {
            0 => {},
            1 => {
                const splat_buffer = &backup_buffer;
                const memset_len = @min(splat_buffer.len, splat);
                const buf = splat_buffer[0..memset_len];
                @memset(buf, pattern[0]);
                addAfdBuf(.@"const", &iovecs, &len, buf);
                var remaining_splat = splat - buf.len;
                while (remaining_splat > splat_buffer.len and len < iovecs.len) {
                    addAfdBuf(.@"const", &iovecs, &len, splat_buffer);
                    remaining_splat -= splat_buffer.len;
                }
                addAfdBuf(.@"const", &iovecs, &len, splat_buffer[0..@min(remaining_splat, splat_buffer.len)]);
            },
            else => for (0..@min(splat, iovecs.len - len)) |_| {
                addAfdBuf(.@"const", &iovecs, &len, pattern);
            },
        },
    };

    const iosb = try deviceIoControl(&.{
        .file = .{ .handle = handle, .flags = .{ .nonblocking = true } },
        .code = windows.IOCTL.AFD.SEND,
        .in = @ptrCast(&windows.AFD.SEND_INFO{
            .BufferArray = &iovecs,
            .BufferCount = len,
            .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
            .TdiFlags = .{},
        }),
    });
    switch (iosb.u.Status) {
        .SUCCESS => return iosb.Information,
        .CANCELLED => unreachable,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        .CONNECTION_RESET => return error.ConnectionResetByPeer,
        else => |status| return windows.unexpectedStatus(status),
    }
}

pub const BindOptions = struct {
    /// Allow the socket to send datagrams to broadcast addresses.
    /// When not enabled any attempt to send datagrams to a broadcast address
    /// will fail with `error.AccessDenied`
    allow_broadcast: bool = false,
};

pub const BindError = error{
    SystemResources,
    ConnectionRefused,
    AddressInUse,
    Canceled,
    Unexpected,
};

pub fn netBindIpWindows(
    socket_handle: windows.HANDLE,
    address: *const Socket.Address,
    options: BindOptions,
) BindError!Socket.Address {
    const bound_address = try bindSocketIpAfd(
        socket_handle,
        address,
        .Active,
    );
    if (options.allow_broadcast) try setSocketOptionAfd(
        socket_handle,
        ws2_32.SOL.SOCKET,
        ws2_32.SO.BROADCAST,
        &mem.toBytes(@as(u32, 1)),
    );
    return bound_address;
}

pub fn netListenIpWindows(
    socket: windows.HANDLE,
    options: IpAddress.ListenOptions,
) IpAddress.ListenError!void {
    if (options.reuse_address) try setSocketOptionAfd(
        socket,
        ws2_32.SOL.SOCKET,
        ws2_32.SO.REUSEADDR,
        &mem.toBytes(@as(u32, 1)),
    );
    // const bound_address = try bindSocketIpAfd(socket_handle, address, .Passive);
    switch ((try deviceIoControl(&.{
        .file = .{
            .handle = socket,
            .flags = .{ .nonblocking = true },
        },
        .code = windows.IOCTL.AFD.START_LISTEN,
        .in = @ptrCast(&windows.AFD.LISTEN_INFO{
            .UseSAN = .FALSE,
            .MaximumConnectionQueue = options.kernel_backlog,
            .UseDelayedAcceptance = .FALSE,
        }),
    })).u.Status) {
        .SUCCESS => {},
        .CANCELLED => unreachable,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => |status| return windows.unexpectedStatus(status),
    }
}

pub fn netConnectIpWindows(
    socket: windows.HANDLE,
    address: *const Socket.Address,
) IpAddress.ConnectError!void {
    try setSocketOptionAfd(
        socket,
        ws2_32.SOL.SOCKET,
        ws2_32.SO.REUSE_UNICASTPORT,
        &mem.toBytes(@as(u32, 1)),
    );

    const wildcard_addr: Socket.Address = .wildcard;

    // TODO: resouldn't need this
    _ = bindSocketIpAfd(
        socket,
        &wildcard_addr,
        .Active,
    ) catch |err| switch (err) {
        error.AddressInUse => return error.Unexpected,
        else => |e| return e,
    };

    const Storage = extern struct {
        Reserved0: [3]usize = @splat(0),
        Socket: Socket.Native,
    };
    var storage: Storage = .{ .Socket = undefined };

    const addr_len: usize = blk: switch (address.*) {
        .ip => |ip| switch (ip) {
            .ip4 => {
                const sock = address.toNative();
                storage.Socket.in = sock.in;
                break :blk @sizeOf(ws2_32.sockaddr.in);
            },
            .ip6 => {
                const sock = address.toNative();
                storage.Socket.in6 = sock.in6;
                break :blk @sizeOf(ws2_32.sockaddr.in6);
            },
        },
        else => unreachable,
    };

    const connect_in_opt = @as([]const u8, @ptrCast(&storage))[0 .. @offsetOf(Storage, "Socket") + addr_len];

    switch ((try deviceIoControl(&.{
        .file = .{
            .handle = socket,
            .flags = .{ .nonblocking = true },
        },
        .code = windows.IOCTL.AFD.CONNECT,
        .in = connect_in_opt,
    })).u.Status) {
        .SUCCESS => return,
        .CANCELLED => unreachable,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        .CONNECTION_REFUSED => return error.ConnectionRefused,
        else => |status| return windows.unexpectedStatus(status),
    }
}

pub const AcceptOptions = struct {
    mode: net.Socket.Mode,
    protocol: ?net.Protocol,
};

pub fn netAcceptWindows(
    listen_handle: net.Socket.Handle,
    addr: ?*Socket.Address,
    options: AcceptOptions,
) !Socket.Handle {
    const Storage = extern struct {
        Info: windows.AFD.LISTEN_RESPONSE_INFO,
        RemoteSocket: Socket.Native,
    };

    var storage: Storage = undefined;
    defer if (addr) |addr_| {
        addr_.* = storage.RemoteSocket.toAddress();
    };

    switch ((try deviceIoControl(&.{
        .file = .{
            .handle = listen_handle,
            .flags = .{ .nonblocking = true },
        },
        .code = windows.IOCTL.AFD.WAIT_FOR_LISTEN,
        .out = @ptrCast(&storage),
    })).u.Status) {
        .SUCCESS => {},
        .CANCELLED => unreachable,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => |status| return windows.unexpectedStatus(status),
    }
    errdefer deferAcceptAfd(listen_handle, storage.Info);

    const accept_handle = openSocketAfd(
        storage.RemoteSocket.any.family,
        .{
            .mode = options.mode,
            .protocol = options.protocol,
        },
    ) catch |err| switch (err) {
        error.AddressFamilyUnsupported => return error.Unexpected,
        error.ProtocolUnsupportedByAddressFamily => return error.Unexpected,
        else => |e| return e,
    };
    errdefer windows.CloseHandle(accept_handle);

    switch ((try deviceIoControl(&.{
        .file = .{
            .handle = listen_handle,
            .flags = .{ .nonblocking = true },
        },
        .code = windows.IOCTL.AFD.ACCEPT,
        .in = @ptrCast(&windows.AFD.ACCEPT_INFO{
            .UseSAN = .FALSE,
            .Sequence = storage.Info.Sequence,
            .AcceptHandle = accept_handle,
        }),
    })).u.Status) {
        .SUCCESS => {},
        .CANCELLED => unreachable,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => |status| return windows.unexpectedStatus(status),
    }

    return accept_handle;
}

fn deferAcceptAfd(listen_handle: net.Socket.Handle, info: windows.AFD.LISTEN_RESPONSE_INFO) void {
    switch ((deviceIoControl(&.{
        .file = .{
            .handle = listen_handle,
            .flags = .{ .nonblocking = true },
        },
        .code = windows.IOCTL.AFD.DEFER_ACCEPT,
        .in = @ptrCast(&windows.AFD.DEFER_ACCEPT_INFO{
            .Sequence = info.Sequence,
            .Reject = .FALSE,
        }),
    }) catch |err| switch (err) {
        error.Canceled => unreachable, // blocked
    }).u.Status) {
        .SUCCESS => {},
        .CANCELLED => unreachable,
        else => |status| windows.unexpectedStatus(status) catch {},
    }
}

pub fn bindSocketIpAfd(
    socket_handle: net.Socket.Handle,
    sock_addr: *const Socket.Address,
    mode: windows.AFD.BIND_INFO.MODE,
) BindError!Socket.Address {
    const Storage = extern struct {
        Info: windows.AFD.BIND_INFO,
        Socket: Socket.Native,
    };
    var storage: Storage = .{
        .Info = .{ .Mode = mode },
        .Socket = undefined,
    };

    const sock_len: usize = blk: switch (sock_addr.*) {
        .ip => |addr| switch (addr) {
            .ip4 => {
                const sock = sock_addr.toNative();
                storage.Socket.in = sock.in;
                break :blk @sizeOf(ws2_32.sockaddr.in);
            },
            .ip6 => {
                const sock = sock_addr.toNative();
                storage.Socket.in6 = sock.in6;
                break :blk @sizeOf(ws2_32.sockaddr.in6);
            },
        },
        // unix not supported yet
        else => unreachable,
    };

    const bind_in_opt = @as([]const u8, @ptrCast(&storage))[0 .. @offsetOf(Storage, "Socket") + sock_len];

    const bind_out_opt = @as([]u8, @ptrCast(&storage.Socket))[0..sock_len];

    switch ((try deviceIoControl(&.{
        .file = .{
            .handle = socket_handle,
            .flags = .{ .nonblocking = true },
        },
        .code = windows.IOCTL.AFD.BIND,
        .in = bind_in_opt,
        .out = bind_out_opt,
    })).u.Status) {
        .SUCCESS => {},
        .CANCELLED => unreachable,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        .SHARING_VIOLATION => return error.AddressInUse,
        else => |status| return windows.unexpectedStatus(status),
    }
    return storage.Socket.toAddress();
}

pub const SetSockError = error{
    SystemResources,
    Unexpected,
    Canceled,
};

pub fn setSocketOptionAfd(
    wsocket: net.Socket.Handle,
    level: i32,
    opt_name: u32,
    opt_val_bytes: []const u8,
) SetSockError!void {
    try socketOptionAfd(
        wsocket,
        .set,
        level,
        opt_name,
        opt_val_bytes,
    );
}

fn socketOptionAfd(wsocket: net.Socket.Handle, mode: windows.AFD.SOCKOPT_INFO.Mode, level: i32, opt_name: u32, opt_val_bytes: []const u8) !void {
    switch ((try deviceIoControl(&.{
        .file = .{
            .handle = wsocket,
            .flags = .{ .nonblocking = true },
        },
        .code = windows.IOCTL.AFD.SOCKOPT,
        .in = @ptrCast(&windows.AFD.SOCKOPT_INFO{
            .mode = mode,
            .level = level,
            .optname = opt_name,
            .optval = opt_val_bytes.ptr,
            .optlen = opt_val_bytes.len,
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
}

pub const SocketOptions = struct {
    /// The socket is restricted to sending and receiving IPv6 packets only.
    /// In this case, an IPv4 and an IPv6 application can bind to a single port
    /// at the same time.
    ip6_only: bool = false,
    mode: net.Socket.Mode,
    protocol: ?net.Protocol = null,
};

pub const SocketError = error{
    AddressFamilyUnsupported,
    ProtocolUnsupportedByAddressFamily,
    Unexpected,
};

pub fn openSocketAfd(family: ws2_32.ADDRESS_FAMILY, options: SocketOptions) SocketError!Socket.Handle {
    const mode, const protocol = Threaded.posixSocketModeProtocol(
        family,
        options.mode,
        options.protocol,
    ) catch unreachable;
    const device_name = windows.AFD.DEVICE_NAME ++ .{ '\\', 'E', 'n', 'd', 'p', 'o', 'i', 'n', 't' };
    var device_str: windows.UNICODE_STRING = .init(device_name);

    const access: windows.ACCESS_MASK = .{
        .STANDARD = .{
            .RIGHTS = .{ .WRITE_DAC = true },
            .SYNCHRONIZE = true,
        },
        .GENERIC = .{ .WRITE = true, .READ = true },
    };

    const ea_info: windows.AFD.OPEN_PACKET.FULL_EA_INFORMATION = .{
        .Value = .{
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
        },
    };

    var handle: windows.HANDLE = undefined;
    var iosb: windows.IO_STATUS_BLOCK = undefined;

    while (true) switch (windows.ntdll.NtCreateFile(
        &handle,
        access,
        &.{
            .ObjectName = &device_str,
        },
        &iosb,
        null,
        .{},
        .{ .READ = true, .WRITE = true },
        .OPEN_IF,
        .{ .IO = .ASYNCHRONOUS },
        &ea_info,
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

fn addAfdBuf(
    comptime mutability: windows.AFD.Mutability,
    iovecs: []windows.AFD.WSABUF(mutability),
    len: *u32,
    bytes: switch (mutability) {
        .@"const" => []const u8,
        .@"var" => []u8,
    },
) void {
    if (bytes.len == 0) return;
    const cap = std.math.maxInt(u32);
    var remaining = bytes;
    while (remaining.len > cap) {
        if (iovecs.len - len.* == 0) return;
        iovecs[len.*] = .{ .buf = remaining.ptr, .len = cap };
        len.* += 1;
        remaining = remaining[cap..];
    } else {
        @branchHint(.likely);
        if (iovecs.len - len.* == 0) return;
        iovecs[len.*] = .{ .buf = remaining.ptr, .len = @intCast(remaining.len) };
        len.* += 1;
    }
}

const default_fn_align = switch (builtin.mode) {
    .Debug, .ReleaseSafe, .ReleaseFast => switch (builtin.cpu.arch) {
        .arm, .thumb => 4,
        .aarch64, .x86, .x86_64 => 16,
        else => |arch| @compileError("Unsupported architecture: " ++ @tagName(arch)),
    },
    .ReleaseSmall => 1,
};

pub const apc_align = @max(default_fn_align, 2);

/// This is either usize or u32. Since, either is fine, let's use the same
/// `addBuf` function for both writing to a file and sending network messages.
const iovlen_t = switch (native_os) {
    .wasi => u32,
    else => @FieldType(ws2_32.msghdr_const, "iovlen"),
};
