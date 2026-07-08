const std = @import("std");
const Io = std.Io;

const tardy = @import("tardy");
const Cross = tardy.Cross;
const Dir = tardy.Dir;
const File = tardy.File;
const OpenFileResult = tardy.OpenFileResult;
const ReadResult = tardy.ReadResult;
const Runtime = tardy.Runtime;
const Task = tardy.Task;
const WriteResult = tardy.WriteResult;

const Tardy = tardy.Tardy(.auto);
pub const std_options: std.Options = .{ .log_level = .debug };

const log = std.log.scoped(.@"tardy/example/shove");

fn main_frame(rt: *Runtime, name: [:0]const u8) !void {
    const file = try Dir.cwd().create_file(rt, name, .{});
    for (0..8) |_| _ = try file.write_all(rt, "*shoved*\n", null);

    const stat = try file.stat(rt);
    log.info("size: {d}", .{stat.size});

    try file.close(rt);
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    var stdout = Io.File.stdout().writer(init.io, &.{});
    defer stdout.flush() catch unreachable;
    const stdout_w = &stdout.interface;

    const file_name: [:0]const u8 = blk: {
        var i: usize = 0;
        while (args.next()) |arg| : (i += 1) if (i == 1) break :blk arg;
        try stdout_w.writeAll("file name not passed in: ./shove [file name]");
        return;
    };

    var td: Tardy = try .init(init.gpa, init.io, .{
        .threading = .single,
        .pooling = .grow,
        .size_tasks_initial = 1,
        .size_aio_reap_max = 1,
    });
    defer td.deinit();

    try td.entry(
        file_name,
        struct {
            fn start(rt: *Runtime, name: [:0]const u8) !void {
                try rt.spawn(main_frame, .{ rt, name }, .@"2MiB");
            }
        }.start,
    );
}
