const std = @import("std");
const Io = std.Io;

const tardy = @import("tardy");
const Cross = tardy.Cross;
const Dir = tardy.Dir;
const File = tardy.File;
const Frame = tardy.Frame;
const Runtime = tardy.Runtime;
const Task = tardy.Task;

const log = std.log.scoped(.@"tardy/example/cat");
pub const std_options: std.Options = .{ .log_level = .err };

const Tardy = tardy.Tardy(.auto);
const EntryParams = struct { file_name: [:0]const u8 };

fn main_frame(rt: *Runtime, p: *EntryParams) !void {
    const file = Dir.cwd().open_file(rt, p.file_name, .{}) catch |e| switch (e) {
        error.NotFound => {
            log.err("{s}: No such file!", .{p.file_name});
            return;
        },
        else => |err| return err,
    };

    var file_reader = file.reader(rt, &.{});
    const file_r = &file_reader.interface;

    var std_out = File.std_out().writer(rt, &.{});
    const stdout_w = &std_out.interface;
    defer stdout_w.flush() catch unreachable;

    var buffer: [1024 * 32]u8 = undefined;
    var done: bool = false;
    while (!done) {
        const length = file_r.readSliceShort(&buffer) catch unreachable;
        done = length < buffer.len;
        stdout_w.writeAll(buffer[0..length]) catch unreachable;
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var td: Tardy = try .init(arena, init.io, .{
        .threading = .single,
        .pooling = .static,
        .size_tasks_initial = 1,
        .size_aio_reap_max = 1,
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

        try stdout_w.writeAll("file name not passed in: ./cat [file name]");
        return;
    };

    var params: EntryParams = .{
        .file_name = file_name,
    };

    try td.entry(
        &params,
        struct {
            fn start(rt: *Runtime, p: *EntryParams) !void {
                try rt.spawn(.{ rt, p }, main_frame, 1024 * 1024 * 4);
            }
        }.start,
    );
}
