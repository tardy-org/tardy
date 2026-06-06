// afd_poll.zig — zero ws2_32 dependency, pure ntdll + Wine AFD IOCTLs
//
// Build: zig build-exe afd_poll.zig -target x86_64-windows-gnu
// Run:   wine afd_poll.exe

const std = @import("std");
const debug = std.debug;
const posix = std.posix;
const Io = std.Io;
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const is_windows = native_os == .windows;
const log = std.log.scoped(.poll);
const windows = std.os.windows;
const ntdll = windows.ntdll;
const ws2_32 = windows.ws2_32;
const IOCTL = windows.IOCTL;
const HANDLE = windows.HANDLE;
const ULONG = windows.ULONG;
const NTSTATUS = windows.NTSTATUS;

// ── IOCTL construction ────────────────────────────────────────────────────────

// Real Windows AFD: FILE_DEVICE_NETWORK (0x12), METHOD_NEITHER (3)
fn afd_ioctl_neither(func: u32) u32 {
    return (0x00000012 << 16) | (0 << 14) | (func << 2) | 3;
}

// Wine AFD (Wine-specific IOCTLs): FILE_DEVICE_NETWORK (0x12), METHOD_BUFFERED (0)
fn wine_afd_ioc(x: u32) u32 {
    return (0x00000012 << 16) | (0 << 14) | (x << 2) | 0;
}

// Wine's poll uses FILE_DEVICE_BEEP (0x1), METHOD_BUFFERED (0)
fn wine_afd_poll_ioc(func: u32) u32 {
    return (0x00000001 << 16) | (0 << 14) | (func << 2) | 0;
}

const IOCTL_AFD_WINE_CREATE = wine_afd_ioc(200);
const IOCTL_AFD_WINE_CONNECT = wine_afd_ioc(203);
const IOCTL_AFD_WINE_RECVMSG = wine_afd_ioc(205);
const IOCTL_AFD_WINE_SENDMSG = wine_afd_ioc(206);
const IOCTL_AFD_POLL = wine_afd_poll_ioc(0x809); // 0x809 per wine/afd.h

// ── ntdll imports ─────────────────────────────────────────────────────────────

pub const NtCreateFile = windows.ntdll.NtCreateFile;

pub const NtDeviceIoControlFile = windows.ntdll.NtDeviceIoControlFile;
pub const NtReadFile = windows.ntdll.NtReadFile;

pub const NtWriteFile = windows.ntdll.NtWriteFile;
pub const NtClose = windows.ntdll.NtClose;

pub const NtCreateEvent = windows.ntdll.NtCreateEvent;
pub const NtWaitForSingleObject = windows.ntdll.NtWaitForSingleObject;

// ── sockaddr ──────────────────────────────────────────────────────────────────

const sockaddr_in = extern struct {
    sin_family: i16,
    sin_port: u16, // network byte order
    sin_addr: u32, // network byte order
    sin_zero: [8]u8 = @splat(0),
};

fn htons(port: u16) u16 {
    return @byteSwap(port);
}

fn inetAddr(s: []const u8) !u32 {
    var result: u32 = 0;
    var octet: u32 = 0;
    var shift: u5 = 0;
    var dots: u32 = 0;
    for (s) |c| {
        if (c == '.') {
            if (dots == 3 or octet > 255) return error.InvalidAddress;
            result |= octet << shift;
            shift +%= 8;
            octet = 0;
            dots += 1;
        } else if (c >= '0' and c <= '9') {
            octet = octet * 10 + (c - '0');
            if (octet > 255) return error.InvalidAddress;
        } else return error.InvalidAddress;
    }
    if (dots != 3 or octet > 255) return error.InvalidAddress;
    result |= octet << shift;
    return result;
}

// ── Wine AFD create params (from wine/include/wine/afd.h) ─────────────────────
// struct afd_create_params { int family, type, protocol; unsigned int flags; }

const AfdCreateParams = extern struct {
    family: i32,
    type: i32,
    protocol: i32,
    flags: u32,
};

