pub fn Ring(comptime T: type) type {
    return struct {
        const Ring_t = @This();

        items: []T,
        // This is where we will read off of.
        read_index: usize = 0,
        // This is where we will write into.
        write_index: usize = 0,
        // Total count of elements.
        count: usize = 0,

        pub fn init(gpa: mem.Allocator, size: usize) !Ring_t {
            debug.assert(size >= 1);
            const items = try gpa.alloc(T, size);
            return .{
                .items = items,
            };
        }

        pub fn deinit(ring: Ring_t, gpa: mem.Allocator) void {
            gpa.free(ring.items);
        }

        pub fn full(ring: Ring_t) bool {
            return ring.count == ring.items.len;
        }

        pub fn empty(ring: Ring_t) bool {
            return ring.count == 0;
        }

        pub fn push(ring: *Ring_t, message: T) !void {
            if (ring.full()) return error.RingFull;
            ring.items[ring.write_index] = message;
            ring.write_index = (ring.write_index + 1) % ring.items.len;
            ring.count += 1;
        }

        pub fn push_assert(ring: *Ring_t, message: T) void {
            debug.assert(!ring.full());
            ring.items[ring.write_index] = message;
            ring.write_index = (ring.write_index + 1) % ring.items.len;
            ring.count += 1;
        }

        pub fn pop(ring: *Ring_t) !T {
            if (ring.empty()) return error.RingEmpty;
            const message = ring.items[ring.read_index];
            ring.read_index = (ring.read_index + 1) % ring.items.len;
            ring.count -= 1;
            return message;
        }

        pub fn pop_assert(ring: *Ring_t) T {
            debug.assert(!ring.empty());
            const message = ring.items[ring.read_index];
            ring.read_index = (ring.read_index + 1) % ring.items.len;
            ring.count -= 1;
            return message;
        }

        pub fn pop_ptr(ring: *Ring_t) !*T {
            if (ring.empty()) return error.RingEmpty;
            const message = &ring.items[ring.read_index];
            ring.read_index = (ring.read_index + 1) % ring.items.len;
            ring.count -= 1;
            return message;
        }
    };
}

test "Ring Send and Recv" {
    const gpa = testing.allocator;

    const size: u32 = 100;
    var ring: Ring(usize) = try .init(gpa, size);
    defer ring.deinit(gpa);

    for (0..size) |i| {
        for (0..i) |j| {
            try ring.push(j);
        }

        for (0..i) |j| {
            try testing.expectEqual(j, try ring.pop());
        }
    }
}

const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;
