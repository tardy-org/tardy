const std = @import("std");
const assert = std.debug.assert;
const tardy = @import("tardy");
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;

const SharedParams = @import("lib.zig").SharedParams;
const TcpClientChain = @import("tcp_chain.zig").TcpClientChain;
const TcpServerChain = @import("tcp_chain.zig").TcpServerChain;

const log = std.log.scoped(.@"tardy/e2e/second");

threadlocal var tcp_client_chain_count: usize = 1;
threadlocal var tcp_server_chain_count: usize = 1;

pub fn start_frame(rt: *Runtime, shared_params: *const SharedParams) !void {
    var prng: std.Random.DefaultPrng = .init(shared_params.seed);
    const rand = prng.random();

    const port: u16 = rand.intRangeLessThan(u16, 30000, @intCast(std.math.maxInt(u16)));
    log.debug("tcp chain port: {d}", .{port});

    const socket: Socket = try .init(rt.io, .{ .tcp = .{ .host = "127.0.0.1", .port = port } });
    try socket.bind();
    try socket.listen(128);

    const chain = try TcpServerChain.generate_random_chain(rt.allocator, shared_params.seed);
    defer rt.allocator.free(chain);

    log.debug("creating tcp chain... ({d})", .{chain.len});

    const server_chain_ptr = try rt.allocator.create(TcpServerChain);
    errdefer rt.allocator.destroy(server_chain_ptr);

    const client_chain_ptr = try rt.allocator.create(TcpClientChain);
    errdefer rt.allocator.destroy(client_chain_ptr);

    server_chain_ptr.* = try .init(rt.allocator, chain, 4096);
    client_chain_ptr.* = try server_chain_ptr.derive_client_chain();

    try rt.spawn(
        TcpClientChain.chain_frame,
        .{ client_chain_ptr, rt, &tcp_client_chain_count, port },
        .@"16KiB",
    );
    try rt.spawn(
        TcpServerChain.chain_frame,
        .{ server_chain_ptr, rt, &tcp_server_chain_count, socket },
        .@"16KiB",
    );
}
