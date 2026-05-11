const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const StdFile = Io.File;
const StdDir = Io.Dir;
const builtin = @import("builtin");
const io = @import("../io.zig");

const Resulted = @import("../aio/completion.zig").Resulted;
const OpenFileResult = @import("../aio/completion.zig").OpenFileResult;
const OpenError = @import("../aio/completion.zig").OpenError;
const StatResult = @import("../aio/completion.zig").StatResult;
const StatError = @import("../aio/completion.zig").StatError;
const ReadResult = @import("../aio/completion.zig").ReadResult;
const ReadError = @import("../aio/completion.zig").ReadError;
const WriteResult = @import("../aio/completion.zig").WriteResult;
const WriteError = @import("../aio/completion.zig").WriteError;
const FileMode = @import("../aio/lib.zig").FileMode;
const AsyncOpenFlags = @import("../aio/lib.zig").AsyncOpenFlags;
const Cross = @import("../cross/lib.zig");
const Frame = @import("../frame/lib.zig").Frame;
const Runtime = @import("../runtime/lib.zig").Runtime;
const Path = @import("lib.zig").Path;
const Stat = @import("lib.zig").Stat;

const log = std.log.scoped(.@"tardy/fs/file");

pub const Writer = struct {
    file: File,
    err: ?anyerror = null,
    pos: u64 = 0,
    rt: *Runtime,
    interface: Io.Writer,

    pub fn init(file: File, rt: *Runtime, buffer: []u8) Writer {
        return .{
            .file = file,
            .rt = rt,
            .interface = initInterface(buffer),
        };
    }

    pub fn initInterface(buffer: []u8) Io.Writer {
        return .{
            .vtable = &.{
                .drain = drain,
                .sendFile = sendFile,
            },
            .buffer = buffer,
        };
    }

    pub fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
        const buffered = io_w.buffered();
        if (buffered.len != 0) {
            const n = w.file.write(w.rt, buffered, w.pos) catch |err| {
                w.err = err;
                return error.WriteFailed;
            };
            w.pos += n;
            return io_w.consume(n);
        }
        for (data[0 .. data.len - 1]) |buf| {
            if (buf.len == 0) continue;
            const n = w.file.write(w.rt, buf, w.pos) catch |err| {
                w.err = err;
                return error.WriteFailed;
            };
            w.pos += n;
            return io_w.consume(n);
        }
        const pattern = data[data.len - 1];
        if (pattern.len == 0 or splat == 0) return 0;
        const n = w.file.write(w.rt, pattern, w.pos) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
        w.pos += n;
        return io_w.consume(n);
    }

    pub fn sendFile(
        io_w: *Io.Writer,
        file_reader: *Io.File.Reader,
        limit: Io.Limit,
    ) Io.Writer.FileError!usize {
        _ = io_w; // autofix
        _ = file_reader; // autofix
        _ = limit; // autofix
        return error.Unimplemented;
    }
};

pub const Reader = struct {
    file: File,
    err: ?anyerror = null,
    size: ?u64 = null,
    pos: u64 = 0,
    rt: *Runtime,
    interface: Io.Reader,

    pub fn init(file: File, rt: *Runtime, buffer: []u8) Reader {
        return .{
            .file = file,
            .rt = rt,
            .interface = initInterface(buffer),
        };
    }

    pub fn initInterface(buffer: []u8) Io.Reader {
        return .{
            .vtable = &.{
                .stream = stream,
            },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        };
    }

    pub fn stream(io_reader: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
        const w_dest = limit.slice(try w.writableSliceGreedy(1));

        const n = r.file.read(r.rt, w_dest, r.pos) catch |err| switch (err) {
            error.EndOfFile => {
                r.size = r.pos;
                return error.EndOfStream;
            },
            else => {
                r.err = err;
                return error.ReadFailed;
            },
        };
        r.pos += n;
        w.advance(n);
        return n;
    }
};