// ── createSocket via IOCTL_AFD_WINE_CREATE ────────────────────────────────────
// Wine creates sockets by opening \Device\Afd then sending IOCTL_AFD_WINE_CREATE.

// fn createSocket(family: i32, sock_type: i32, protocol: i32) !HANDLE {
//     const path = std.unicode.utf8ToUtf16LeStringLiteral("\\Device\\Afd");
//     var name_str = windows.UNICODE_STRING{
//         .Length = @intCast(path.len * 2),
//         .MaximumLength = @intCast(path.len * 2),
//         .Buffer = @constCast(path.ptr),
//     };
//     var obj_attr = std.mem.zeroes(windows.OBJECT.ATTRIBUTES);
//     obj_attr.Length = @sizeOf(windows.OBJECT.ATTRIBUTES);
//     obj_attr.ObjectName = &name_str;

//     var iosb: windows.IO_STATUS_BLOCK = std.mem.zeroes(windows.IO_STATUS_BLOCK);
//     var handle: HANDLE = undefined;

//     // SYNCHRONIZE | GENERIC_READ | GENERIC_WRITE
//     const access: u32 = 0x00100000 | 0x80000000 | 0x40000000;
//     _ = access; // autofix

//     // var status = NtCreateFile(
//     //     &handle,
//     //     access,
//     //     &obj_attr,
//     //     &iosb,
//     //     null,
//     //     0,
//     //     windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
//     //     windows.FILE_OPEN_IF,
//     //     // FILE_SYNCHRONOUS_IO_NONALERT | FILE_NON_DIRECTORY_FILE
//     //     0x00000020 | 0x00000040,
//     //     null,
//     //     0,
//     // );
//     var status = NtCreateFile(
//         &handle,
//         // 0x00100000 | 0x00080000 | 0x00120000, // GENERIC_READ|WRITE|SYNCHRONIZE
//         .{
//             .GENERIC = .{
//                 .READ = true,
//                 .WRITE = true,
//             },
//             .STANDARD = .{ .SYNCHRONIZE = true },
//         },
//         &obj_attr,
//         &iosb,
//         null,
//         .{},
//         .{ .READ = true, .WRITE = true },
//         .OPEN_IF,
//         .{ .IO = .ASYNCHRONOUS },
//         null,
//         0,
//     );
//     log.debug("status of NtCreateFile in createSocket is {t}", .{status});

//     if (status != .SUCCESS) {
//         std.debug.print("NtCreateFile failed: {t}\n", .{status});
//         return error.CreateFileFailed;
//     }

//     // Send the socket parameters via IOCTL_AFD_WINE_CREATE
//     const params = AfdCreateParams{
//         .family = family,
//         .type = sock_type,
//         .protocol = protocol,
//         .flags = 0,
//     };

