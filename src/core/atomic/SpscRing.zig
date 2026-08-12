/// An Atomic Spsc Ring
pub fn SpscRing(comptime T: type) type {
    return struct {
        const SpscRing_t = @This();

        items: []T,

        write_index: atomic.Value(usize) align(atomic.cache_line),
        read_index: atomic.Value(usize) align(atomic.cache_line),

        pub fn init(gpa: mem.Allocator, size: usize) !SpscRing_t {
            debug.assert(size >= 2);
            debug.assert(math.isPowerOfTwo(size));

            const items = try gpa.alloc(T, size);
            errdefer gpa.free(items);

            return .{
                .items = items,
                .write_index = .{ .raw = 0 },
                .read_index = .{ .raw = 0 },
            };
        }

        pub fn deinit(spsc_ring: SpscRing_t, gpa: mem.Allocator) void {
            gpa.free(spsc_ring.items);
        }

        pub fn push(spsc_ring: *SpscRing_t, item: T) !void {
            const write = spsc_ring.write_index.load(.acquire);
            const next: usize = (write + 1) % spsc_ring.items.len;
            if (next == spsc_ring.read_index.load(.acquire)) return error.RingFull;
            spsc_ring.items[write] = item;
            spsc_ring.write_index.store(
                (write + 1) % spsc_ring.items.len,
                .release,
            );
        }

        pub fn pop(spsc_ring: *SpscRing_t) !T {
            const read = spsc_ring.read_index.load(.acquire);
            if (read == spsc_ring.write_index.load(.acquire)) return error.RingEmpty;
            const item = spsc_ring.items[read];
            spsc_ring.read_index.store((read + 1) % spsc_ring.items.len, .release);
            return item;
        }
    };
}

test "SpscRing: Fill and Empty" {
    const gpa = testing.allocator;

    const size: u32 = 128;
    var ring: SpscRing(usize) = try .init(gpa, size);
    defer ring.deinit(gpa);

    try testing.expectError(
        error.RingEmpty,
        ring.pop(),
    );
    for (0..size - 1) |i| try ring.push(i);
    try testing.expectError(
        error.RingFull,
        ring.push(1),
    );
    for (0..size - 1) |i| try testing.expectEqual(
        i,
        try ring.pop(),
    );
    try testing.expectError(
        error.RingEmpty,
        ring.pop(),
    );
}

const std = @import("std");
const debug = std.debug;
const math = std.math;
const atomic = std.atomic;
const testing = std.testing;
const mem = std.mem;
