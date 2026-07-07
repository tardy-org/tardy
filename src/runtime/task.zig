const std = @import("std");

const Result = @import("../aio/completion.zig").Result;
const Frame = @import("../frame/lib.zig").Frame;

pub const Task = struct {
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
    // 1 byte
    state: State = .dead,
    // no idea on bytes.
    result: Result = .none,
    // 8 bytes
    index: usize,
    // 8 bytes
    frame: *Frame,
};
