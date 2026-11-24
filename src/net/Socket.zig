pub const Socket = @This();

handle: Socket.Handle,
addr: Address,
kind: Kind,

pub fn init(options: Options) !Socket {
    const addr: Address.Config = switch (options) {
        .tcp, .udp => |config| .{
            .ip = blk: {
                // we only support non-root ports
                debug.assert(config.port > 1023);
                break :blk try .parse(config.host, config.port);
            },
        },
        // Not supported on Windows at the moment.
        .unix => |path| if (builtin.os.tag == .windows)
            unreachable
        else
            .{ .unix = try .init(path) },
    };

    return try initWithAddress(options, addr);
}

pub fn initWithAddress(options: Options, addr: Address.Config) !Socket {
    const sock_type: u32, const protocol: u32 = switch (options) {
        .tcp => .{ SOCK.STREAM, IPPROTO.TCP },
        .udp => .{ SOCK.DGRAM, IPPROTO.UDP },
        .unix => .{ SOCK.STREAM, IPPROTO.IP },
    };

    const family: u32 = switch (addr) {
        .ip => |ip| switch (ip) {
            .ip4 => AF.INET,
            .ip6 => AF.INET6,
        },
        .unix => AF.UNIX,
    };

    const flags: u32 = if (builtin.os.tag != .windows)
        sock_type | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK
    else
        sock_type;

    const socket = try syscall.socket(
        family,
        flags,
        protocol,
    );

    switch (options) {
        .tcp, .udp => |config| {
            if (config.disable_nagle) try disable_nagle(socket);

            // https://stackoverflow.com/a/14388707
            try syscall.setsockopt(
                socket,
                SOL.SOCKET,
                SO.REUSEADDR,
                &mem.toBytes(@as(u32, 1)),
            );

            if (@hasDecl(SO, "REUSEPORT_LB")) {
                try syscall.setsockopt(
                    socket,
                    SOL.SOCKET,
                    SO.REUSEPORT_LB,
                    &mem.toBytes(@as(u32, 1)),
                );
            } else if (@hasDecl(SO, "REUSEPORT")) {
                try syscall.setsockopt(
                    socket,
                    SOL.SOCKET,
                    SO.REUSEPORT,
                    &mem.toBytes(@as(u32, 1)),
                );
            }
        },
        .unix => {},
    }

    return .{
        .handle = socket,
        .addr = blk: {
            const sock_addr, const sock_len = addr.toPosix();
            break :blk .{
                .any = sock_addr,
                .len = sock_len,
            };
        },

        .kind = options.kind(),
    };
}

fn disable_nagle(socket: Socket.Handle) !void {
    if (comptime builtin.os.tag != .windows) {
        try syscall.setsockopt(
            socket,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            &std.mem.toBytes(@as(c_int, 1)),
        );
    } else {
        // TODO: implement TCP.NODELAY on windows
    }
}

/// Sets the `std.posix.socket_t` to nonblocking.
pub fn enable_nonblocking(socket: Socket.Handle) !void {
    if (comptime builtin.os.tag == .windows) {
        var mode: u32 = 1;
        _ = syscall.ws2.ioctlsocket(
            socket,
            syscall.ws2.FIONBIO,
            &mode,
        );
    } else {
        const current_flags = try syscall.fcntl(
            socket,
            std.posix.F.GETFL,
            0,
        );
        var new_flags = @as(
            std.posix.O,
            @bitCast(@as(u32, @intCast(current_flags))),
        );
        new_flags.NONBLOCK = true;
        const arg: u32 = @bitCast(new_flags);
        _ = try syscall.fcntl(socket, std.posix.F.SETFL, arg);
    }
}

/// Bind the current Socket
pub fn bind(sock: *const Socket) !void {
    try syscall.bind(sock.handle, &sock.addr);
}

/// Listen on the Current Socket.
pub fn listen(sock: *const Socket, backlog: usize) !void {
    debug.assert(sock.kind.listenable());
    try syscall.listen(sock.handle, @truncate(backlog));
}

