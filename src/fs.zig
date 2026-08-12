pub const Path = union(enum) {
    /// Relative to given Directory
    rel: struct {
        dir: posix.fd_t,
        path: [:0]const u8,
    },
    /// Absolute Path
    abs: [:0]const u8,

    pub fn dupe(path: *const Path, gpa: mem.Allocator) !Path {
        switch (path.*) {
            .rel => |rel| {
                const path_dupe = try gpa.dupeSentinel(
                    u8,
                    rel.path,
                    0x0,
                );
                errdefer gpa.free(path_dupe);
                return .{
                    .rel = .{
                        .dir = rel.dir,
                        .path = path_dupe,
                    },
                };
            },
            .abs => |abs| return .{
                .abs = try gpa.dupeSentinel(
                    u8,
                    abs,
                    0x0,
                ),
            },
        }
    }
};

pub const Stat = struct {
    size: u64,
    mode: u32 = 0,
    accessed: ?Io.Timestamp = null,
    modified: ?Io.Timestamp = null,
    changed: ?Io.Timestamp = null,
};

const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const Io = std.Io;

pub const Dir = @import("fs/dir.zig");
pub const File = @import("fs/file.zig");
