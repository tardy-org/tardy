const std = @import("std");
const Io = std.Io;

const options = @import("options");
const tardy = @import("tardy");
const Dir = tardy.fs.Dir;
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;
const AsyncIO = tardy.AsyncIO;

const backend: AsyncIO.Kind = .init(options.async_backend);
const Tardy = tardy.Tardy(backend);

const EntryParams = struct {
    file_name: [:0]const u8,
    server_socket: *const Socket,
};
const log = std.log.scoped(.@"tardy/example/stream");

fn stream_frame(rt: *Runtime, server: *const Socket, file_name: [:0]const u8) !void {
    defer rt.spawn(stream_frame, .{ rt, server, file_name }, .@"4MiB") catch unreachable;

    const socket = try server.accept(rt);
    defer socket.close_blocking();

    const file = try Dir.cwd().open_file(rt, file_name, .{});
    defer file.close_blocking();

    const time: std.Io.Timestamp = .now(rt.io, .awake);
    log.info(
        "{f} - accepted socket [{f}]",
        .{ time.untilNow(rt.io, .awake), socket.addr },
    );

    var buffer: [1024]u8 = undefined;
    var socket_w = socket.writer(rt, &buffer);
    const socket_sw = &socket_w.interface;
    defer socket_sw.flush() catch unreachable;

    file.stream_to(
        socket_sw,
        rt,
    ) catch unreachable;
}

pub fn main(init: std.process.Init) !void {
    const host = "0.0.0.0";
    const port = 9862;

    const server: Socket = try .init(init.io, .{ .tcp = .{ .host = host, .port = port } });
    try server.bind();
    try server.listen(1024);

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    var stdout = Io.File.stdout().writer(init.io, &.{});
    defer stdout.flush() catch unreachable;
    const stdout_w = &stdout.interface;

    const file_name: [:0]const u8 = blk: {
        var i: usize = 0;
        while (args.next()) |arg| : (i += 1) {
            if (i == 1) break :blk arg;
        }

        try stdout_w.writeAll("file name not passed in: ./stream [file name]");
        return;
    };

    var params: EntryParams = .{
        .file_name = file_name,
        .server_socket = &server,
    };

    var td: Tardy = try .init(init.gpa, init.io, .{
        .threading = .single,
        .pooling = .static,
        .size_tasks_initial = 2,
        .size_aio_reap_max = 1,
    });
    defer td.deinit();

    try td.entry(
        &params,
        struct {
            fn start(rt: *Runtime, p: *EntryParams) !void {
                try rt.spawn(
                    stream_frame,
                    .{ rt, p.server_socket, p.file_name },
                    .@"4MiB",
                );
            }
        }.start,
    );
}