//     var iosb2 = std.mem.zeroes(windows.IO_STATUS_BLOCK);
//     status = NtDeviceIoControlFile(
//         handle,
//         null,
//         null,
//         null,
//         &iosb2,
//         @bitCast(@as(windows.ULONG, IOCTL_AFD_WINE_CREATE)),
//         &params,
//         @sizeOf(AfdCreateParams),
//         null,
//         0,
//     );
//     if (status != .SUCCESS) {
//         _ = NtClose(handle);
//         std.debug.print("IOCTL_AFD_WINE_CREATE failed: 0x{t}\n", .{status});
//         return error.CreateSocketFailed;
//     }
//     return handle;
// }
fn createSocket(family: i32, sock_type: i32, protocol: u32) !HANDLE {
    const path = std.unicode.utf8ToUtf16LeStringLiteral("\\Device\\Afd\\Endpoint");

    var name_str: windows.UNICODE_STRING = .{
        .Length = @intCast(path.len * 2),
        .MaximumLength = @intCast(path.len * 2),
        .Buffer = @constCast(path.ptr),
    };

    const obj_attr: windows.OBJECT.ATTRIBUTES = .{
        .Length = @sizeOf(windows.OBJECT.ATTRIBUTES),
        .RootDirectory = null,
        .ObjectName = &name_str,
        .Attributes = .{
            .CASE_INSENSITIVE = true,
            .INHERIT = true,
        },
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };

    const ea_buffer: windows.AFD.OPEN_PACKET.FULL_EA_INFORMATION = .{
        .Value = .{
            .EndpointType = .{
                .CONNECTIONLESS = switch (sock_type) {
                    ws2_32.SOCK.STREAM, ws2_32.SOCK.SEQPACKET, ws2_32.SOCK.RDM => false,
                    ws2_32.SOCK.DGRAM, ws2_32.SOCK.RAW => true,
                    else => unreachable,
                },
                .MESSAGEMODE = sock_type != ws2_32.SOCK.STREAM,
                .RAW = sock_type == ws2_32.SOCK.RAW,
            },
            .GroupID = 0,
            .AddressFamily = family,
            .SocketType = @bitCast(sock_type),
            .Protocol = @bitCast(protocol),
            .TransportDeviceNameLength = 0,
            .TransportDeviceName = undefined,
        },
    };
    var iosb = std.mem.zeroes(windows.IO_STATUS_BLOCK);

    var socket_handle: HANDLE = undefined;

    while (true) switch (ntdll.NtCreateFile(
        &socket_handle,
        .{
            .GENERIC = .{ .READ = true, .WRITE = true },
            .STANDARD = .{ .SYNCHRONIZE = true },
        },
        &obj_attr,
        &iosb,
        null,
        .{},
        .{ .READ = true, .WRITE = true },
        .OPEN_IF,
        .{ .IO = .SYNCHRONOUS_NONALERT },
        &ea_buffer,
        @sizeOf(@TypeOf(ea_buffer)),
    )) {
        .SUCCESS => {
            return socket_handle;
        },
        .CANCELLED => {
            continue;
        },
        .PROTOCOL_NOT_SUPPORTED => return error.AddressFamilyUnsupported,
        .NO_SUCH_FILE => return error.ProtocolUnsupportedByAddressFamily,
        else => |s| {
            log.err("failed to create socket handle: status {t}", .{s});
            return windows.unexpectedStatus(s);
        },
    };
}

// ── connect via IOCTL_AFD_WINE_CONNECT ───────────────────────────────────────
// struct afd_connect_params { int addr_len; int synchronous; }
// followed immediately in memory by the sockaddr.

const AfdConnectParams = extern struct {
    addr_len: i32,
    synchronous: i32, // 1 = blocking connect
    addr: sockaddr_in,
};

fn waitIosb(event: HANDLE, iosb: *windows.IO_STATUS_BLOCK, status: NTSTATUS) !void {
    swi: switch (status) {
        .PENDING => {
            _ = NtWaitForSingleObject(
                event,
                .FALSE, // what happens when alertable is true
                null,
            );
            continue :swi iosb.u.Status;
        },
        .SUCCESS, .END_OF_FILE => return,
        else => |s| {
            std.debug.print("operation failed: 0x{t}\n", .{s});
            return error.OperationFailed;
        },
    }
}

fn connectSocket(handle: HANDLE, addr: sockaddr_in) !void {
    const params: AfdConnectParams = .{
        .addr_len = @sizeOf(sockaddr_in),
        .synchronous = 1,
        .addr = addr,
    };

    // create a manual-reset event to wait on
    var event: HANDLE = undefined;
    const es = NtCreateEvent(
        &event,
        @bitCast(@as(windows.DWORD, 0x1F0003)),
        null,
        .Notification,
        .FALSE,
    );
    if (es != .SUCCESS) return error.CreateEventFailed;
    defer _ = NtClose(event);

    var iosb = std.mem.zeroes(windows.IO_STATUS_BLOCK);
    const status = NtDeviceIoControlFile(
        handle,
        event,
        null,
        null,
        &iosb,
        IOCTL.AFD.CONNECT,
        &params,
        @sizeOf(AfdConnectParams),
        null,
        0,
    );

    switch (status) {
        .SUCCESS => {},
        .PENDING => {
            waitIosb(event, &iosb, status) catch |err| switch (err) {
                error.OperationFailed => return error.ConnectFailed,
                else => unreachable,
            };
        },
        else => {
            std.debug.print("IOCTL_AFD_WINE_CONNECT failed: 0x{t}\n", .{status});
            return error.ConnectFailed;
        },
    }
}