pub fn close(sock: *const Socket, rt: *Runtime) !void {
    if (rt.aio.features.has_capability(.close))
        try rt.scheduler.ioAwait(rt.gpa, .{
            .close = sock.handle,
        })
    else
        syscall.close(sock.handle);
}

pub fn close_blocking(sock: *const Socket) void {
    syscall.close(sock.handle);
}

pub fn accept(sock: *const Socket, rt: *Runtime) Errors.Accept!Socket {
    debug.assert(sock.kind.listenable());
    if (rt.aio.features.has_capability(.accept)) {
        try rt.scheduler.ioAwait(rt.gpa, .{
            .accept = .{
                .socket = sock,
            },
        });

        const task_index = rt.current_task.?;
        const task = rt.scheduler.tasks.get(task_index);
        return try task.result.accept.unwrap();
    } else {
        var addr: Socket.Address = switch (sock.addr.family()) {
            .ip4 => .wildcard,
            .ip6 => .wildcard64,
            .unix => .unix,
        };

        const new_handle: syscall.socket_t = blk: while (true) {
            break :blk syscall.accept(
                sock.handle,
                &addr,
                if (builtin.os.tag != .windows) posix.SOCK.NONBLOCK else 0,
            ) catch |err| return switch (err) {
                error.WouldBlock => {
                    Coroutine.yield();
                    continue;
                },
                error.ConnectionAborted,
                => error.ConnectionAborted,
                error.SocketNotListening => error.NotListening,
                error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
                else => error.Unexpected,
            };
        };

        log.debug(
            "new accept client_fd is {} with address ({f})",
            .{ new_handle, addr },
        );

        return .{
            .handle = new_handle,
            .addr = addr,
            .kind = sock.kind,
        };
    }
}

pub fn connect(sock: *const Socket, rt: *Runtime) Errors.Connect!void {
    if (rt.aio.features.has_capability(.connect)) {
        try rt.scheduler.ioAwait(rt.gpa, .{
            .connect = .{
                .socket = sock,
            },
        });

        const task_index = rt.current_task.?;
        const task = rt.scheduler.tasks.get(task_index);
        try task.result.connect.unwrap();
    } else {
        while (true) {
            break syscall.connect(
                sock.handle,
                &sock.addr,
            ) catch |err| return switch (err) {
                error.WouldBlock => {
                    Coroutine.yield();
                    continue;
                },
                else => error.Unexpected,
            };
        }
    }
}

pub fn recv(
    sock: *const Socket,
    rt: *Runtime,
    buffer: []u8,
    flags: u32,
) Errors.Recv!usize {
    if (buffer.len == 0) return 0;
    if (rt.aio.features.has_capability(.recv)) {
        try rt.scheduler.ioAwait(rt.gpa, .{
            .recv = .{
                .socket = sock.handle,
                .buffer = buffer,
                .flags = flags,
            },
        });

        const task_index = rt.current_task.?;
        const task = rt.scheduler.tasks.get(task_index);
        return try task.result.recv.unwrap();
    } else {
        const count: usize = blk: while (true) {
            break :blk syscall.recv(
                sock.handle,
                buffer,
                flags,
            ) catch |err| return switch (err) {
                error.WouldBlock => {
                    Coroutine.yield();
                    continue;
                },
                error.ConnectionResetByPeer, error.BrokenPipe => error.Closed,
                else => error.Unexpected,
            };
        };

        return count;
    }
}

pub fn recv_all(sock: *const Socket, rt: *Runtime, buffer: []u8) Errors.Recv!usize {
    var length: usize = 0;

    while (length < buffer.len) {
        const count = sock.recv(
            rt,
            buffer[length..],
        ) catch |err| switch (err) {
            error.Closed => return length,
            else => |e| return e,
        };
        defer length += count;
    }

    return length;
}

