const std = @import("std");
const assert = std.debug.assert;
const StdDir = std.Io.Dir;
const builtin = @import("builtin");

const Resulted = @import("../aio/completion.zig").Resulted;
const OpenFileResult = @import("../aio/completion.zig").OpenFileResult;
const OpenDirResult = @import("../aio/completion.zig").OpenDirResult;
const OpenError = @import("../aio/completion.zig").OpenError;
const DeleteError = @import("../aio/completion.zig").DeleteError;
const DeleteResult = @import("../aio/completion.zig").DeleteResult;
const DeleteTreeResult = @import("../aio/completion.zig").DeleteTreeResult;
const StatResult = @import("../aio/completion.zig").StatResult;
const ReadResult = @import("../aio/completion.zig").ReadResult;
const WriteResult = @import("../aio/completion.zig").WriteResult;
const CreateDirResult = @import("../aio/completion.zig").CreateDirResult;
const MkdirResult = @import("../aio/completion.zig").MkdirResult;
const MkdirError = @import("../aio/completion.zig").MkdirError;
const StatError = @import("../aio/completion.zig").StatError;
const FileMode = @import("../aio/lib.zig").FileMode;
const AsyncOpenFlags = @import("../aio/lib.zig").AsyncOpenFlags;
const Runtime = @import("../runtime/lib.zig").Runtime;
const File = @import("lib.zig").File;
const Path = @import("lib.zig").Path;
const Stat = @import("lib.zig").Stat;

const log = std.log.scoped(.@"tardy/fs/dir");

const Io = std.Io;

