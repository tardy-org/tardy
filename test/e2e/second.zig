threadlocal var tcp_client_chain_count: usize = 1;
threadlocal var tcp_server_chain_count: usize = 1;

pub fn start_frame(rt: *Runtime, shared_params: *const e2e.Params) !void {
    var prng: Random.DefaultPrng = .init(shared_params.seed);
    const rand = prng.random();

    const port: u16 = rand.intRangeLessThan(
        u16,
        30000,
        @intCast(std.math.maxInt(u16)),
    );
    log.debug("tcp chain port: {d}", .{port});

    const socket: Socket = try .init(.{
        .tcp = .{ .host = "127.0.0.1", .port = port },
    });
    try socket.bind();
    try socket.listen(128);

    const chain = try Server.generate_random_chain(
        rt.gpa,
        shared_params.seed,
    );
    defer rt.gpa.free(chain);

    log.debug("creating tcp chain... ({d})", .{chain.len});

    const server_chain_ptr = try rt.gpa.create(Server);
    errdefer rt.gpa.destroy(server_chain_ptr);

    const client_chain_ptr = try rt.gpa.create(Client);
    errdefer rt.gpa.destroy(client_chain_ptr);

    server_chain_ptr.* = try .init(rt.gpa, chain, 4096);
    client_chain_ptr.* = try server_chain_ptr.derive_client_chain(rt.gpa);

    try rt.spawn(
        Client.chain_frame,
        .{ client_chain_ptr, rt, &tcp_client_chain_count, port },
        .@"32KiB",
    );
    try rt.spawn(
        Server.chain_frame,
        .{ server_chain_ptr, rt, &tcp_server_chain_count, socket },
        .@"32KiB",
    );
}

const log = std.log.scoped(.@"tardy/e2e/second");

const std = @import("std");
const Random = std.Random;
const debug = std.debug;

const tardy = @import("tardy");
const Runtime = tardy.Runtime;
const Socket = tardy.net.Socket;

const e2e = @import("e2e.zig");
const tcp_chain = @import("tcp_chain.zig");
const Client = tcp_chain.Client;
const Server = tcp_chain.Server;
