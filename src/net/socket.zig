const std = @import("std");
const debug = std.debug;
const builtin = @import("builtin");

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

pub const Socket = struct {
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

    handle: std.posix.socket_t,
    addr: std.net.Address,
    kind: Kind,

    pub fn init(kind: InitKind) !Socket {
        const addr = switch (kind) {
            .tcp, .udp => |inner| blk: {
                break :blk if (comptime builtin.os.tag == .linux)
                    try std.net.Address.resolveIp(inner.host, inner.port)
                else
                    try std.net.Address.parseIp(inner.host, inner.port);
            },
            // Not supported on Windows at the moment.
            .unix => |path| if (builtin.os.tag == .windows) unreachable else try std.net.Address.initUnix(path),
        };

        return try init_with_address(kind, addr);
    }

    pub fn init_with_address(kind: Kind, addr: std.net.Address) !Socket {
        const sock_type: u32 = switch (kind) {
            .tcp, .unix => std.posix.SOCK.STREAM,
            .udp => std.posix.SOCK.DGRAM,
        };

        const protocol: u32 = switch (kind) {
            .tcp => std.posix.IPPROTO.TCP,
            .udp => std.posix.IPPROTO.UDP,
            .unix => 0,
        };

        const flags: u32 = sock_type | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK;
        const socket = try std.posix.socket(addr.any.family, flags, protocol);

        if (kind != .unix) {
            if (@hasDecl(std.posix.SO, "REUSEPORT_LB")) {
                try std.posix.setsockopt(
                    socket,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.REUSEPORT_LB,
                    &std.mem.toBytes(@as(c_int, 1)),
                );
            } else if (@hasDecl(std.posix.SO, "REUSEPORT")) {
                try std.posix.setsockopt(
                    socket,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.REUSEPORT,
                    &std.mem.toBytes(@as(c_int, 1)),
                );
            } else {
                try std.posix.setsockopt(
                    socket,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.REUSEADDR,
                    &std.mem.toBytes(@as(c_int, 1)),
                );
            }
        }

        return .{ .handle = socket, .addr = addr, .kind = kind };
    }

    /// Bind the current Socket
    pub fn bind(self: Socket) !void {
        try std.posix.bind(self.handle, &self.addr.any, self.addr.getOsSockLen());
    }

    /// Listen on the Current Socket.
    pub fn listen(self: Socket, backlog: usize) !void {
        debug.assert(self.kind.listenable());
        try std.posix.listen(self.handle, @truncate(backlog));
    }

    pub fn close(self: Socket, rt: *Runtime) !void {
        if (rt.aio.features.has_capability(.close))
            try rt.scheduler.io_await(.{ .close = self.handle })
        else
            std.posix.close(self.handle);
    }

    pub fn close_blocking(self: Socket) void {
        // todo: delete the unix socket if the
        // server is being closed
        std.posix.close(self.handle);
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
            var sa: std.posix.sockaddr.storage = undefined;
            var salen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);

            const socket: std.posix.socket_t = blk: while (true) {
                break :blk std.posix.accept(
                    self.handle,
                    @ptrCast(&sa),
                    &salen,
                    std.posix.SOCK.NONBLOCK,
                ) catch |e| return switch (e) {
                    std.posix.AcceptError.WouldBlock => {
                        Frame.yield();
                        continue;
                    },
                    std.posix.AcceptError.ConnectionAborted,
                    std.posix.AcceptError.ConnectionResetByPeer,
                    => AcceptError.ConnectionAborted,
                    std.posix.AcceptError.SocketNotListening => AcceptError.NotListening,
                    std.posix.AcceptError.ProcessFdQuotaExceeded => AcceptError.ProcessFdQuotaExceeded,
                    std.posix.AcceptError.SystemFdQuotaExceeded => AcceptError.SystemFdQuotaExceeded,
                    std.posix.AcceptError.FileDescriptorNotASocket => AcceptError.NotASocket,
                    std.posix.AcceptError.OperationNotSupported => AcceptError.OperationNotSupported,
                    else => AcceptError.Unexpected,
                };
            };

            const addr: *std.posix.sockaddr = @ptrCast(&sa);
            return .{
                .handle = socket,
                .addr = .{ .any = addr.* },
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
            while (true) {
                break std.posix.connect(
                    self.handle,
                    &self.addr.any,
                    self.addr.getOsSockLen(),
                ) catch |e| return switch (e) {
                    std.posix.ConnectError.WouldBlock => {
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
                break :blk std.posix.recv(self.handle, buffer, 0) catch |e| return switch (e) {
                    std.posix.RecvFromError.WouldBlock => {
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
                RecvError.Closed => return length,
                else => return e,
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
                break :blk std.posix.send(self.handle, buffer, 0) catch |e| return switch (e) {
                    std.posix.SendError.WouldBlock => {
                        Frame.yield();
                        continue;
                    },
                    std.posix.SendError.ConnectionResetByPeer,
                    std.posix.SendError.BrokenPipe,
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
                SendError.Closed => return length,
                else => return e,
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
        interface: std.Io.Writer,

        pub fn init(socket: Socket, rt: *Runtime, buffer: []u8) Writer {
            return .{
                .socket = socket,
                .rt = rt,
                .interface = initInterface(buffer),
            };
        }

        pub fn initInterface(buffer: []u8) std.Io.Writer {
            return .{
                .vtable = &.{
                    .drain = drain,
                    .sendFile = sendFile,
                },
                .buffer = buffer,
            };
        }

        pub fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
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
            io_w: *std.Io.Writer,
            file_reader: *std.fs.File.Reader,
            limit: std.Io.Limit,
        ) std.Io.Writer.FileError!usize {
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
        interface: std.Io.Reader,

        pub fn init(socket: Socket, rt: *Runtime, buffer: []u8) Reader {
            return .{
                .socket = socket,
                .rt = rt,
                .interface = initInterface(buffer),
            };
        }

        pub fn initInterface(buffer: []u8) std.Io.Reader {
            return .{
                .vtable = &.{
                    .stream = Reader.stream,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            };
        }

        fn stream(io_reader: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
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
    pub fn stream_to(from: Socket, to_w: *std.Io.Writer, rt: *Runtime) !void {
        debug.assert(to_w.buffer.len > 0);

        var file = from.reader(rt, &.{});
        const file_r = &file.interface;
        while (true) {
            _ = Reader.stream(file_r, to_w, .limited(to_w.buffer.len)) catch |e| switch (e) {
                error.EndOfStream => break,
                else => {
                    return e;
                },
            };
            _ = to_w.vtable.drain(to_w, &.{}, 0) catch break;
        }
    }
};
