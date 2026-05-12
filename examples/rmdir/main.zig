const std = @import("std");
const Io = std.Io;

const tardy = @import("tardy");
const Cross = tardy.Cross;
const Dir = tardy.Dir;
const Runtime = tardy.Runtime;
const Task = tardy.Task;

const Tardy = tardy.Tardy(.auto);
const log = std.log.scoped(.@"tardy/example/rmdir");

fn main_frame(rt: *Runtime, name: [:0]const u8) !void {
    try Dir.cwd().delete_tree(rt, name);
    log.info("deleted tree '{s}/' :)", .{name});
}

pub fn main(init: std.process.Init) !void {
    var stdout = Io.File.stdout().writer(init.io, &.{});
    defer stdout.flush() catch unreachable;
    const stdout_w = &stdout.interface;

    const arena = init.arena.allocator();

    var td: Tardy = try .init(arena, init.io, .{
        .threading = .single,
        .pooling = .static,
        .size_tasks_initial = 1,
        .size_aio_reap_max = 1,
    });
    defer td.deinit();

    var i: usize = 0;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    const tree_name: [:0]const u8 = blk: {
        while (args.next()) |arg| : (i += 1) {
            if (i == 1) break :blk arg;
        }

        try stdout_w.writeAll("tree name not passed in: ./rmdir [tree name]");
        return;
    };

    try td.entry(
        tree_name,
        struct {
            fn start(rt: *Runtime, name: [:0]const u8) !void {
                try rt.spawn(.{ rt, name }, main_frame, 1024 * 1024 * 2);
            }
        }.start,
    );
}
