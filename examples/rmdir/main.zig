const std = @import("std");
const Io = std.Io;

const options = @import("options");
const tardy = @import("tardy");
const Dir = tardy.fs.Dir;
const Runtime = tardy.Runtime;
const AsyncIO = tardy.AsyncIO;

const backend: AsyncIO.Kind = .init(options.async_backend);
const Tardy = tardy.Tardy(backend);

const log = std.log.scoped(.@"tardy/example/rmdir");

fn main_frame(rt: *Runtime, name: [:0]const u8) !void {
    try Dir.cwd().delete_tree(rt, name);
    log.info("deleted tree '{s}/' :)", .{name});
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    var stdout = Io.File.stdout().writer(init.io, &.{});
    defer stdout.flush() catch unreachable;
    const stdout_w = &stdout.interface;

    const tree_name: [:0]const u8 = blk: {
        var i: usize = 0;
        while (args.next()) |arg| : (i += 1) {
            if (i == 1) break :blk arg;
        }

        try stdout_w.writeAll("tree name not passed in: ./rmdir [tree name]");
        return;
    };

    var td: Tardy = try .init(init.gpa, init.io, .{
        .threading = .single,
        .pooling = .static,
        .size_tasks_initial = 1,
        .size_aio_reap_max = 1,
    });
    defer td.deinit();

    try td.entry(
        tree_name,
        struct {
            fn start(rt: *Runtime, name: [:0]const u8) !void {
                try rt.spawn(main_frame, .{ rt, name }, .@"2MiB");
            }
        }.start,
    );
}