const net = std.Io.net;
pub const PosixAddress = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,
};

const UnixAddress = extern union {
    any: posix.sockaddr,
    un: posix.sockaddr.un,
};

pub const ConnectOptions = struct {
    mode: i32,
    protocol: ?net.Protocol = null,
};

fn netConnectIpWindows(
    address: *const net.IpAddress,
    options: ConnectOptions,
) net.IpAddress.ConnectError!net.Socket {
    const family = posixAddressFamily(address);
    const socket_handle = try createSocket(family, options.mode, @intFromEnum(if (options.protocol) |protocal| protocal else .hopopts));
    errdefer windows.CloseHandle(socket_handle);
    try setSocketOptionAfd(socket_handle, ws2_32.SOL.SOCKET, ws2_32.SO.REUSE_UNICASTPORT, true);
    const bound_address = bindSocketIpAfd(socket_handle, &switch (address.*) {
        .ip4 => .{ .ip4 = .unspecified(0) },
        .ip6 => .{ .ip6 = .unspecified(0) },
    }, .Active) catch |err| switch (err) {
        error.AddressInUse => return error.Unexpected,
        else => |e| return e,
    };
    const Storage = extern struct { Reserved0: [3]usize = @splat(0), Address: PosixAddress };
    var storage: Storage = .{ .Address = undefined };
    const addr_len = addressToPosix(address, &storage.Address);
    switch ((try deviceIoControl(&.{
        .file = .{ .handle = socket_handle, .flags = .{ .nonblocking = true } },
        .code = windows.IOCTL.AFD.CONNECT,
        .in = @as([]const u8, @ptrCast(&storage))[0 .. @offsetOf(Storage, "Address") + addr_len],
    })).u.Status) {
        .SUCCESS => {},
        .CANCELLED => unreachable,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        .CONNECTION_REFUSED => return error.ConnectionRefused,
        else => |status| return windows.unexpectedStatus(status),
    }
    log.debug("connect data is {any}\nas str is `{s}`", .{
        storage,
        @as([]const u8, @ptrCast(&storage))[0 .. @offsetOf(Storage, "Address") + addr_len],
    });
    return .{ .handle = socket_handle, .address = bound_address };
}

fn bindSocketIpAfd(socket_handle: net.Socket.Handle, address: *const net.IpAddress, mode: windows.AFD.BIND_INFO.MODE) !net.IpAddress {
    const Storage = extern struct { Info: windows.AFD.BIND_INFO, Address: PosixAddress };
    var storage: Storage = .{ .Info = .{ .Mode = mode }, .Address = undefined };
    const addr_len = addressToPosix(address, &storage.Address);
    switch ((try deviceIoControl(&.{
        .file = .{ .handle = socket_handle, .flags = .{ .nonblocking = true } },
        .code = windows.IOCTL.AFD.BIND,
        .in = @as([]const u8, @ptrCast(&storage))[0 .. @offsetOf(Storage, "Address") + addr_len],
        .out = @as([]u8, @ptrCast(&storage.Address))[0..addr_len],
    })).u.Status) {
        .SUCCESS => {},
        .CANCELLED => unreachable,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        .SHARING_VIOLATION => return error.AddressInUse,
        else => |status| return windows.unexpectedStatus(status),
    }
    return addressFromPosix(&storage.Address);
}