pub fn send(sock: *const Socket, rt: *Runtime, buffer: []const u8) Errors.Send!usize {
    if (buffer.len == 0) return 0;
    if (rt.aio.features.has_capability(.send)) {
        try rt.scheduler.ioAwait(rt.gpa, .{
            .send = .{
                .socket = sock.handle,
                .buffer = buffer,
            },
        });

        const task_index = rt.current_task.?;
        const task = rt.scheduler.tasks.get(task_index);
        return try task.result.send.unwrap();
    } else {
        const count: usize = blk: while (true) {
            break :blk syscall.send(
                sock.handle,
                buffer,
                0,
            ) catch |err| return switch (err) {
                error.WouldBlock => {
                    Coroutine.yield();
                    continue;
                },
                error.ConnectionResetByPeer, error.BrokenPipe => error.Closed,
                else => error.Unexpected,
            };
        };

        return count;
    }
}

pub fn send_all(
    sock: *const Socket,
    rt: *Runtime,
    buffer: []const u8,
) Errors.Send!usize {
    var length: usize = 0;

    while (length < buffer.len) {
        const count = sock.send(
            rt,
            buffer[length..],
        ) catch |err| switch (err) {
            error.Closed => return length,
            else => |e| return e,
        };
        defer length += count;
    }

    return length;
}

pub const Mode = enum(u8) {
    client,
    server,
};

pub const Config = struct {
    host: []const u8,
    port: u16,
    mode: Mode = .server,
    /// defines the maximum length to which the queue of
    /// pending connections for the socket may grow
    backlog: u32 = 4096,
    /// Set `TCP_NODELAY` which allows segments of data to be sent as soon
    /// as possible even if there is only a small amount of data
    /// https://brooker.co.za/blog/2024/05/09/nagle.html
    disable_nagle: bool = true,
};

pub const Options = union(Kind) {
    tcp: Config,
    udp: Config,
    unix: []const u8,

    pub fn kind(options: Options) Kind {
        return @fromBackingInt(@backingInt(options));
    }
};

pub const Kind = enum(u8) {
    tcp,
    udp,
    unix,

    pub fn listenable(kind: Kind) bool {
        return switch (kind) {
            .tcp, .unix => true,
            else => false,
        };
    }
};

pub const Native = extern union {
    any: sockaddr,
    in: sockaddr.in,
    in6: sockaddr.in6,
    un: sockaddr.un,
};

