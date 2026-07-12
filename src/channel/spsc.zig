pub fn Spsc(comptime T: type) type {
    return struct {
        const Self = @This();

        fn trigger_consumer(self: *Self) !void {
            try self.consumer_rt.load(.acquire).?.trigger(
                self.consumer_index.load(.acquire),
            );
        }

        fn trigger_producer(self: *Self) !void {
            try self.producer_rt.load(.acquire).?.trigger(
                self.producer_index.load(.acquire),
            );
        }

        pub const Producer = struct {
            inner: *Self,
            rt: *Runtime,

            pub fn send(self: Producer, message: T) !void {
                log.debug("producer sending...", .{});
                while (true) switch (self.inner.state.load(.acquire)) {
                    // Both ends must be open.
                    .starting => try self.rt.scheduler.trigger_await(),
                    // Channel was cleaned up.
                    .closed => return error.Closed,
                    .running => {
                        if (!self.inner.consumer_open.load(.acquire)) return error.Closed;
                        self.inner.ring.push(message) catch |e| switch (e) {
                            error.RingFull => {
                                self.inner.producer_index.store(
                                    self.rt.current_task.?,
                                    .release,
                                );
                                try self.inner.trigger_consumer();
                                try self.rt.scheduler.trigger_await();
                                continue;
                            },
                        };

                        return;
                    },
                };
            }

            pub fn close(self: Producer) void {
                self.inner.producer_open.store(false, .release);
                self.inner.trigger_consumer() catch unreachable;
            }
        };

        pub const Consumer = struct {
            inner: *Self,
            rt: *Runtime,

            pub fn recv(self: Consumer) !T {
                log.debug("consumer recving...", .{});
                while (true) switch (self.inner.state.load(.acquire)) {
                    // Both ends must be open.
                    .starting => try self.rt.scheduler.trigger_await(),
                    // Channel was cleaned up.
                    .closed => return error.Closed,
                    .running => {
                        const data = self.inner.ring.pop() catch |e| switch (e) {
                            // If we are empty, trigger the producer to run.
                            error.RingEmpty => {
                                if (!self.inner.producer_open.load(.acquire)) return error.Closed;
                                self.inner.consumer_index.store(
                                    self.rt.current_task.?,
                                    .release,
                                );
                                try self.inner.trigger_producer();
                                try self.rt.scheduler.trigger_await();
                                continue;
                            },
                        };

                        return data;
                    },
                };
            }

            pub fn close(self: Consumer) void {
                self.inner.consumer_open.store(false, .release);
                self.inner.trigger_producer() catch unreachable;
            }
        };

        ring: atomic.SpscRing(T),

        producer_rt: std_atomic.Value(?*Runtime) align(std_atomic.cache_line),
        producer_index: std_atomic.Value(usize) align(std_atomic.cache_line),
        producer_open: std_atomic.Value(bool) align(std_atomic.cache_line),

        consumer_rt: std_atomic.Value(?*Runtime) align(std_atomic.cache_line),
        consumer_index: std_atomic.Value(usize) align(std_atomic.cache_line),
        consumer_open: std_atomic.Value(bool) align(std_atomic.cache_line),

        state: std.atomic.Value(State) align(std_atomic.cache_line),

        pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
            return .{
                .ring = try .init(allocator, size),

                .producer_rt = .{ .raw = null },
                .producer_index = .{ .raw = 0 },
                .producer_open = .{ .raw = false },

                .consumer_rt = .{ .raw = null },
                .consumer_index = .{ .raw = 0 },
                .consumer_open = .{ .raw = false },
                .state = .{ .raw = .starting },
            };
        }

        pub fn deinit(self: *Self) void {
            self.producer_open.store(false, .release);
            self.consumer_open.store(false, .release);

            if (self.state.cmpxchgStrong(.running, .closed, .acq_rel, .acquire)) |_| {
                return; // Someone else is handling deinit
            }

            self.ring.deinit();
        }

        pub fn producer(self: *Self, runtime: *Runtime) Producer {
            if (self.producer_rt.cmpxchgStrong(
                null,
                runtime,
                .acq_rel,
                .acquire,
            )) |_| @panic("Only one producer can exist for a Spsc");

            self.producer_open.store(true, .release);
            if (self.consumer_rt.load(.acquire) != null) self.state.store(
                .running,
                .release,
            );
            return .{ .inner = self, .rt = runtime };
        }

        pub fn consumer(self: *Self, runtime: *Runtime) Consumer {
            if (self.consumer_rt.cmpxchgStrong(
                null,
                runtime,
                .acq_rel,
                .acquire,
            )) |_| @panic("Only one consumer can exist for a Spsc");

            self.consumer_open.store(true, .release);
            if (self.producer_rt.load(.acquire) != null) self.state.store(
                .running,
                .release,
            );
            return .{ .inner = self, .rt = runtime };
        }
    };
}

const log = std.log.scoped(.@"tardy/channel/spsc");

const State = enum(u8) {
    starting,
    running,
    closed,
};

const std = @import("std");
const std_atomic = std.atomic;

const tardy = @import("../root.zig");
const atomic = tardy.core.atomic;
const Runtime = tardy.Runtime;