pub const File = packed struct {
    handle: std.posix.fd_t,

    pub fn reader(file: File, rt: *Runtime, buffer: []u8) Reader {
        return .init(file, rt, buffer);
    }

    pub fn writer(file: File, rt: *Runtime, buffer: []u8) Writer {
        return .init(file, rt, buffer);
    }

    pub const CreateFlags = struct {
        mode: FileMode = .write,
        perms: isize = 0o644,
        truncate: bool = true,
        overwrite: bool = true,
    };

    pub const OpenFlags = struct {
        mode: FileMode = .read,
    };

    pub fn to_std(self: File) Io.File {
        return .{
            .handle = self.handle,
            .flags = .{ .nonblocking = false },
        };
    }

    pub fn from_std(self: Io.File) File {
        return .{ .handle = self.handle };
    }

    /// Get `stdout` as a File.
    pub fn std_out() File {
        return .{ .handle = Cross.get_std_out() };
    }

    /// Get `stdin` as a File.
    pub fn std_in() File {
        return .{ .handle = Cross.get_std_in() };
    }

    /// Get `stderr` as a File.
    pub fn std_err() File {
        return .{ .handle = Cross.get_std_err() };
    }

    pub fn close(self: File, rt: *Runtime) !void {
        if (rt.aio.features.has_capability(.close))
            try rt.scheduler.io_await(.{ .close = self.handle })
        else
            io.close(self.handle);
    }

    pub fn close_blocking(self: File) void {
        io.close(self.handle);
    }

    pub fn create(rt: *Runtime, path: Path, flags: CreateFlags) !File {
        const aio_flags: AsyncOpenFlags = .{
            .mode = flags.mode,
            .perms = flags.perms,
            .create = true,
            .truncate = flags.truncate,
            .exclusive = !flags.overwrite,
            .directory = false,
        };

        if (rt.aio.features.has_capability(.open)) {
            try rt.scheduler.io_await(.{ .open = .{ .path = path, .flags = aio_flags } });

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get(index);

            const result: OpenFileResult = switch (task.result.open) {
                .actual => |actual| .{ .actual = actual.file },
                .err => |err| .{ .err = err },
            };

            return try result.unwrap();
        } else {
            const std_flags: StdFile.CreateFlags = .{
                .read = (aio_flags.mode == .read or aio_flags.mode == .read_write),
                .truncate = aio_flags.truncate,
                .exclusive = aio_flags.exclusive,
            };

            switch (path) {
                .rel => |inner| {
                    const dir: StdDir = .{ .handle = inner.dir };
                    const opened: StdFile = blk: while (true) {
                        break :blk dir.createFile(rt.io, inner.path, std_flags) catch |e| return switch (e) {
                            error.WouldBlock => {
                                Frame.yield();
                                continue;
                            },
                            error.AccessDenied => OpenError.AccessDenied,
                            error.BadPathName => OpenError.InvalidArguments,
                            error.DeviceBusy => OpenError.Busy,
                            error.SystemFdQuotaExceeded => OpenError.SystemFdQuotaExceeded,
                            error.ProcessFdQuotaExceeded => OpenError.ProcessFdQuotaExceeded,
                            error.FileNotFound => OpenError.NotFound,
                            error.PipeBusy => OpenError.Busy,
                            error.FileTooBig => OpenError.FileTooBig,
                            error.IsDir => OpenError.IsDirectory,
                            error.NameTooLong => OpenError.NameTooLong,
                            error.NoDevice => OpenError.DeviceNotFound,
                            error.NoSpaceLeft => OpenError.NoSpace,
                            error.NotDir => OpenError.NotADirectory,
                            error.PathAlreadyExists => OpenError.AlreadyExists,
                            error.SymLinkLoop => OpenError.Loop,
                            error.SystemResources => OpenError.OutOfMemory,
                            else => OpenError.Unexpected,
                        };
                    };
                    try Cross.fd.to_nonblock(opened.handle);

                    return .{ .handle = opened.handle };
                },
                .abs => |inner| {
                    const opened: StdFile = blk: while (true) {
                        break :blk Io.Dir.createFileAbsolute(rt.io, inner, std_flags) catch |e| return switch (e) {
                            error.WouldBlock => {
                                Frame.yield();
                                continue;
                            },
                            error.AccessDenied => OpenError.AccessDenied,
                            error.BadPathName => OpenError.InvalidArguments,
                            error.DeviceBusy, error.PipeBusy => OpenError.Busy,
                            error.SystemFdQuotaExceeded => OpenError.SystemFdQuotaExceeded,
                            error.ProcessFdQuotaExceeded => OpenError.ProcessFdQuotaExceeded,
                            error.FileNotFound => OpenError.NotFound,
                            error.FileTooBig => OpenError.FileTooBig,
                            error.IsDir => OpenError.IsDirectory,
                            error.NameTooLong => OpenError.NameTooLong,
                            error.NoDevice => OpenError.DeviceNotFound,
                            error.NoSpaceLeft => OpenError.NoSpace,
                            error.NotDir => OpenError.NotADirectory,
                            error.PathAlreadyExists => OpenError.AlreadyExists,
                            error.SymLinkLoop => OpenError.Loop,
                            error.SystemResources => OpenError.OutOfMemory,
                            else => OpenError.Unexpected,
                        };
                    };
                    try Cross.fd.to_nonblock(opened.handle);

                    return .{ .handle = opened.handle };
                },
            }
        }
    }

    pub fn open(rt: *Runtime, path: Path, flags: OpenFlags) !File {
        if (rt.aio.features.has_capability(.open)) {
            const aio_flags: AsyncOpenFlags = .{
                .mode = flags.mode,
                .create = false,
                .directory = false,
            };

            try rt.scheduler.io_await(.{ .open = .{ .path = path, .flags = aio_flags } });

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get(index);
            const result: OpenFileResult = switch (task.result.open) {
                .actual => |actual| .{ .actual = actual.file },
                .err => |err| .{ .err = err },
            };

            return try result.unwrap();
        } else {
            const std_flags: StdFile.OpenFlags = .{
                .mode = switch (flags.mode) {
                    .read => .read_only,
                    .write => .write_only,
                    .read_write => .read_write,
                },
            };

            switch (path) {
                .rel => |inner| {
                    const dir: StdDir = .{ .handle = inner.dir };
                    const opened: StdFile = blk: while (true) {
                        break :blk dir.openFile(rt.io, inner.path, std_flags) catch |e| return switch (e) {
                            error.WouldBlock => {
                                Frame.yield();
                                continue;
                            },
                            error.AccessDenied => OpenError.AccessDenied,
                            error.BadPathName => OpenError.InvalidArguments,
                            error.DeviceBusy => OpenError.Busy,
                            error.SystemFdQuotaExceeded => OpenError.SystemFdQuotaExceeded,
                            error.ProcessFdQuotaExceeded => OpenError.ProcessFdQuotaExceeded,
                            error.FileNotFound => OpenError.NotFound,
                            error.PipeBusy => OpenError.Busy,
                            error.FileTooBig => OpenError.FileTooBig,
                            error.IsDir => OpenError.IsDirectory,
                            error.NameTooLong => OpenError.NameTooLong,
                            error.NoDevice => OpenError.DeviceNotFound,
                            error.NoSpaceLeft => OpenError.NoSpace,
                            error.NotDir => OpenError.NotADirectory,
                            error.PathAlreadyExists => OpenError.AlreadyExists,
                            error.SymLinkLoop => OpenError.Loop,
                            error.SystemResources => OpenError.OutOfMemory,
                            else => OpenError.Unexpected,
                        };
                    };
                    try Cross.fd.to_nonblock(opened.handle);

                    return .{ .handle = opened.handle };
                },
                .abs => |inner| {
                    const opened: StdFile = blk: while (true) {
                        break :blk Io.Dir.openFileAbsolute(rt.io, inner, std_flags) catch |e| return switch (e) {
                            error.WouldBlock => {
                                Frame.yield();
                                continue;
                            },
                            error.AccessDenied => OpenError.AccessDenied,
                            error.BadPathName => OpenError.InvalidArguments,
                            error.DeviceBusy, error.PipeBusy => OpenError.Busy,
                            error.SystemFdQuotaExceeded => OpenError.SystemFdQuotaExceeded,
                            error.ProcessFdQuotaExceeded => OpenError.ProcessFdQuotaExceeded,
                            error.FileNotFound => OpenError.NotFound,
                            error.FileTooBig => OpenError.FileTooBig,
                            error.IsDir => OpenError.IsDirectory,
                            error.NameTooLong => OpenError.NameTooLong,
                            error.NoDevice => OpenError.DeviceNotFound,
                            error.NoSpaceLeft => OpenError.NoSpace,
                            error.NotDir => OpenError.NotADirectory,
                            error.PathAlreadyExists => OpenError.AlreadyExists,
                            error.SymLinkLoop => OpenError.Loop,
                            error.SystemResources => OpenError.OutOfMemory,
                            else => OpenError.Unexpected,
                        };
                    };
                    try Cross.fd.to_nonblock(opened.handle);

                    return .{ .handle = opened.handle };
                },
            }
        }
    }

    pub fn read(self: File, rt: *Runtime, buffer: []u8, offset: ?usize) !usize {
        if (rt.aio.features.has_capability(.read)) {
            try rt.scheduler.io_await(.{
                .read = .{
                    .fd = self.handle,
                    .buffer = buffer,
                    .offset = offset,
                },
            });

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get(index);
            return try task.result.read.unwrap();
        } else {
            const std_file = self.to_std();

            const count = blk: {
                if (offset) |o| {
                    while (true) {
                        break :blk std_file.readPositionalAll(rt.io, buffer, o) catch |e| return switch (e) {
                            error.WouldBlock => {
                                Frame.yield();
                                continue;
                            },
                            error.Unseekable => unreachable,
                            error.AccessDenied => ReadError.AccessDenied,
                            error.NotOpenForReading => ReadError.InvalidFd,
                            error.InputOutput => ReadError.IoError,
                            error.IsDir => ReadError.IsDirectory,
                            else => ReadError.Unexpected,
                        };
                    }
                } else {
                    while (true) {
                        break :blk std_file.readStreaming(rt.io, &.{buffer}) catch |e| return switch (e) {
                            error.WouldBlock => {
                                Frame.yield();
                                continue;
                            },
                            error.AccessDenied => ReadError.AccessDenied,
                            error.NotOpenForReading => ReadError.InvalidFd,
                            error.InputOutput => ReadError.IoError,
                            error.IsDir => ReadError.IsDirectory,
                            else => ReadError.Unexpected,
                        };
                    }
                }
            };

            if (count == 0) return ReadError.EndOfFile;
            return count;
        }
        return .{ .file = self, .buffer = buffer, .offset = offset };
    }

    pub fn read_all(self: File, rt: *Runtime, buffer: []u8, offset: ?usize) !usize {
        var length: usize = 0;

        while (length < buffer.len) {
            const real_offset: ?usize = if (offset) |o| o + length else null;

            const result = self.read(rt, buffer[length..], real_offset) catch |e| switch (e) {
                error.EndOfFile => return length,
                else => |err| return err,
            };

            length += result;
        }

        return length;
    }

    pub fn write(self: File, rt: *Runtime, buffer: []const u8, offset: ?usize) WriteError!usize {
        if (rt.aio.features.has_capability(.write)) {
            rt.scheduler.io_await(.{
                .write = .{ .fd = self.handle, .buffer = buffer, .offset = offset },
            }) catch unreachable;

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get(index);
            return try task.result.write.unwrap();
        } else {
            const std_file = self.to_std();

            // TODO: Proper and improved error handling (also why not error.*)
            if (offset) |o| {
                return blk: while (true) {
                    break :blk std_file.writePositional(rt.io, &.{buffer}, o) catch |e| switch (e) {
                        error.WouldBlock => {
                            Frame.yield();
                            continue;
                        },
                        error.Unseekable => unreachable,
                        error.DiskQuota => WriteError.DiskQuotaExceeded,
                        error.FileTooBig => WriteError.FileTooBig,
                        error.InputOutput => WriteError.IoError,
                        error.NoSpaceLeft => WriteError.NoSpace,
                        error.AccessDenied => WriteError.AccessDenied,
                        error.NotOpenForWriting => WriteError.InvalidFd,
                        error.BrokenPipe => WriteError.BrokenPipe,
                        else => WriteError.Unexpected,
                    };
                };
            } else {
                return blk: while (true) {
                    break :blk std_file.writeStreaming(rt.io, &.{}, &.{buffer}, 0) catch |e| switch (e) {
                        error.WouldBlock => {
                            Frame.yield();
                            continue;
                        },
                        error.DiskQuota => WriteError.DiskQuotaExceeded,
                        error.FileTooBig => WriteError.FileTooBig,
                        error.InputOutput => WriteError.IoError,
                        error.NoSpaceLeft => WriteError.NoSpace,
                        error.AccessDenied => WriteError.AccessDenied,
                        error.NotOpenForWriting => WriteError.InvalidFd,
                        error.BrokenPipe => WriteError.BrokenPipe,
                        else => WriteError.Unexpected,
                    };
                };
            }
        }
    }

    pub fn write_all(self: File, rt: *Runtime, buffer: []const u8, offset: ?usize) WriteError!usize {
        var length: usize = 0;

        while (length < buffer.len) {
            const real_offset: ?usize = if (offset) |o| o + length else null;

            const result = self.write(rt, buffer[length..], real_offset) catch |e| switch (e) {
                error.NoSpace => return length,
                else => |err| return err,
            };

            length += result;
        }

        return length;
    }

    pub fn stat(self: File, rt: *Runtime) !Stat {
        if (rt.aio.features.has_capability(.stat)) {
            try rt.scheduler.io_await(.{ .stat = self.handle });

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get(index);
            return try task.result.stat.unwrap();
        } else {
            const std_file = self.to_std();

            const file_stat = std_file.stat(rt.io) catch |e| {
                return switch (e) {
                    error.AccessDenied => StatError.AccessDenied,
                    error.SystemResources => StatError.OutOfMemory,
                    error.Unexpected => StatError.Unexpected,
                    error.PermissionDenied => StatError.PermissionDenied,
                    error.Streaming, error.Canceled => unreachable,
                };
            };

            return .{
                .size = file_stat.size,
                .changed = file_stat.ctime,
                .modified = file_stat.mtime,
                .accessed = file_stat.atime,
            };
        }
    }

    // TODO: sendFile like api is a more appropriate for this
    pub fn stream_to(from: File, to_w: *Io.Writer, rt: *Runtime) !void {
        std.debug.assert(to_w.buffer.len > 0);

        var file = from.reader(rt, &.{});
        const file_r = &file.interface;
        while (true) {
            _ = Reader.stream(file_r, to_w, .limited(to_w.buffer.len)) catch |e| switch (e) {
                error.EndOfStream => break,
                else => |err| return err,
            };
            _ = to_w.vtable.drain(to_w, &.{}, 0) catch break;
        }
    }
};