pub const Address = extern struct {
    any: sockaddr,
    len: socklen_t,

    pub const localhost: Address = blk: {
        const loopback: [4]u8 = .{ 127, 0, 0, 1 };
        const in: sockaddr.in = .{
            .addr = @bitCast(loopback),
            .port = 0,
        };
        const addr: sockaddr = @as(*const sockaddr, @ptrCast(@alignCast(&in))).*;

        var ip4: Address = mem.zeroes(Address);
        ip4.len = @sizeOf(sockaddr.in);
        ip4.any = addr;
        break :blk ip4;
    };

    pub const wildcard: Address = blk: {
        var ip4: Address = mem.zeroes(Address);
        ip4.any.family = AF.INET;
        ip4.len = @sizeOf(sockaddr.in);
        break :blk ip4;
    };

    pub const unix: Address = blk: {
        var un: Address = mem.zeroes(Address);
        un.any.family = AF.UNIX;
        un.len = @sizeOf(sockaddr.un);
        break :blk un;
    };

    pub const wildcard64: Address = blk: {
        var ip6: Address = mem.zeroes(Address);
        ip6.any.family = AF.INET6;
        ip6.len = @sizeOf(sockaddr.in6);
        break :blk ip6;
    };

    pub fn init(af: Family) Address {
        return switch (af) {
            .ip4 => .wildcard,
            .ip6 => .wildcard64,
            .unix => .unix,
        };
    }

    pub fn family(addr: Address) Family {
        return switch (addr.any.family) {
            AF.INET => .ip4,
            AF.INET6 => .ip6,
            AF.UNIX => .unix,
            else => unreachable,
        };
    }

    pub fn format(addr: *const Address, w: *Io.Writer) Io.Writer.Error!void {
        const address: Address.Config = .fromAny(&addr.any);
        try address.format(w);
    }

    pub const Family = enum(u8) {
        ip4 = AF.INET,
        ip6 = AF.INET6,
        unix = AF.UNIX,
    };

    const Config = union(enum) {
        ip: net.IpAddress,
        unix: net.UnixAddress,

        pub fn format(a: *const Address.Config, w: *Io.Writer) Io.Writer.Error!void {
            switch (a.*) {
                .ip => |*ip| try ip.format(w),
                .unix => |*un| {
                    try w.print("{s}", .{if (un.path.len == 0)
                        "N/A: unix socket"
                    else
                        un.path});
                },
            }
        }

        pub fn fromAny(addr: *const sockaddr) Address.Config {
            switch (addr.family) {
                AF.INET => {
                    const sock: *const sockaddr.in = @ptrCast(@alignCast(addr));
                    return .{
                        .ip = .{
                            .ip4 = .{
                                .port = mem.bigToNative(u16, sock.port),
                                .bytes = @bitCast(sock.addr),
                            },
                        },
                    };
                },
                AF.INET6 => {
                    const sock6: *const sockaddr.in6 = @ptrCast(@alignCast(addr));
                    return .{
                        .ip = .{
                            .ip6 = .{
                                .port = mem.bigToNative(u16, sock6.port),
                                .flow = sock6.flowinfo,
                                .interface = .{
                                    .index = sock6.scope_id,
                                },
                                .bytes = sock6.addr,
                            },
                        },
                    };
                },
                AF.UNIX => {
                    const sockun: *const sockaddr.un = @ptrCast(@alignCast(addr));
                    return .{
                        .unix = .{
                            .path = mem.sliceTo(&sockun.path, 0x0),
                        },
                    };
                },
                else => unreachable,
            }
        }

        pub fn toPosix(addr: *const Address.Config) struct {
            sockaddr,
            socklen_t,
        } {
            switch (addr.*) {
                .ip => |ip| {
                    switch (ip) {
                        .ip4 => |ip4| {
                            const saddr: sockaddr.in = .{
                                .addr = @bitCast(ip4.bytes),
                                .port = mem.nativeToBig(u16, ip4.port),
                            };
                            const raw: *const sockaddr =
                                @ptrCast(@alignCast(&saddr));
                            return .{ raw.*, @sizeOf(sockaddr.in) };
                        },
                        .ip6 => |ip6| {
                            const saddr: sockaddr.in6 = .{
                                .addr = ip6.bytes,
                                .flowinfo = ip6.flow,
                                .scope_id = ip6.interface.index,
                                .port = mem.nativeToBig(u16, ip6.port),
                            };
                            const raw: *const sockaddr =
                                @ptrCast(@alignCast(&saddr));
                            return .{ raw.*, @sizeOf(sockaddr.in6) };
                        },
                    }
                },
                .unix => |un| {
                    var saddr: sockaddr.un = .{
                        .path = @splat(0x0),
                    };
                    @memcpy(saddr.path[0..un.path.len], un.path[0..]);
                    const raw: *const sockaddr =
                        @ptrCast(@alignCast(&saddr));
                    return .{ raw.*, @sizeOf(sockaddr.un) };
                },
            }
        }
    };
};

pub const Writer = struct {
    socket: *const Socket,
    err: ?anyerror = null,
    pos: u64 = 0,
    rt: *Runtime,
    interface: Io.Writer,

    pub fn init(socket: *const Socket, rt: *Runtime, buffer: []u8) Writer {
        return .{
            .socket = socket,
            .rt = rt,
            .interface = initInterface(buffer),
        };
    }

    pub fn initInterface(buffer: []u8) Io.Writer {
        return .{
            .vtable = &.{
                .drain = drain,
                .sendFile = sendFile,
            },
            .buffer = buffer,
        };
    }

    pub fn drain(
        io_w: *Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) Io.Writer.Error!usize {
        const w: *Writer = @alignCast(
            @fieldParentPtr("interface", io_w),
        );
        const buffered = io_w.buffered();

        if (buffered.len != 0) {
            const n = w.socket.send(w.rt, buffered) catch |err| {
                w.err = err;
                return error.WriteFailed;
            };
            w.pos += n;
            return io_w.consume(n);
        }

        for (data[0 .. data.len - 1]) |buf| {
            if (buf.len == 0) continue;
            const n = w.socket.send(w.rt, buf) catch |err| {
                w.err = err;
                return error.WriteFailed;
            };
            w.pos += n;
            return io_w.consume(n);
        }

        const pattern = data[data.len - 1];
        if (pattern.len == 0 or splat == 0) return 0;
        const n = w.socket.send(w.rt, pattern) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
        w.pos += n;
        return io_w.consume(n);
    }

    pub fn sendFile(
        io_w: *Io.Writer,
        file_reader: *Io.File.Reader,
        limit: Io.Limit,
    ) Io.Writer.FileError!usize {
        _ = io_w;
        _ = file_reader;
        _ = limit;
        return error.Unimplemented;
    }
};

