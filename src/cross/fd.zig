const std = @import("std");
const builtin = @import("builtin");
const os = builtin.os.tag;
const syscall = @import("../syscall.zig");

/// Invalid `fd_t`.
pub const INVALID_FD = if (os == .windows) std.os.windows.INVALID_HANDLE_VALUE else -1;

/// Ensures that the `std.posix.fd_t` is valid.
pub fn is_valid(fd: std.posix.fd_t) bool {
    switch (comptime os) {
        .windows => return fd != std.os.windows.INVALID_HANDLE_VALUE,
        else => return fd >= 0,
    }
}

pub fn to_nonblock(fd: std.posix.fd_t) !void {
    if (comptime os == .windows) {
        // windows doesn't have non-blocking I/O w/o overlapped.
    } else {
        const current_flags = try syscall.fcntl(fd, std.posix.F.GETFL, 0);
        var new_flags = @as(
            std.posix.O,
            @bitCast(@as(u32, @intCast(current_flags))),
        );
        new_flags.NONBLOCK = true;
        const arg: u32 = @bitCast(new_flags);
        _ = try syscall.fcntl(fd, std.posix.F.SETFL, arg);
    }
}