fn bindSocketUnixAfd(socket_handle: net.Socket.Handle, address: *const UnixAddress) !void {
    const Storage = extern struct { Info: windows.AFD.BIND_INFO, Address: UnixAddress };
    var storage: Storage = .{ .Info = .{ .Mode = .Unix }, .Address = undefined };
    const addr_len = addressUnixToPosix(address, &storage.Address);
    switch ((try deviceIoControl(&.{
        .file = .{ .handle = socket_handle, .flags = .{ .nonblocking = true } },
        .code = windows.IOCTL.AFD.BIND,
        .in = @as([]const u8, @ptrCast(&storage))[0 .. @offsetOf(Storage, "Address") + addr_len],
        .out = @ptrCast(&storage.Address),
    })).u.Status) {
        .SUCCESS => {},
        .CANCELLED => unreachable,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        .ADDRESS_ALREADY_EXISTS => return error.AddressInUse,
        else => |status| return windows.unexpectedStatus(status),
    }
}

fn setSocketOptionAfd(socket: net.Socket.Handle, level: i32, opt_name: u32, opt_val: anytype) !void {
    try socketOptionAfd(socket, .set, level, opt_name, @ptrCast(@constCast(&opt_val)));
}

fn socketOptionAfd(socket: net.Socket.Handle, mode: windows.AFD.SOCKOPT_INFO.Mode, level: i32, opt_name: u32, opt_val: []u8) !void {
    switch ((try deviceIoControl(&.{
        .file = .{ .handle = socket, .flags = .{ .nonblocking = true } },
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

pub const apc_align = @max(default_fn_align, 2);

const default_fn_align = switch (builtin.mode) {
    .Debug, .ReleaseSafe, .ReleaseFast => switch (builtin.cpu.arch) {
        else => |arch| @compileError("Unsupported architecture: " ++ @tagName(arch)),
        .arm, .thumb => 4,
        .aarch64, .x86, .x86_64 => 16,
    },
    .ReleaseSmall => 1,
};

pub fn waitForApcOrAlert() void {
    const infinite_timeout: windows.LARGE_INTEGER = std.math.minInt(windows.LARGE_INTEGER);
    _ = windows.ntdll.NtDelayExecution(.TRUE, &infinite_timeout);
}

fn flagApc(userdata: ?*anyopaque, _: *windows.IO_STATUS_BLOCK, _: windows.ULONG) align(apc_align) callconv(.winapi) void {
    const flag: *bool = @ptrCast(userdata);
    flag.* = true;
}

fn deviceIoControl(o: *const Io.Operation.DeviceIoControl) Io.Cancelable!Io.Operation.DeviceIoControl.Result {
    if (is_windows) {
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
            const rc = posix.system.ioctl(o.file.handle, @bitCast(o.code), @intFromPtr(o.arg));
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

pub fn posixAddressFamily(a: *const net.IpAddress) posix.sa_family_t {
    return switch (a.*) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
}

pub fn addressFromPosix(posix_address: *const PosixAddress) net.IpAddress {
    return switch (posix_address.any.family) {
        posix.AF.INET => .{ .ip4 = address4FromPosix(&posix_address.in) },
        posix.AF.INET6 => .{ .ip6 = address6FromPosix(&posix_address.in6) },
        else => .{ .ip4 = .loopback(0) },
    };
}

pub fn addressToPosix(a: *const net.IpAddress, storage: *PosixAddress) posix.socklen_t {
    return switch (a.*) {
        .ip4 => |ip4| {
            storage.in = address4ToPosix(ip4);
            return @sizeOf(posix.sockaddr.in);
        },
        .ip6 => |*ip6| {
            storage.in6 = address6ToPosix(ip6);
            return @sizeOf(posix.sockaddr.in6);
        },
    };
}

pub fn posixSocketModeProtocol(family: posix.sa_family_t, mode: net.Socket.Mode, protocol: ?net.Protocol) !struct { u32, u32 } {
    return .{
        switch (mode) {
            .stream => posix.SOCK.STREAM,
            .dgram => posix.SOCK.DGRAM,
            .seqpacket => posix.SOCK.SEQPACKET,
            .raw => posix.SOCK.RAW,
            .rdm => if (@hasDecl(posix.SOCK, "RDM")) posix.SOCK.RDM else return error.OptionUnsupported,
        },
        if (protocol) |p| @intFromEnum(p) else if (is_windows) switch (family) {
            posix.AF.UNIX => switch (mode) {
                .stream => 0,
                else => return error.ProtocolUnsupportedByAddressFamily,
            },
            posix.AF.INET, posix.AF.INET6 => @intFromEnum(@as(net.Protocol, switch (mode) {
                .stream => .tcp,
                .dgram => .udp,
                else => return error.ProtocolUnsupportedByAddressFamily,
            })),
            else => return error.ProtocolUnsupportedByAddressFamily,
        } else 0,
    };
}

fn addressUnixToPosix(a: *const UnixAddress, storage: *UnixAddress) ws2_32.socklen_t {
    storage.un.family = ws2_32.AF.UNIX;
    var path_len = switch (native_os) {
        .windows => @min(a.path.len, storage.un.path.len),
        else => a.path.len,
    };
    // With the AFD API, `sockaddr.un` is purely informational, so
    // use a suffix which is usually the most relevant part of a path.
    @memcpy(storage.un.path[0..path_len], a.path[a.path.len - path_len ..]);
    if (storage.un.path.len - path_len > 0) {
        @branchHint(.likely);
        storage.un.path[path_len] = 0;
        path_len += 1;
    }
    switch (native_os) {
        .windows => {
            if (storage.un.path[0] == 0) @memset(storage.un.path[path_len..], 0);
            return @sizeOf(posix.sockaddr.un);
        },
        else => return @intCast(@offsetOf(posix.sockaddr.un, "path") + path_len),
    }
}

fn address4FromPosix(in: *const ws2_32.sockaddr.in) net.Ip4Address {
    return .{
        .port = std.mem.bigToNative(u16, in.port),
        .bytes = @bitCast(in.addr),
    };
}

fn address6FromPosix(in6: *const ws2_32.sockaddr.in6) net.Ip6Address {
    return .{
        .port = std.mem.bigToNative(u16, in6.port),
        .bytes = in6.addr,
        .flow = in6.flowinfo,
        .interface = .{ .index = in6.scope_id },
    };
}

fn address4ToPosix(a: net.Ip4Address) ws2_32.sockaddr.in {
    return .{
        .port = std.mem.nativeToBig(u16, a.port),
        .addr = @bitCast(a.bytes),
    };
}

fn address6ToPosix(a: *const net.Ip6Address) ws2_32.sockaddr.in6 {
    return .{
        .port = std.mem.nativeToBig(u16, a.port),
        .flowinfo = a.flow,
        .addr = a.bytes,
        .scope_id = a.interface.index,
    };
}
// ── send via NtWriteFile ──────────────────────────────────────────────────────

fn sendData(handle: HANDLE, buf: []const u8) !usize {
    var iosb = std.mem.zeroes(windows.IO_STATUS_BLOCK);
    const status = NtWriteFile(
        handle,
        null,
        null,
        null,
        &iosb,
        buf.ptr,
        @intCast(buf.len),
        null,
        null,
    );
    if (status != .SUCCESS) {
        std.debug.print("NtWriteFile failed: 0x{t}\n", .{status});
        return error.SendFailed;
    }
    return iosb.Information;
}

// ── recv via NtReadFile ───────────────────────────────────────────────────────

fn recvData(handle: HANDLE, buf: []u8) !usize {
    var iosb = std.mem.zeroes(windows.IO_STATUS_BLOCK);
    const status = NtReadFile(
        handle,
        null,
        null,
        null,
        &iosb,
        buf.ptr,
        @intCast(buf.len),
        null,
        null,
    );
    if (status == .END_OF_FILE) return 0;
    if (status != .SUCCESS) {
        std.debug.print("NtReadFile failed: 0x{t}\n", .{status});
        return error.RecvFailed;
    }
    return iosb.Information;
}

/// AFD poll event flags
pub const AfdPollFlags = packed struct(u32) {
    /// Data can be read without blocking
    READ: bool = false,
    /// Out-of-band data available
    OOB: bool = false,
    /// Data can be written without blocking
    WRITE: bool = false,
    /// Hang up (connection broken)
    HUP: bool = false,
    /// Connection reset
    RESET: bool = false,
    /// Socket closed
    CLOSE: bool = false,
    /// Connection established
    CONNECT: bool = false,
    /// New connection ready to accept
    ACCEPT: bool = false,
    /// Connection error occurred
    CONNECT_ERR: bool = false,
    _9: u23 = 0,
};

const AfdPollSocket = extern struct {
    socket: windows.HANDLE, // SOCKET = UINT_PTR
    flags: AfdPollFlags,
    status: i32,
};

const AfdPollParams = extern struct {
    timeout: i64 align(4),
    count: u32,
    exclusive: windows.BOOLEAN,
    padding: [3]windows.BOOLEAN = @splat(.FALSE),
    sockets: [1]AfdPollSocket, // we only poll one socket at a time here
};

fn msToNtRelative(ms: i64) i64 {
    return if (ms > 0) -ms * 10_000 else std.math.maxInt(i64);
}

const WSAPOLLFD = extern struct {
    fd: windows.HANDLE,
    events: Revents,
    revents: Events,

    pub const Revents = Events;
    pub const Events = packed struct(u16) {
        ERR: bool = false,
        HUP: bool = false,
        NVAL: bool = false,
        WRNORM: bool = false,
        WRBAND: bool = false,
        _5: u2 = 0,
        RDNORM: bool = false,
        RDBAND: bool = false,
        PRI: bool = false,
        _10: u6 = 0,

        pub const IN: Events = .{ .RDNORM = true, .RDBAND = true };
        pub const OUT: Events = .{ .WRNORM = true };

        pub const empty: Events = @bitCast(@as(u16, 0));
    };
};

fn WSAPoll(fds: []WSAPOLLFD, timeout_ms: i64) !usize {
    debug.assert(fds.len > 0);

    // return error.SystemResources
    var params: AfdPollParams = .{
        .timeout = msToNtRelative(timeout_ms),
        .count = 1,
        .exclusive = .FALSE,
        .sockets = @splat(undefined),
    };

    // create a manual-reset event to wait on
    var event: HANDLE = undefined;
    const es = NtCreateEvent(
        &event,
        @bitCast(@as(windows.DWORD, 0x1F0003)),
        null,
        .Notification,
        .FALSE,
    );
    defer _ = NtClose(event);
    if (es != .SUCCESS) return error.CreateEventFailed;
    log.debug("created event with status {t}", .{es});

    var poll_handle: windows.HANDLE = undefined;
    for (fds, &params.sockets) |*pollfd, *socket| {
        // We don't support negative fds
        debug.assert(@intFromPtr(pollfd.fd) > 0);

        const flags = blk: {
            var flags: AfdPollFlags = .{
                .HUP = true,
                .RESET = true,
                .CONNECT_ERR = true,
            };

            if (pollfd.events.RDNORM) {
                flags.ACCEPT = true;
                flags.READ = true;
            }
            if (pollfd.events.RDBAND) flags.OOB = true;
            if (pollfd.events.WRNORM) flags.WRITE = true;

            break :blk flags;
        };

        socket.flags = flags;
        poll_handle = pollfd.fd;
        pollfd.revents = .empty;
    }

    var iosb = std.mem.zeroes(windows.IO_STATUS_BLOCK);

    const status = NtDeviceIoControlFile(
        poll_handle,
        event,
        null,
        null,
        &iosb,
        @bitCast(@as(windows.ULONG, IOCTL_AFD_POLL)),
        &params,
        @sizeOf(AfdPollParams),
        &params,
        @sizeOf(AfdPollParams),
    );
    log.debug("status of poll syscall is {t}", .{status});

    var poll_count: usize = 0;

    return swi: switch (status) {
        .SUCCESS => poll_count, // fired events,
        .PENDING => {
            waitIosb(event, &iosb, status) catch |err| switch (err) {
                error.OperationFailed => return error.ConnectFailed,
                else => unreachable,
            };
            log.debug("status after pending wait is {t}", .{iosb.u.Status});
            continue :swi iosb.u.Status;
        },
        .TIMEOUT => error.TimeOut,
        else => |s| {
            for (fds, &params.sockets) |*pollfd, *socket| {
                var revents: WSAPOLLFD.Revents = .empty;

                if (socket.flags.ACCEPT or socket.flags.READ) revents.RDNORM = true;
                if (socket.flags.OOB) revents.RDBAND = true;
                if (socket.flags.WRITE) revents.WRNORM = true;
                if (socket.flags.RESET or socket.flags.HUP) revents.HUP = true;
                if (socket.flags.RESET or socket.flags.CONNECT_ERR) revents.ERR = true;
                if (socket.flags.CLOSE) revents.NVAL = true;

                pollfd.revents = @bitCast(
                    @as(u16, @bitCast(revents)) &
                        (@as(u16, @bitCast(pollfd.events)) |
                            @as(u16, @bitCast(
                                WSAPOLLFD.Events{
                                    .HUP = true,
                                    .ERR = true,
                                    .NVAL = true,
                                },
                            ))),
                );
                if (pollfd.revents != WSAPOLLFD.Revents.empty) poll_count += 1;
            }

            log.debug("IOCTL_AFD_POLL status: {t}\n", .{s});

            return poll_count;
        },
    };
}

// ── main ──────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    var stdout_w = std.Io.File.stdout().writer(init.io, &.{});
    defer stdout_w.flush() catch unreachable;
    const stdout = &stdout_w.interface;

    // 1. Create TCP socket via IOCTL_AFD_WINE_CREATE
    const AF_INET = @as(i32, 2);
    const SOCK_STREAM = @as(i32, 1);
    const IPPROTO_TCP = @as(i32, 6);

    const sock = try createSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    defer _ = NtClose(sock);
    try stdout.print("Socket created.\n", .{});

    // 2. Connect to example.com:80
    //    Run: dig +short example.com   and substitute the result here.
    const ip_str = "104.20.23.154";
    const addr = sockaddr_in{
        .sin_family = AF_INET,
        .sin_port = htons(80),
        .sin_addr = try inetAddr(ip_str),
    };

    try stdout.print("Connecting to example.com:80 ({s})...\n", .{ip_str});
    const ip: net.Ip4Address = try .parse("104.20.23.154", 80);
    _ = try netConnectIpWindows(&.{ .ip4 = ip }, .{ .mode = ws2_32.SOCK.STREAM, .protocol = .tcp });
    try connectSocket(sock, addr);
    try stdout.print("Connected.\n", .{});

    // 3. Send HTTP GET
    const request = "GET / HTTP/1.0\r\nHost: example.com\r\n\r\n";
    const sent = try sendData(sock, request);
    try stdout.print("Sent {} bytes.\n\n", .{sent});

    // 4. AFD poll — wait up to 5 seconds for data
    try stdout.print("Waiting for response via IOCTL_AFD_POLL...\n\n", .{});

    var fds: [1]WSAPOLLFD = .{
        .{
            .fd = sock,
            .events = .{
                .RDNORM = true,
                .HUP = true,
            },
            .revents = .empty,
        },
    };
    const fired = WSAPoll(
        &fds,
        5_000,
    ) catch |err| switch (err) {
        error.TimeOut => {
            log.debug("Timed out.", .{});
            std.process.exit(1);
        },
        else => unreachable,
    };

    try stdout.print("AFD poll fired {} events\n", .{fired});
    if (fds[0].revents.RDNORM) try stdout.print("  read (data ready)\n", .{});
    if (fds[0].revents.HUP) try stdout.print("  hup (remote FIN)\n", .{});
    if (fds[0].revents.ERR) try stdout.print("  reset or connection err\n", .{});
    try stdout.print("\n", .{});

    // 5. Read response
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = try recvData(sock, &buf);
        if (n == 0) break;
        try stdout.print("{s}", .{buf[0..n]});
        total += n;
    }
    try stdout.print("\n\n--- {} bytes total ---\n", .{total});
}
