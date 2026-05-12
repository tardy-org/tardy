const std = @import("std");
const Io = std.Io;

const tardy = @import("tardy");
const Dir = tardy.Dir;
const File = tardy.File;
const Runtime = tardy.Runtime;
const Stat = tardy.Stat;
const StatResult = tardy.StatResult;
const Task = tardy.Task;

const Tardy = tardy.Tardy(.auto);
const log = std.log.scoped(.@"tardy/example/stat");

fn main_frame(rt: *Runtime, name: [:0]const u8) !void {
    const file = try Dir.cwd().open_file(rt, name, .{});
    defer file.close_blocking();

    const stat = try file.stat(rt);
    log.info("stat: {any}", .{stat});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var td: Tardy = try .init(arena, init.io, .{
        .threading = .single,
    });
    defer td.deinit();

    var stdout = Io.File.stdout().writer(init.io, &.{});
    defer stdout.flush() catch unreachable;
    const stdout_w = &stdout.interface;

    var i: usize = 0;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    const file_name: [:0]const u8 = blk: {
        while (args.next()) |arg| : (i += 1) {
            if (i == 1) break :blk arg;
        }

        try stdout_w.writeAll("file name not passed in: ./stat [file name]");
        return;
    };

    try td.entry(
        file_name,
        struct {
            fn init_fn(rt: *Runtime, path: [:0]const u8) !void {
                try rt.spawn(.{ rt, path }, main_frame, 1024 * 1024 * 2);
            }
        }.init_fn,
    );
}
