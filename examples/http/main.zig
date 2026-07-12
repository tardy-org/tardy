const std = @import("std");

const options = @import("options");
const tardy = @import("tardy");
const Runtime = tardy.Runtime;
const Socket = tardy.net.Socket;
const AsyncIO = tardy.AsyncIO;

const backend: AsyncIO.Kind = .init(options.async_backend);
const Tardy = tardy.Tardy(backend);

const log = std.log.scoped(.@"tardy/example/http");

const HTTP_RESPONSE = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 27\r\nContent-Type: text/plain\r\n\r\nThis is an HTTP benchmark\r\n";

fn main_frame(rt: *Runtime, server: *const Socket) !void {
    const socket = try server.accept(rt);
    defer socket.close_blocking();

    const time: std.Io.Timestamp = .now(rt.io, .awake);
    log.info(
        "{f} - accepted socket [{f}]",
        .{ time.untilNow(rt.io, .awake), socket.addr },
    );

    // spawn off a new frame.
    try rt.spawn(main_frame, .{ rt, server }, .@"16KiB");

    var buffer: [1024]u8 = undefined;
    var recv_length: usize = 0;
    while (true) {
        recv_length += socket.recv(rt, &buffer) catch |e| {
            log.err("Failed to recv on socket | {}", .{e});
            return;
        };

        if (std.mem.indexOf(u8, buffer[0..recv_length], "\r\n\r\n")) |_| {
            _ = socket.send_all(rt, HTTP_RESPONSE[0..]) catch |e| {
                log.err("Failed to send on socket | {}", .{e});
                return;
            };
            recv_length = 0;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const host = "0.0.0.0";
    const port = 9862;

    const server: Socket = try .init(init.io, .{ .tcp = .{ .host = host, .port = port } });
    try server.bind();
    try server.listen(1024);

    var td: Tardy = try .init(init.gpa, init.io, .{
        .threading = .auto,
        .pooling = .grow,
        .size_tasks_initial = 256,
        .size_aio_reap_max = 1024,
    });
    defer td.deinit();

    try td.entry(
        &server,
        struct {
            fn start(rt: *Runtime, tcp_server: *const Socket) !void {
                try rt.spawn(main_frame, .{ rt, tcp_server }, .@"16KiB");
            }
        }.start,
    );
}