pub const Reader = struct {
    socket: *const Socket,
    err: ?anyerror = null,
    pos: u64 = 0,
    rt: *Runtime,
    interface: Io.Reader,

    pub fn init(socket: *const Socket, rt: *Runtime, buffer: []u8) Reader {
        return .{
            .socket = socket,
            .rt = rt,
            .interface = initInterface(buffer),
        };
    }

    pub fn initInterface(buffer: []u8) Io.Reader {
        return .{
            .vtable = &.{
                .stream = Reader.stream,
            },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        };
    }

    fn stream(
        io_reader: *Io.Reader,
        w: *Io.Writer,
        limit: Io.Limit,
    ) Io.Reader.StreamError!usize {
        const r: *Reader = @alignCast(
            @fieldParentPtr("interface", io_reader),
        );
        const w_dest = limit.slice(try w.writableSliceGreedy(1));

        const n = r.socket.recv(
            r.rt,
            w_dest,
            0,
        ) catch |err| switch (err) {
            error.Closed => {
                return error.EndOfStream;
            },
            else => {
                r.err = err;
                return error.ReadFailed;
            },
        };

        r.pos += n;
        w.advance(n);
        return n;
    }
};

pub fn writer(sock: *const Socket, rt: *Runtime, buffer: []u8) Writer {
    return .init(sock, rt, buffer);
}

pub fn reader(sock: *const Socket, rt: *Runtime, buffer: []u8) Reader {
    return .init(sock, rt, buffer);
}

// TODO: sendFile like api is a more appropriate for this
pub fn stream_to(from: Socket, to_w: *Io.Writer, rt: *Runtime) !void {
    debug.assert(to_w.buffer.len > 0);

    var file = from.reader(rt, &.{});
    const file_r = &file.interface;
    while (true) {
        _ = Reader.stream(
            file_r,
            to_w,
            .limited(to_w.buffer.len),
        ) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        _ = to_w.vtable.drain(to_w, &.{}, 0) catch break;
    }
}

const Errors = struct {
    const Accept = AsyncIO.Errors.QueueJob || results.Errors.Accept;
    const Recv = AsyncIO.Errors.QueueJob || results.Errors.Recv;
    const Send = AsyncIO.Errors.QueueJob || results.Errors.Send;
    const Connect = AsyncIO.Errors.QueueJob || results.Errors.Connect;
};

const std = @import("std");
const debug = std.debug;
const Io = std.Io;
const net = Io.net;
const ws2_32 = std.os.windows.ws2_32;
const posix = std.posix;
const mem = std.mem;
pub const Handle = net.Socket.Handle;
const builtin = @import("builtin");

const tardy = @import("../root.zig");
const results = tardy.results;
const AsyncIO = tardy.AsyncIO;
const syscall = AsyncIO.syscall;
const sockaddr = syscall.sockaddr;
const socklen_t = syscall.socklen_t;
const AF = syscall.AF;
const SOCK = syscall.SOCK;
const IPPROTO = syscall.IPPROTO;
const SOL = syscall.SOL;
const SO = syscall.SO;
const Coroutine = tardy.Coroutine;
const Runtime = tardy.Runtime;
const log = std.log.scoped(.@"tardy/net/Socket");
