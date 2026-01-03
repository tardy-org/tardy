const std = @import("std");

const AcceptResult = @import("tardy").AcceptResult;
const Cross = @import("tardy").Cross;
const Pool = @import("tardy").Pool;
const RecvResult = @import("tardy").RecvResult;
const Runtime = @import("tardy").Runtime;
const SendResult = @import("tardy").SendResult;
const Socket = @import("tardy").Socket;
const Task = @import("tardy").Task;
const Timer = @import("tardy").Timer;

const Tardy = @import("tardy").Tardy(.auto);
const log = std.log.scoped(.@"tardy/example/echo");

fn echo_frame(rt: *Runtime, server: *const Socket) !void {
    const socket = try server.accept(rt);
    defer socket.close_blocking();

    var sock_reader = socket.reader(rt, &.{});
    const sock_r = &sock_reader.interface;

    var sock_writer = socket.writer(rt, &.{});
    const sock_w = &sock_writer.interface;
    defer sock_w.flush() catch unreachable;

    log.debug(
        "{d} - accepted socket [{f}]",
        .{ std.time.milliTimestamp(), socket.addr },
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

        log.debug("Echoed: {s}", .{buffer[0..recv_length]});
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var tardy: Tardy = try .init(allocator, .{
        .threading = .single,
        .pooling = .static,
        .size_tasks_initial = 256,
        .size_aio_reap_max = 256,
    });
    defer tardy.deinit();

    const host = "0.0.0.0";
    const port = 9862;

    const server: Socket = try .init(.{ .tcp = .{ .host = host, .port = port } });
    try server.bind();
    try server.listen(1024);

    try tardy.entry(
        &server,
        struct {
            fn start(rt: *Runtime, tcp_server: *const Socket) !void {
                try rt.spawn(.{ rt, tcp_server }, echo_frame, 1024 * 16);
            }
        }.start,
    );
}
