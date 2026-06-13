const std = @import("std");

const tardy = @import("tardy");
const AcceptResult = tardy.AcceptResult;
const Cross = tardy.Cross;
const Pool = tardy.Pool;
const RecvResult = tardy.RecvResult;
const Runtime = tardy.Runtime;
const SendResult = tardy.SendResult;
const Socket = tardy.Socket;
const Task = tardy.Task;
const Timer = tardy.Timer;

const Tardy = tardy.Tardy(.auto);
const log = std.log.scoped(.@"tardy/example/echo");

fn echo_frame(rt: *Runtime, server: *const Socket) !void {
    const socket = try server.accept(rt);
    defer socket.close_blocking();

    var sock_reader = socket.reader(rt, &.{});
    const sock_r = &sock_reader.interface;

    var sock_writer = socket.writer(rt, &.{});
    const sock_w = &sock_writer.interface;
    defer sock_w.flush() catch unreachable;

    const time: std.Io.Timestamp = .now(rt.io, .awake);
    log.info(
        "{f} - accepted socket [{f}]",
        .{ time.untilNow(rt.io, .awake), socket.addr },
    );

    // spawn off a new frame.
    try rt.spawn(.{ rt, server }, echo_frame, 1024 * 16);

    var buffer: [501]u8 = undefined;
    while (true) {
        const recv_length = sock_r.readSliceShort(&buffer) catch |e| {
            log.err("Failed to recv on socket | {t}", .{e});
            break;
        };

        if (recv_length == 0) return;

        sock_w.writeAll(buffer[0..recv_length]) catch |e| {
            log.err("Failed to send on socket | {t}", .{e});
            break;
        };

        log.info("Echoed: {s}", .{buffer[0..recv_length]});
    }
}

pub fn main(init: std.process.Init) !void {
    const host = "0.0.0.0";
    const port = 9862;

    const server: Socket = try .init(init.io, .{ .tcp = .{ .host = host, .port = port } });
    try server.bind();
    try server.listen(501);

    // tardy by default is
    // - multithreaded
    // - unbounded in terms of spawnable tasks
    var td: Tardy = try .init(init.gpa, init.io, .{
        .pooling = .static,
        .size_tasks_initial = 256,
        .size_aio_reap_max = 256,
    });
    defer td.deinit();

    try td.entry(
        &server,
        struct {
            fn start(rt: *Runtime, tcp_server: *const Socket) !void {
                try rt.spawn(.{ rt, tcp_server }, echo_frame, 1024 * 16);
            }
        }.start,
    );
}
