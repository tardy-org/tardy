threadlocal var file_chain_counter: usize = 0;

pub fn start_frame(rt: *Runtime, shared_params: *const e2e.Params) !void {
    errdefer unreachable;

    const new_dir = try Dir.cwd().create_dir(rt, shared_params.seed_string);
    log.debug("created new shared dir (seed={d})", .{shared_params.seed});

    var prng: std.Random.DefaultPrng = .init(shared_params.seed);
    const rand = prng.random();

    const rand_int = rand.intRangeAtMost(usize, 1, 2);
    const chain_count = shared_params.size_tasks_initial * rand_int;
    file_chain_counter = chain_count;

    log.debug("creating file chains... ({d})", .{chain_count});
    for (0..chain_count) |i| {
        var prng2: std.Random.DefaultPrng = .init(shared_params.seed + i);
        const rand2 = prng2.random();

        const chain_ptr = try rt.allocator.create(FileChain);
        errdefer rt.allocator.destroy(chain_ptr);

        const sub_chain = try FileChain.generate_random_chain(
            rt.allocator,
            (shared_params.seed + i) % std.math.maxInt(usize),
        );
        defer rt.allocator.free(sub_chain);

        const subpath = try std.fmt.allocPrintSentinel(
            rt.allocator,
            "{s}-{d}",
            .{ shared_params.seed_string, i },
            0x0,
        );
        defer rt.allocator.free(subpath);

        chain_ptr.* = try .init(
            rt.allocator,
            sub_chain,
            .{ .rel = .{ .dir = new_dir.handle, .path = subpath } },
            rand2.intRangeLessThan(usize, 1, 64),
        );
        errdefer chain_ptr.deinit(rt.allocator);

        try rt.spawn(
            FileChain.chain_frame,
            .{ chain_ptr, rt, &file_chain_counter, shared_params.seed_string },
            if (is_unix) .KiB(48) else .MiB(2),
        );
    }
}

const is_unix = builtin.os.tag != .windows;

const log = std.log.scoped(.@"tardy/e2e/first");

const std = @import("std");
const builtin = @import("builtin");

const tardy = @import("tardy");
const Dir = tardy.fs.Dir;
const Runtime = tardy.Runtime;

const FileChain = @import("FileChain.zig");
const e2e = @import("e2e.zig");
