const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub fn Ring(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        items: []T,
        // This is where we will read off of.
        read_index: usize = 0,
        // This is where we will write into.
        write_index: usize = 0,
        // Total count of elements.
        count: usize = 0,

        pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
            assert(size >= 1);
            const items = try allocator.alloc(T, size);
            return .{
                .allocator = allocator,
                .items = items,
            };
        }

        pub fn deinit(self: Self) void {
            self.allocator.free(self.items);
        }

        pub fn full(self: Self) bool {
            return self.count == self.items.len;
        }

        pub fn empty(self: Self) bool {
            return self.count == 0;
        }

        pub fn push(self: *Self, message: T) !void {
            if (self.full()) return error.RingFull;
            self.items[self.write_index] = message;
            self.write_index = (self.write_index + 1) % self.items.len;
            self.count += 1;
        }

        pub fn push_assert(self: *Self, message: T) void {
            assert(!self.full());
            self.items[self.write_index] = message;
            self.write_index = (self.write_index + 1) % self.items.len;
            self.count += 1;
        }

        pub fn pop(self: *Self) !T {
            if (self.empty()) return error.RingEmpty;
            const message = self.items[self.read_index];
            self.read_index = (self.read_index + 1) % self.items.len;
            self.count -= 1;
            return message;
        }

        pub fn pop_assert(self: *Self) T {
            assert(!self.empty());
            const message = self.items[self.read_index];
            self.read_index = (self.read_index + 1) % self.items.len;
            self.count -= 1;
            return message;
        }

        pub fn pop_ptr(self: *Self) !*T {
            if (self.empty()) return error.RingEmpty;
            const message = &self.items[self.read_index];
            self.read_index = (self.read_index + 1) % self.items.len;
            self.count -= 1;
            return message;
        }
    };
}

test "Ring Send and Recv" {
    const size: u32 = 100;
    var ring: Ring(usize) = try .init(testing.allocator, size);
    defer ring.deinit();

    for (0..size) |i| {
        for (0..i) |j| {
            try ring.push(j);
        }

        for (0..i) |j| {
            try testing.expectEqual(j, try ring.pop());
        }
    }
}
