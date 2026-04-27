const std = @import("std");

pub const Dir = @import("dir.zig").Dir;
pub const File = @import("file.zig").File;

pub const Path = union(enum) {
    /// Relative to given Directory
    rel: struct {
        dir: std.posix.fd_t,
        path: [:0]const u8,
    },
    /// Absolute Path
    abs: [:0]const u8,

    pub fn dupe(self: *const Path, allocator: std.mem.Allocator) !Path {
        switch (self.*) {
            .rel => |inner| {
                const path_dupe = try allocator.dupeZ(u8, inner.path);
                errdefer allocator.free(path_dupe);
                return .{ .rel = .{ .dir = inner.dir, .path = path_dupe } };
            },
            .abs => |path| return .{ .abs = try allocator.dupeZ(u8, path) },
        }
    }
};
const Io = std.Io;
pub const Stat = struct {
    size: u64,
    mode: u32 = 0,
    accessed: ?Io.Timestamp = null,
    modified: ?Io.Timestamp = null,
    changed: ?Io.Timestamp = null,
};
