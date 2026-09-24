pub const Task = @This();

// 8 bytes
index: usize,
// 8 bytes
frame: *tardy.Coroutine,
// 144 bytes.
result: results.Result = .none,
// 1 byte
state: State = .dead,

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

const tardy = @import("../root.zig");
const results = tardy.results;