pub const Dir = packed struct {
    handle: std.posix.fd_t,

    /// Create a std.fs.Dir from a Dir.
    pub fn to_std(self: Dir) std.fs.Dir {
        return std.fs.Dir{ .fd = self.handle };
    }

    /// Create a Dir from the std.fs.Dir
    pub fn from_std(self: Io.Dir) Dir {
        return .{ .handle = self.handle };
    }

    /// Get `cwd` as a Dir.
    pub fn cwd() Dir {
        return .{ .handle = Io.Dir.cwd().handle };
    }

    /// Close the underlying Handle of this Dir.
    pub fn close(self: Dir, rt: *Runtime) !void {
        if (rt.aio.features.has_capability(.close))
            try rt.scheduler.io_await(.{ .close = self.handle })
        else
            std.Io.File.close(.{ .handle = self.handle, .flags = .{ .nonblocking = false } }, rt.io);
    }

    pub fn close_blocking(self: Dir) void {
        std.posix.close(self.handle);
    }

    /// Open a Directory.
    pub fn open(rt: *Runtime, path: Path) !Dir {
        const flags: AsyncOpenFlags = .{
            .mode = .read,
            .create = false,
            .directory = true,
        };

        if (rt.aio.features.has_capability(.open)) {
            try rt.scheduler.io_await(.{ .open = .{ .path = path, .flags = flags } });

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get_ptr(index);

            const result: OpenDirResult = switch (task.result.open) {
                .actual => |actual| .{ .actual = actual.dir },
                .err => |err| .{ .err = err },
            };

            return try result.unwrap();
        } else {
            switch (path) {
                .rel => |inner| {
                    const dir: StdDir = .{ .fd = inner.dir };
                    const opened = dir.openDirZ(inner.path, .{ .iterate = true }) catch |e| {
                        return switch (e) {
                            StdDir.OpenError.AccessDenied => OpenError.AccessDenied,
                            else => OpenError.Unexpected,
                        };
                    };

                    return .{ .handle = opened.fd };
                },
                .abs => |inner| {
                    const opened = std.fs.openDirAbsoluteZ(inner, .{ .iterate = true }) catch |e| {
                        return switch (e) {
                            StdDir.OpenError.AccessDenied => OpenError.AccessDenied,
                            else => OpenError.Unexpected,
                        };
                    };

                    return .{ .handle = opened.fd };
                },
            }
        }
    }

    /// Creates and opens a Directory.
    pub fn create(rt: *Runtime, path: Path) !Dir {
        if (rt.aio.features.has_capability(.mkdir)) {
            try rt.scheduler.io_await(.{ .mkdir = .{ .path = path, .mode = 0o775 } });

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get_ptr(index);
            try task.result.mkdir.unwrap();

            return try Dir.open(rt, path);
        } else {
            switch (path) {
                .rel => |p| {
                    const dir: StdDir = .{ .fd = p.dir };
                    dir.makeDirZ(p.path) catch |e| {
                        return switch (e) {
                            else => MkdirError.Unexpected,
                        };
                    };
                },
                .abs => |p| {
                    std.fs.makeDirAbsoluteZ(p) catch |e| {
                        return switch (e) {
                            else => MkdirError.Unexpected,
                        };
                    };
                },
            }

            return try Dir.open(rt, path);
        }
    }

    /// Create a File relative to this Dir.
    pub fn create_file(self: Dir, rt: *Runtime, subpath: [:0]const u8, flags: File.CreateFlags) !File {
        return try File.create(rt, .{ .rel = .{ .dir = self.handle, .path = subpath } }, flags);
    }

    /// Open a File relative to this Dir.
    pub fn open_file(self: Dir, rt: *Runtime, subpath: [:0]const u8, flags: File.OpenFlags) !File {
        return try File.open(rt, .{ .rel = .{ .dir = self.handle, .path = subpath } }, flags);
    }

    /// Create a Dir relative to this Dir.
    pub fn create_dir(self: Dir, rt: *Runtime, subpath: [:0]const u8) !Dir {
        return try Dir.create(rt, .{ .rel = .{ .dir = self.handle, .path = subpath } });
    }

    /// Open a Dir relative to this Dir.
    pub fn open_dir(self: Dir, rt: *Runtime, subpath: [:0]const u8) !Dir {
        return try Dir.open(rt, .{ .rel = .{ .dir = self.handle, .path = subpath } });
    }

    /// Get Stat information of this Dir.
    pub fn stat(self: Dir, rt: *Runtime) !Stat {
        if (rt.aio.features.has_capability(.stat)) {
            try rt.scheduler.io_await(.{ .stat = self.handle });

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get_ptr(index);
            return try task.result.stat.unwrap();
        } else {
            const std_dir = self.to_std();
            const dir_stat = std_dir.stat() catch |e| {
                return switch (e) {
                    StdDir.StatError.AccessDenied => StatError.AccessDenied,
                    StdDir.StatError.SystemResources => StatError.OutOfMemory,
                    StdDir.StatError.Unexpected => StatError.Unexpected,
                };
            };

            return Stat{
                .size = dir_stat.size,
                .mode = dir_stat.mode,
                .changed = .{
                    .seconds = @intCast(@divTrunc(dir_stat.ctime, std.time.ns_per_s)),
                    .nanos = @intCast(@mod(dir_stat.ctime, std.time.ns_per_s)),
                },
                .modified = .{
                    .seconds = @intCast(@divTrunc(dir_stat.mtime, std.time.ns_per_s)),
                    .nanos = @intCast(@mod(dir_stat.mtime, std.time.ns_per_s)),
                },
                .accessed = .{
                    .seconds = @intCast(@divTrunc(dir_stat.atime, std.time.ns_per_s)),
                    .nanos = @intCast(@mod(dir_stat.atime, std.time.ns_per_s)),
                },
            };
        }
    }

    /// Delete a File within this Dir.
    pub fn delete_file(self: Dir, rt: *Runtime, subpath: [:0]const u8) !void {
        if (rt.aio.features.has_capability(.delete)) {
            try rt.scheduler.io_await(.{
                .delete = .{
                    .path = .{ .rel = .{ .dir = self.handle, .path = subpath } },
                    .is_dir = false,
                },
            });
        } else {
            const std_dir = self.to_std();
            return std_dir.deleteFileZ(subpath) catch |e| switch (e) {
                else => DeleteError.Unexpected,
            };
        }
    }

    /// Delete a Dir within this Dir.
    pub fn delete_dir(self: Dir, rt: *Runtime, subpath: [:0]const u8) !void {
        if (rt.aio.features.has_capability(.delete)) {
            try rt.scheduler.io_await(.{
                .delete = .{
                    .path = .{ .rel = .{ .dir = self.handle, .path = subpath } },
                    .is_dir = true,
                },
            });
        } else {
            const std_dir = self.to_std();
            return std_dir.deleteDirZ(subpath) catch |e| switch (e) {
                else => DeleteError.Unexpected,
            };
        }
    }

    /// This will iterate through the Directory at the path given,
    /// deleting all files within it and then deleting the Directory.
    ///
    /// This does allocate within it using the `rt.allocator`.
    pub fn delete_tree(self: Dir, rt: *Runtime, subpath: [:0]const u8) !void {
        const base_dir = try self.open_dir(rt, subpath);

        const base_std_dir = base_dir.to_std();
        var walker = try base_std_dir.walk(rt.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            const new_dir = Dir.from_std(entry.dir);
            switch (entry.kind) {
                .directory => try new_dir.delete_tree(rt, entry.basename),
                else => try new_dir.delete_file(rt, entry.basename),
            }
        }

        try base_dir.close(rt);
        try self.delete_dir(rt, subpath);
    }
};
