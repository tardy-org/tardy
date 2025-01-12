const std = @import("std");
const builtin = @import("builtin");

const Runtime = @import("../runtime/lib.zig").Runtime;
const TaskFn = @import("../runtime/task.zig").TaskFn;

const AcceptTcpResult = @import("../aio/completion.zig").AcceptTcpResult;
const ConnectResult = @import("../aio/completion.zig").ConnectResult;
const RecvResult = @import("../aio/completion.zig").RecvResult;
const SendResult = @import("../aio/completion.zig").SendResult;

pub const TcpServer = struct {
    socket: std.posix.socket_t,

    pub fn from_std(server: std.net.Server) TcpServer {
        return .{ .socket = server.stream.handle };
    }

    pub fn to_std(self: TcpServer) std.net.Server {
        return std.net.Server{
            .stream = .{ .handle = self.socket },
            // This isn't really used in the impl so just ensure you don't use it.
            .listen_address = std.mem.zeroes(std.net.Address),
        };
    }

    pub fn init(host: []const u8, port: u16) !TcpServer {
        const addr = blk: {
            if (comptime builtin.os.tag == .linux) {
                break :blk try std.net.Address.resolveIp(host, port);
            } else {
                break :blk try std.net.Address.parseIp(host, port);
            }
        };

        const socket = try std.posix.socket(
            addr.any.family,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
            std.posix.IPPROTO.TCP,
        );

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

        try std.posix.bind(socket, &addr.any, addr.getOsSockLen());
        return .{ .socket = socket };
    }

    pub fn listen(self: *const TcpServer, backlog: usize) !void {
        try std.posix.listen(self.socket, @truncate(backlog));
    }

    pub fn accept(
        self: *const TcpServer,
        rt: *Runtime,
        task_ctx: anytype,
        comptime task_fn: TaskFn(AcceptTcpResult, @TypeOf(task_ctx)),
    ) !void {
        try rt.scheduler.spawn2(
            AcceptTcpResult,
            task_ctx,
            task_fn,
            .waiting,
            .{ .accept = .{ .socket = self.socket, .kind = .tcp } },
        );
    }

    pub fn close(
        self: *const TcpServer,
        rt: *Runtime,
        task_ctx: anytype,
        comptime task_fn: TaskFn(void, @TypeOf(task_ctx)),
    ) !void {
        try rt.scheduler.spawn2(void, task_ctx, task_fn, .waiting, .{ .close = self.socket });
    }

    pub fn close_blocking(self: *const TcpServer) !void {
        std.posix.close(self.socket);
    }
};

pub const TcpSocket = struct {
    socket: std.posix.socket_t,

    pub fn connect(
        rt: *Runtime,
        task_ctx: anytype,
        comptime task_fn: TaskFn(ConnectResult, @TypeOf(task_ctx)),
        host: []const u8,
        port: u16,
    ) !void {
        const addr = blk: {
            if (comptime builtin.os.tag == .linux) {
                break :blk try std.net.Address.resolveIp(host, port);
            } else {
                break :blk try std.net.Address.parseIp(host, port);
            }
        };

        const socket = try std.posix.socket(
            addr.any.family,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
            std.posix.IPPROTO.TCP,
        );

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

        try rt.scheduler.spawn2(
            ConnectResult,
            task_ctx,
            task_fn,
            .waiting,
            .{ .connect = .{ .socket = socket, .host = host, .port = port } },
        );
    }

    pub fn from_std(self: std.net.Server.Connection) TcpSocket {
        return .{ .socket = self.stream.handle };
    }

    pub fn to_std(self: TcpSocket) std.net.Server.Connection {
        return std.net.Server.Connection{
            .stream = .{ .handle = self.socket },
            // This isn't really used in the impl so just ensure you don't use it.
            .address = std.mem.zeroes(std.net.Address),
        };
    }

    pub fn recv(
        self: *const TcpSocket,
        rt: *Runtime,
        task_ctx: anytype,
        comptime task_fn: TaskFn(RecvResult, @TypeOf(task_ctx)),
        buffer: []u8,
    ) !void {
        try rt.scheduler.spawn2(
            RecvResult,
            task_ctx,
            task_fn,
            .waiting,
            .{ .recv = .{ .socket = self.socket, .buffer = buffer } },
        );
    }

    pub fn send(
        self: *const TcpSocket,
        rt: *Runtime,
        task_ctx: anytype,
        comptime task_fn: TaskFn(SendResult, @TypeOf(task_ctx)),
        buffer: []const u8,
    ) !void {
        try rt.scheduler.spawn2(
            SendResult,
            task_ctx,
            task_fn,
            .waiting,
            .{ .send = .{ .socket = self.socket, .buffer = buffer } },
        );
    }

    pub fn close(
        self: *const TcpSocket,
        rt: *Runtime,
        task_ctx: anytype,
        comptime task_fn: TaskFn(void, @TypeOf(task_ctx)),
    ) !void {
        try rt.scheduler.spawn2(void, task_ctx, task_fn, .waiting, .{ .close = self.socket });
    }

    pub fn close_blocking(self: *const TcpSocket) void {
        std.posix.close(self.socket);
    }
};
