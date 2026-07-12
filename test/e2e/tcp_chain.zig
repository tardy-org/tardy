const log = std.log.scoped(.@"tardy/e2e/tcp_chain");

pub const TcpServerChain = struct {
    const Step = enum {
        accept,
        recv,
        send,
        close,
    };

    allocator: mem.Allocator,
    socket: ?net.Socket = null,
    steps: []Step,
    index: usize = 0,
    buffer: []u8,

    pub fn next_steps(current: Step) []const Step {
        switch (current) {
            .accept, .recv, .send => return &.{ .recv, .send, .close },
            .close => return &.{},
        }
    }

    pub fn validate_chain(chain: []const Step) bool {
        if (chain.len < 2) return false;
        if (chain[0] != .accept) return false;
        if (chain[chain.len - 1] != .close) return false;

        chain: for (chain[0 .. chain.len - 1], chain[1..]) |prev, curr| {
            const steps = next_steps(prev);
            for (steps[0..]) |step| if (curr == step) continue :chain;
            return false;
        }

        return true;
    }

    pub fn generate_random_chain(allocator: mem.Allocator, seed: u64) ![]Step {
        var prng: std.Random.DefaultPrng = .init(seed);
        const rand = prng.random();

        var list: std.ArrayList(Step) = try .initCapacity(allocator, 0);
        defer list.deinit(allocator);
        try list.append(allocator, .accept);

        while (true) {
            const potentials = next_steps(list.last().?.*);
            if (potentials.len == 0) break;
            const potential = rand.intRangeLessThan(usize, 0, potentials.len);
            try list.append(allocator, potentials[potential]);
        }

        return try list.toOwnedSlice(allocator);
    }

    pub fn derive_client_chain(self: *const TcpServerChain) !TcpClientChain {
        debug.assert(self.steps.len > 0);

        const client_steps = try self.allocator.alloc(TcpClientChain.Step, self.steps.len);
        errdefer self.allocator.free(client_steps);

        for (self.steps, 0..) |step, i| {
            switch (step) {
                .accept => client_steps[i] = .connect,
                .recv => client_steps[i] = .send,
                .send => client_steps[i] = .recv,
                .close => client_steps[i] = .close,
            }
        }

        const buffer = try self.allocator.alloc(u8, self.buffer.len);
        errdefer self.allocator.free(buffer);

        return .{
            .allocator = self.allocator,
            .steps = client_steps,
            .buffer = buffer,
        };
    }

    // Path is expected to remain valid.
    pub fn init(allocator: mem.Allocator, chain: []const Step, buffer_size: usize) !TcpServerChain {
        debug.assert(chain.len > 0);

        const chain_dupe = try allocator.dupe(Step, chain);
        errdefer allocator.free(chain_dupe);
        debug.assert(validate_chain(chain));

        const buffer = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(buffer);

        return .{
            .allocator = allocator,
            .steps = chain_dupe,
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *const TcpServerChain) void {
        defer self.allocator.free(self.steps);
        defer self.allocator.free(self.buffer);
    }

    pub fn chain_frame(
        chain: *TcpServerChain,
        rt: *Runtime,
        counter: *usize,
        server_socket: net.Socket,
    ) !void {
        defer rt.allocator.destroy(chain);
        defer chain.deinit();
        errdefer unreachable;

        chain: while (chain.index < chain.steps.len) : (chain.index += 1) {
            const current_step = chain.steps[chain.index];
            log.debug("server chain step: {t}", .{current_step});
            switch (current_step) {
                .accept => {
                    const socket = try server_socket.accept(rt);
                    chain.socket = socket;
                },
                .recv => {
                    const length = chain.socket.?.recv(rt, chain.buffer) catch |e| switch (e) {
                        error.Closed => break :chain,
                        else => |err| return err,
                    };

                    for (chain.buffer[0..length]) |item| debug.assert(item == 123);
                },
                .send => {
                    for (chain.buffer[0..]) |*item| item.* = 123;
                    _ = try chain.socket.?.send_all(rt, chain.buffer);
                },
                .close => try chain.socket.?.close(rt),
            }
        }
        counter.* -= 1;

        if (counter.* == 0) {
            log.debug("closing main accept socket", .{});
            server_socket.close_blocking();
        }
    }
};

pub const TcpClientChain = struct {
    const Step = enum {
        connect,
        recv,
        send,
        close,
    };

    allocator: mem.Allocator,
    steps: []Step,
    index: usize = 0,
    buffer: []u8,

    pub fn deinit(self: *const TcpClientChain) void {
        defer self.allocator.free(self.steps);
        defer self.allocator.free(self.buffer);
    }

    pub fn chain_frame(chain: *TcpClientChain, rt: *Runtime, counter: *usize, port: u16) !void {
        defer rt.allocator.destroy(chain);
        defer chain.deinit();
        errdefer unreachable;

        var socket: net.Socket = try .init(rt.io, .{
            .tcp = .{ .host = "127.0.0.1", .port = port },
        });

        chain: while (chain.index < chain.steps.len) : (chain.index += 1) {
            const current_step = chain.steps[chain.index];
            log.debug("client chain step: {t}", .{current_step});
            switch (current_step) {
                .connect => try socket.connect(rt),
                .recv => {
                    const length = socket.recv(rt, chain.buffer) catch |e| switch (e) {
                        error.Closed => break :chain,
                        else => |err| return err,
                    };

                    for (chain.buffer[0..length]) |item| debug.assert(item == 123);
                },
                .send => {
                    for (chain.buffer[0..]) |*item| item.* = 123;
                    _ = try socket.send_all(rt, chain.buffer);
                },
                .close => {
                    log.debug("closing client socket", .{});
                    socket.close_blocking();
                },
            }
        }
        counter.* -= 1;

        if (counter.* == 0) {
            log.debug("tcp client chain done!", .{});
        }
    }
};

test "TcpServerChain: Proper Chain" {
    const chain: []const TcpServerChain.Step = &.{
        .accept,
        .recv,
        .send,
        .close,
    };

    try testing.expect(TcpServerChain.validate_chain(chain));
}

test "TcpServerChain: Validate Random Chain" {
    // Actually generates and tests a random TcpServerChain :)
    var seed: u64 = undefined;
    try std.posix.getrandom(mem.asBytes(&seed));

    const chain = try TcpServerChain.generate_random_chain(
        testing.allocator,
        seed,
    );
    defer testing.allocator.free(chain);

    errdefer {
        std.debug.print("failed seed: {d}\n", .{seed});
        for (chain) |item| {
            std.debug.print("action={t}\n", .{item});
        }
    }

    try testing.expect(TcpServerChain.validate_chain(chain));
}

const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;

const tardy = @import("tardy");
const net = tardy.net;
const Runtime = tardy.Runtime;
