/// Ensures that the `std.posix.socket_t` is valid.
pub fn is_valid(socket: std.posix.socket_t) bool {
    switch (comptime builtin.os.tag) {
        .windows => return socket != INVALID_SOCKET,
        else => return socket >= 0,
    }
}

const std = @import("std");
const builtin = @import("builtin");

pub const INVALID_SOCKET = @import("fd.zig").INVALID_FD;
