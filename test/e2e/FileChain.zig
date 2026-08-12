pub const FileChain = @This();

file: ?fs.File = null,
path: fs.Path,
steps: []Step,
index: usize = 0,
buffer: []u8,

// Path is expected to remain valid.
pub fn init(
    gpa: mem.Allocator,
    chain: []const Step,
    path: fs.Path,
    buffer_size: usize,
) !FileChain {
    debug.assert(chain.len > 0);

    const chain_dupe = try gpa.dupe(Step, chain);
    errdefer gpa.free(chain_dupe);

    const path_dupe = try path.dupe(gpa);
    errdefer switch (path_dupe) {
        .rel => |rel| gpa.free(rel.path),
        .abs => |abs| gpa.free(abs),
    };

    debug.assert(validate_chain(chain));

    const buffer = try gpa.alloc(u8, buffer_size);
    errdefer gpa.free(buffer);

    return .{
        .steps = chain_dupe,
        .path = path_dupe,
        .buffer = buffer,
    };
}

pub fn deinit(file_chain: *FileChain, gpa: mem.Allocator) void {
    defer gpa.free(file_chain.steps);
    defer gpa.free(file_chain.buffer);
    defer switch (file_chain.path) {
        .rel => |rel| gpa.free(rel.path),
        .abs => |abs| gpa.free(abs),
    };
}

pub fn generate_random_chain(gpa: mem.Allocator, seed: u64) ![]Step {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();

    var list: std.ArrayList(Step) = try .initCapacity(gpa, 0);
    defer list.deinit(gpa);
    try list.append(gpa, .create);

    while (true) {
        const potentials = next_steps(list.last().?.*);
        if (potentials.len == 0) break;
        const potential = rand.intRangeLessThan(
            usize,
            0,
            potentials.len,
        );
        try list.append(gpa, potentials[potential]);
    }

    return try list.toOwnedSlice(gpa);
}

pub fn chain_frame(
    chain: *FileChain,
    rt: *Runtime,
    counter: *usize,
    seed_string: [:0]const u8,
) !void {
    defer rt.gpa.destroy(chain);
    defer chain.deinit(rt.gpa);

    var read_head: usize = 0;
    var write_head: usize = 0;

    while (chain.index < chain.steps.len) : (chain.index += 1) {
        switch (chain.steps[chain.index]) {
            .create => {
                const file: fs.File = try .create(rt, chain.path, .{
                    .mode = .read_write,
                });
                chain.file = file;
            },
            .open => {
                const file: fs.File = try .open(rt, chain.path, .{
                    .mode = .read_write,
                });
                chain.file = file;
            },
            .read => {
                const length = try chain.file.?.read_all(
                    rt,
                    chain.buffer,
                    read_head,
                );
                debug.assert(length == @min(chain.buffer.len, write_head - read_head));
                for (chain.buffer[0..length]) |item| debug.assert(item == 123);
                read_head += length;
            },
            .write => {
                for (chain.buffer[0..]) |*item| item.* = 123;
                write_head += try chain.file.?.write_all(
                    rt,
                    chain.buffer,
                    write_head,
                );
            },
            .stat => {
                const stat = try chain.file.?.stat(rt);
                debug.assert(stat.size == write_head);
            },
            .close => try chain.file.?.close(rt),
            .delete => {
                const dir: fs.Dir = .{ .handle = chain.path.rel.dir };
                try dir.delete_file(rt, chain.path.rel.path);
                counter.* -= 1;
            },
        }
    }

    if (counter.* == 0) {
        log.debug("deleting the e2e tree...", .{});
        try fs.Dir.cwd().delete_tree(rt, seed_string);
    }
}

pub fn next_steps(current: Step) []const Step {
    switch (current) {
        .create, .open, .read, .write, .stat => return &.{ .read, .write, .stat, .close },
        .close => return &.{ .open, .delete },
        .delete => return &.{},
    }
}

pub fn validate_chain(chain: []const Step) bool {
    if (chain.len < 3) return false;
    if (chain[0] != .create) return false;
    if (chain[chain.len - 1] != .delete) return false;

    chain: for (chain[0 .. chain.len - 1], chain[1..]) |prev, curr| {
        const steps = next_steps(prev);
        for (steps[0..]) |step| if (curr == step) continue :chain;
        return false;
    }

    return true;
}

test "FileChain: Invalid Exists" {
    const chain: []const FileChain.Step = &.{
        .open,
        .read,
        .write,
        .close,
        .delete,
    };

    try testing.expect(!FileChain.validate_chain(chain));
}

test "FileChain: Invalid Opened" {
    const chain: []const FileChain.Step = &.{
        .create,
        .close,
        .read,
        .write,
    };

    try testing.expect(!FileChain.validate_chain(chain));
}

test "FileChain: Never Closed" {
    const chain: []const FileChain.Step = &.{
        .create,
        .delete,
    };

    try testing.expect(!FileChain.validate_chain(chain));
}

test "FileChain: Never Deleted" {
    const chain: []const FileChain.Step = &.{
        .create,
        .read,
        .stat,
        .write,
        .close,
    };

    try testing.expect(!FileChain.validate_chain(chain));
}

test "FileChain: Verify Double Close" {
    const chain: []const FileChain.Step = &.{
        .create,
        .read,
        .write,
        .close,
        .open,
        .read,
        .read,
        .read,
        .close,
        .delete,
    };

    try testing.expect(FileChain.validate_chain(chain));
}

test "FileChain: Validate Random Chain" {
    const gpa = testing.allocator;
    // Actually generates and tests a random FileChain :)
    var seed: u64 = undefined;
    try std.posix.getrandom(mem.asBytes(&seed));
    errdefer std.debug.print("failed seed: {d}\n", .{seed});

    const chain = try FileChain.generate_random_chain(
        gpa,
        seed,
    );
    defer gpa.free(chain);

    try testing.expect(FileChain.validate_chain(chain));
}

const log = std.log.scoped(.@"tardy/e2e/FileChain");

const Step = enum {
    create,
    open,
    read,
    write,
    stat,
    close,
    delete,
};

const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;

const tardy = @import("tardy");
const fs = tardy.fs;
const Runtime = tardy.Runtime;
