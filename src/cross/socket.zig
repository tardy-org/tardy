/// Ensures that the `std.posix.socket_t` is valid.
pub fn is_valid(socket: std.posix.socket_t) bool {
    switch (comptime os) {
        .windows => return socket != INVALID_SOCKET,
        else => return socket >= 0,
    }
}

/// Sets the `std.posix.socket_t` to nonblocking.
pub fn to_nonblock(socket: std.posix.socket_t) !void {
    if (comptime os == .windows) {
        var mode: u32 = 1;
        _ = syscall.ws2.ioctlsocket(
            socket,
            syscall.ws2.FIONBIO,
            &mode,
        );
    } else {
        const current_flags = try syscall.fcntl(
            socket,
            std.posix.F.GETFL,
            0,
        );
        var new_flags = @as(
            std.posix.O,
            @bitCast(@as(u32, @intCast(current_flags))),
        );
        new_flags.NONBLOCK = true;
        const arg: u32 = @bitCast(new_flags);
        _ = try syscall.fcntl(socket, std.posix.F.SETFL, arg);
    }
}

const std = @import("std");
const builtin = @import("builtin");
const os = builtin.os.tag;

const tardy = @import("../root.zig");
const syscall = tardy.AsyncIO.syscall;
pub const INVALID_SOCKET = @import("fd.zig").INVALID_FD;
