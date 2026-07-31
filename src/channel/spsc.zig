pub fn Spsc(comptime T: type) type {
    return struct {
        const Spsc_t = @This();

        fn trigger_consumer(spsc: *Spsc_t) !void {
            try spsc.consumer_rt.load(.acquire).?.trigger(
                spsc.consumer_index.load(.acquire),
            );
        }

        fn trigger_producer(spsc: *Spsc_t) !void {
            try spsc.producer_rt.load(.acquire).?.trigger(
                spsc.producer_index.load(.acquire),
            );
        }

        pub const Producer = struct {
            inner: *Spsc_t,
            rt: *Runtime,

            pub fn send(spsc: Producer, message: T) !void {
                log.debug("producer sending...", .{});
                while (true) switch (spsc.inner.state.load(.acquire)) {
                    // Both ends must be open.
                    .starting => spsc.rt.scheduler.trigger_await(),
                    // Channel was cleaned up.
                    .closed => return error.Closed,
                    .running => {
                        if (!spsc.inner.consumer_open.load(.acquire)) return error.Closed;
                        spsc.inner.ring.push(message) catch |e| switch (e) {
                            error.RingFull => {
                                spsc.inner.producer_index.store(
                                    spsc.rt.current_task.?,
                                    .release,
                                );
                                try spsc.inner.trigger_consumer();
                                spsc.rt.scheduler.trigger_await();
                                continue;
                            },
                        };

                        return;
                    },
                };
            }

            pub fn close(spsc: Producer) void {
                spsc.inner.producer_open.store(false, .release);
                spsc.inner.trigger_consumer() catch unreachable;
            }
        };

        pub const Consumer = struct {
            inner: *Spsc_t,
            rt: *Runtime,

            pub fn recv(spsc: Consumer) !T {
                log.debug("consumer recving...", .{});
                while (true) switch (spsc.inner.state.load(.acquire)) {
                    // Both ends must be open.
                    .starting => spsc.rt.scheduler.trigger_await(),
                    // Channel was cleaned up.
                    .closed => return error.Closed,
                    .running => {
                        const data = spsc.inner.ring.pop() catch |e| switch (e) {
                            // If we are empty, trigger the producer to run.
                            error.RingEmpty => {
                                if (!spsc.inner.producer_open.load(.acquire)) return error.Closed;
                                spsc.inner.consumer_index.store(
                                    spsc.rt.current_task.?,
                                    .release,
                                );
                                try spsc.inner.trigger_producer();
                                spsc.rt.scheduler.trigger_await();
                                continue;
                            },
                        };

                        return data;
                    },
                };
            }

            pub fn close(spsc: Consumer) void {
                spsc.inner.consumer_open.store(false, .release);
                spsc.inner.trigger_producer() catch unreachable;
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

        pub fn init(allocator: std.mem.Allocator, size: usize) !Spsc_t {
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

        pub fn deinit(spsc: *Spsc_t, allocator: mem.Allocator) void {
            spsc.producer_open.store(false, .release);
            spsc.consumer_open.store(false, .release);

            if (spsc.state.cmpxchgStrong(.running, .closed, .acq_rel, .acquire)) |_| {
                return; // Someone else is handling deinit
            }

            spsc.ring.deinit(allocator);
        }

        pub fn producer(spsc: *Spsc_t, runtime: *Runtime) Producer {
            if (spsc.producer_rt.cmpxchgStrong(
                null,
                runtime,
                .acq_rel,
                .acquire,
            )) |_| @panic("Only one producer can exist for a Spsc");

            spsc.producer_open.store(true, .release);
            if (spsc.consumer_rt.load(.acquire) != null) spsc.state.store(
                .running,
                .release,
            );
            return .{ .inner = spsc, .rt = runtime };
        }

        pub fn consumer(spsc: *Spsc_t, runtime: *Runtime) Consumer {
            if (spsc.consumer_rt.cmpxchgStrong(
                null,
                runtime,
                .acq_rel,
                .acquire,
            )) |_| @panic("Only one consumer can exist for a Spsc");

            spsc.consumer_open.store(true, .release);
            if (spsc.producer_rt.load(.acquire) != null) spsc.state.store(
                .running,
                .release,
            );
            return .{ .inner = spsc, .rt = runtime };
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
const mem = std.mem;
const std_atomic = std.atomic;

const tardy = @import("../root.zig");
const atomic = tardy.core.atomic;
const Runtime = tardy.Runtime;
