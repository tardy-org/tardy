pub const Task = @This();

// 1 byte
state: State = .dead,
// no idea on bytes.
result: results.Result = .none,
// 8 bytes
index: usize,
// 8 bytes
frame: *tardy.Coroutine,

pub const State = union(enum) {
    /// Waiting for a Runtime Trigger.
    wait_for_trigger,
    /// Waiting for an Async I/O Event.
    wait_for_io,
    /// Immediately Runnable.
    runnable,
    /// Dead.
    dead,
};

const std = @import("std");

const tardy = @import("../root.zig");
const results = tardy.results;
