/// Cross-platform abstractions.
/// For the `std.posix` interface types.
const std = @import("std");
const File = std.Io.File;

pub const fd = @import("cross/fd.zig");
pub const socket = @import("cross/socket.zig");

/// Get the `fd_t` for `stdin`.
pub fn get_std_in() std.posix.fd_t {
    return File.stdin().handle;
}

/// Get the `fd_t` for `stdout`.
pub fn get_std_out() std.posix.fd_t {
    return File.stdout().handle;
}

/// Get the `fd_t` for `stderr`.
pub fn get_std_err() std.posix.fd_t {
    return File.stderr().handle;
}
