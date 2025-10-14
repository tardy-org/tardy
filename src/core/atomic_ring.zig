const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Value;
const testing = std.testing;

pub fn SpscAtomicRing(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        items: []T,

        write_index: Atomic(usize) align(std.atomic.cache_line),
        read_index: Atomic(usize) align(std.atomic.cache_line),

        pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
            assert(size >= 2);
            assert(std.math.isPowerOfTwo(size));

            const items = try allocator.alloc(T, size);
            errdefer allocator.free(items);

            return .{
                .allocator = allocator,
                .items = items,
                .write_index = .{ .raw = 0 },
                .read_index = .{ .raw = 0 },
            };
        }

        pub fn deinit(self: Self) void {
            self.allocator.free(self.items);
        }

        pub fn push(self: *Self, item: T) !void {
            const write = self.write_index.load(.acquire);
            if (write - self.read_index.load(.acquire) > self.items.len - 1) return error.RingFull;
            const next: usize = write + 1;
            self.items[write % self.items.len] = item;
            self.write_index.store(next, .release);
            if (next - self.read_index.load(.acquire) > self.items.len - 1) return error.RingFull;
        }

        pub fn pop(self: *Self) !T {
            const read = self.read_index.load(.acquire);
            if (read == self.write_index.load(.acquire)) return error.RingEmpty;
            const item = self.items[read % self.items.len];
            self.read_index.store(read + 1, .release);
            return item;
        }

        pub fn empty(self: *const Self) bool {
            return (self.read_index.load(.acquire) == self.write_index.load(.acquire));
        }

        pub fn len(self: *const Self) usize {
            return (self.write_index.load(.acquire) - self.read_index.load(.acquire));
        }
    };
}

test "SpscAtomicRing: Fill and Empty" {
    const size: u32 = 128;
    var ring = try SpscAtomicRing(usize).init(testing.allocator, size);
    defer ring.deinit();

    try testing.expectError(error.RingEmpty, ring.pop());
    for (0..size - 1) |i| try ring.push(i);
    try testing.expectError(error.RingFull, ring.push(127));
    try testing.expectError(error.RingFull, ring.push(127));
    try testing.expectEqual(128, ring.len());
    try testing.expectEqual(0, try ring.pop());
    try testing.expectEqual(127, ring.len());
    try testing.expectError(error.RingFull, ring.push(128));
    for (1..size + 1) |i| try testing.expectEqual(i, try ring.pop());
    try testing.expectError(error.RingEmpty, ring.pop());
}
