const std = @import("std");
const debug = std.debug;
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;

const AcceptResult = @import("../aio/completion.zig").AcceptResult;
const AcceptError = @import("../aio/completion.zig").AcceptError;
const ConnectResult = @import("../aio/completion.zig").ConnectResult;
const ConnectError = @import("../aio/completion.zig").ConnectError;
const RecvResult = @import("../aio/completion.zig").RecvResult;
const RecvError = @import("../aio/completion.zig").RecvError;
const SendResult = @import("../aio/completion.zig").SendResult;
const SendError = @import("../aio/completion.zig").SendError;
const Frame = @import("../frame/lib.zig").Frame;
const Runtime = @import("../runtime/lib.zig").Runtime;
const posix = std.posix;
const syscall = @import("../syscall.zig");
const mem = std.mem;

pub const Socket = struct {
    // TODO: create a udp/tcp connection without this
    pub const Kind = enum {
        tcp,
        udp,
        unix,

        pub fn listenable(self: Kind) bool {
            return switch (self) {
                .tcp, .unix => true,
                else => false,
            };
        }
    };

    const HostPort = struct {
        host: []const u8,
        port: u16,
    };

    pub const InitKind = union(Kind) {
        tcp: HostPort,
        udp: HostPort,
        unix: []const u8,
    };

    pub const Handle = net.Socket.Handle;

    pub const Address = union(enum) {
        ip: net.IpAddress,
        unix: net.UnixAddress,

        pub const empty: Address = .{
            .ip = .{
                .ip4 = .{
                    .port = 0,
                    .bytes = @splat(0x0),
                },
            },
        };

        pub fn format(a: Address, w: *Io.Writer) Io.Writer.Error!void {
            switch (a) {
                .ip => |ip| try ip.format(w),
                .unix => |unix| {
                    try w.print("{s}", .{unix.path});
                },
            }
        }

        pub fn toPosix(addr: Address) struct { posix.sockaddr, posix.socklen_t } {
            switch (addr) {
                .ip => |ip| {
                    switch (ip) {
                        .ip4 => |ip4| {
                            const saddr: posix.sockaddr.in = .{
                                .addr = @bitCast(ip4.bytes),
                                .port = mem.nativeToBig(u16, ip4.port),
                            };
                            const addr_: posix.sockaddr = @as(*const posix.sockaddr, @ptrCast(&saddr)).*;
                            return .{ addr_, @sizeOf(@TypeOf(saddr)) };
                        },
                        .ip6 => |ip6| {
                            const saddr: posix.sockaddr.in6 = .{
                                .addr = ip6.bytes,
                                .flowinfo = ip6.flow,
                                .scope_id = ip6.interface.index,
                                .port = mem.nativeToBig(u16, ip6.port),
                            };
                            const addr_: posix.sockaddr = @as(*const posix.sockaddr, @ptrCast(&saddr)).*;
                            return .{ addr_, @sizeOf(@TypeOf(saddr)) };
                        },
                    }
                },
                .unix => |unix| {
                    var saddr: posix.sockaddr.un = .{
                        .path = @splat(0x0),
                    };
                    @memcpy(saddr.path[0..unix.path.len], unix.path[0..]);
                    const addr_: posix.sockaddr = @as(*const posix.sockaddr, @ptrCast(&saddr)).*;
                    return .{ addr_, @sizeOf(@TypeOf(saddr)) };
                },
            }
        }
    };

    handle: posix.socket_t,
    addr: Address,
    kind: Kind,

    // TODO: we shouldn't need Io here
    pub fn init(io_: Io, kind: InitKind) !Socket {
        const addr: Address = switch (kind) {
            .tcp, .udp => |inner| blk: {
                break :blk if (comptime builtin.os.tag == .linux)
                    .{ .ip = try .resolve(io_, inner.host, inner.port) }
                else
                    .{ .ip = try .parse(inner.host, inner.port) };
            },
            // Not supported on Windows at the moment.
            .unix => |path| if (builtin.os.tag == .windows) unreachable else .{ .unix = try .init(path) },
        };

        return try init_with_address(kind, addr);
    }

    pub fn init_with_address(kind: Kind, addr: Address) !Socket {
        const sock_type: u32 = switch (kind) {
            .tcp, .unix => posix.SOCK.STREAM,
            .udp => posix.SOCK.DGRAM,
        };

        const protocol: u32 = switch (kind) {
            .tcp => posix.IPPROTO.TCP,
            .udp => posix.IPPROTO.UDP,
            .unix => 0,
        };

        const family: u32 = switch (addr) {
            .ip => |ip| switch (ip) {
                .ip4 => posix.AF.INET,
                .ip6 => posix.AF.INET6,
            },
            .unix => posix.AF.UNIX,
        };

        const flags: u32 = sock_type | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;

        // TODO: audit these and posix uses across tardy
        const socket = try syscall.socket(family, flags, protocol);

        if (kind != .unix) {
            if (@hasDecl(posix.SO, "REUSEPORT_LB")) {
                try syscall.setsockopt(
                    socket,
                    posix.SOL.SOCKET,
                    posix.SO.REUSEPORT_LB,
                    &std.mem.toBytes(@as(u32, 1)),
                );
            } else if (@hasDecl(posix.SO, "REUSEPORT")) {
                try syscall.setsockopt(
                    socket,
                    posix.SOL.SOCKET,
                    posix.SO.REUSEPORT,
                    &std.mem.toBytes(@as(u32, 1)),
                );
            } else {
                try syscall.setsockopt(
                    socket,
                    posix.SOL.SOCKET,
                    posix.SO.REUSEADDR,
                    &std.mem.toBytes(@as(u32, 1)),
                );
            }
        }

        return .{ .handle = socket, .addr = addr, .kind = kind };
    }

    /// Bind the current Socket
    pub fn bind(sock: Socket) !void {
        const sockaddr, const socklen = sock.addr.toPosix();
        try syscall.bind(sock.handle, &sockaddr, socklen);
    }

    /// Listen on the Current Socket.
    pub fn listen(self: Socket, backlog: usize) !void {
        debug.assert(self.kind.listenable());
        try syscall.listen(self.handle, @truncate(backlog));
    }

    // TODO: rethink the aio to io approach
    pub fn close(self: Socket, rt: *Runtime) !void {
        if (rt.aio.features.has_capability(.close))
            try rt.scheduler.io_await(.{ .close = self.handle })
        else
            syscall.close(self.handle);
    }

    pub fn close_blocking(self: Socket) void {
        // todo: delete the unix socket if the
        // server is being closed
        syscall.close(self.handle);
    }

    pub fn accept(self: Socket, rt: *Runtime) !Socket {
        debug.assert(self.kind.listenable());
        if (rt.aio.features.has_capability(.accept)) {
            try rt.scheduler.io_await(.{
                .accept = .{
                    .socket = self.handle,
                    .kind = self.kind,
                },
            });

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get(index);
            return try task.result.accept.unwrap();
        } else {
            var addr: Socket.Address = .{ .ip = undefined };
            var sockaddr, var socklen = addr.toPosix();

            const socket: posix.socket_t = blk: while (true) {
                break :blk syscall.accept(
                    self.handle,
                    &sockaddr,
                    &socklen,
                    posix.SOCK.NONBLOCK,
                ) catch |e| return switch (e) {
                    error.WouldBlock => {
                        Frame.yield();
                        continue;
                    },
                    error.ConnectionAborted,
                    => AcceptError.ConnectionAborted,
                    error.SocketNotListening => AcceptError.NotListening,
                    error.ProcessFdQuotaExceeded => AcceptError.ProcessFdQuotaExceeded,
                    error.SystemFdQuotaExceeded => AcceptError.SystemFdQuotaExceeded,
                    else => AcceptError.Unexpected,
                };
            };

            return .{
                .handle = socket,
                .addr = addr,
                .kind = self.kind,
            };
        }
    }

    pub fn connect(self: Socket, rt: *Runtime) !void {
        if (rt.aio.features.has_capability(.connect)) {
            try rt.scheduler.io_await(.{
                .connect = .{
                    .socket = self.handle,
                    .addr = self.addr,
                    .kind = self.kind,
                },
            });

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get(index);
            try task.result.connect.unwrap();
        } else {
            const sockaddr, const socklen = self.addr.toPosix();
            while (true) {
                break syscall.connect(
                    self.handle,
                    &sockaddr,
                    socklen,
                ) catch |e| return switch (e) {
                    error.WouldBlock => {
                        Frame.yield();
                        continue;
                    },
                    else => ConnectError.Unexpected,
                };
            }
        }
    }

    pub fn recv(self: Socket, rt: *Runtime, buffer: []u8) !usize {
        if (rt.aio.features.has_capability(.recv)) {
            try rt.scheduler.io_await(.{
                .recv = .{
                    .socket = self.handle,
                    .buffer = buffer,
                },
            });

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get(index);
            return try task.result.recv.unwrap();
        } else {
            const count: usize = blk: while (true) {
                break :blk syscall.recv(self.handle, buffer, 0) catch |e| return switch (e) {
                    error.WouldBlock => {
                        Frame.yield();
                        continue;
                    },
                    else => RecvError.Unexpected,
                };
            };

            if (count == 0) return RecvError.Closed;
            return count;
        }
    }

    pub fn recv_all(self: Socket, rt: *Runtime, buffer: []u8) !usize {
        var length: usize = 0;

        while (length < buffer.len) {
            const result = self.recv(rt, buffer[length..]) catch |e| switch (e) {
                error.Closed => return length,
                else => |err| return err,
            };

            length += result;
        }

        return length;
    }

    pub fn send(self: Socket, rt: *Runtime, buffer: []const u8) !usize {
        if (rt.aio.features.has_capability(.send)) {
            try rt.scheduler.io_await(.{
                .send = .{
                    .socket = self.handle,
                    .buffer = buffer,
                },
            });

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get(index);
            return try task.result.send.unwrap();
        } else {
            const count: usize = blk: while (true) {
                break :blk syscall.send(self.handle, buffer, 0) catch |e| return switch (e) {
                    error.WouldBlock => {
                        Frame.yield();
                        continue;
                    },
                    error.ConnectionResetByPeer,
                    error.BrokenPipe,
                    => SendError.Closed,
                    else => SendError.Unexpected,
                };
            };

            return count;
        }
    }

    pub fn send_all(self: Socket, rt: *Runtime, buffer: []const u8) !usize {
        var length: usize = 0;

        while (length < buffer.len) {
            const result = self.send(rt, buffer[length..]) catch |e| switch (e) {
                error.Closed => return length,
                else => |err| return err,
            };
            length += result;
        }

        return length;
    }

    pub const Writer = struct {
        socket: Socket,
        err: ?anyerror = null,
        pos: u64 = 0,
        rt: *Runtime,
        interface: Io.Writer,

        pub fn init(socket: Socket, rt: *Runtime, buffer: []u8) Writer {
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

        pub fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
            const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
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
            _ = io_w; // autofix
            _ = file_reader; // autofix
            _ = limit; // autofix
            return error.Unimplemented;
        }
    };

    pub const Reader = struct {
        socket: Socket,
        err: ?anyerror = null,
        pos: u64 = 0,
        rt: *Runtime,
        interface: Io.Reader,

        pub fn init(socket: Socket, rt: *Runtime, buffer: []u8) Reader {
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

        fn stream(io_reader: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
            const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
            const w_dest = limit.slice(try w.writableSliceGreedy(1));

            const n = r.socket.recv(r.rt, w_dest) catch |err| switch (err) {
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

    pub fn writer(sock: Socket, rt: *Runtime, buffer: []u8) Writer {
        return .init(sock, rt, buffer);
    }

    pub fn reader(sock: Socket, rt: *Runtime, buffer: []u8) Reader {
        return .init(sock, rt, buffer);
    }

    // TODO: sendFile like api is a more appropriate for this
    pub fn stream_to(from: Socket, to_w: *Io.Writer, rt: *Runtime) !void {
        debug.assert(to_w.buffer.len > 0);

        var file = from.reader(rt, &.{});
        const file_r = &file.interface;
        while (true) {
            _ = Reader.stream(file_r, to_w, .limited(to_w.buffer.len)) catch |e| switch (e) {
                error.EndOfStream => break,
                else => |err| return err,
            };
            _ = to_w.vtable.drain(to_w, &.{}, 0) catch break;
        }
    }
};
