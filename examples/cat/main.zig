const std = @import("std");
const Io = std.Io;

const options = @import("options");
const tardy = @import("tardy");
const Dir = tardy.Dir;
const File = tardy.File;
const Runtime = tardy.Runtime;
const AsyncIO = tardy.AsyncIO;

const backend: AsyncIO.Kind = .init(options.async_backend);
const Tardy = tardy.Tardy(backend);

const log = std.log.scoped(.@"tardy/example/cat");
pub const std_options: std.Options = .{ .log_level = .info };

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
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    var stdout = Io.File.stdout().writer(init.io, &.{});
    defer stdout.flush() catch unreachable;
    const stdout_w = &stdout.interface;

    const file_name: [:0]const u8 = blk: {
        var i: usize = 0;
        while (args.next()) |arg| : (i += 1) {
            if (i == 1) break :blk arg;
        }

        try stdout_w.writeAll("file name not passed in: ./cat [file name]");
        return;
    };

    var params: EntryParams = .{
        .file_name = file_name,
    };

    var td: Tardy = try .init(init.gpa, init.io, .{
        .threading = .single,
        .pooling = .static,
        .size_tasks_initial = 1,
        .size_aio_reap_max = 1,
    });
    defer td.deinit();

    try td.entry(
        &params,
        struct {
            fn start(rt: *Runtime, p: *EntryParams) !void {
                try rt.spawn(main_frame, .{ rt, p }, .auto);
            }
        }.start,
    );
}
