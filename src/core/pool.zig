const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const Error = error{Full} || Allocator.Error;

pub const PoolKind = enum {
    /// This keeps the Pool at a static size, never growing.
    static,
    /// This allows the Pool to grow but never shrink.
    grow,
};

pub fn Pool(comptime T: type) type {
    return struct {
        pub const Kind = PoolKind;

        pub const Iterator = struct {
            items: []T,
            iter: std.DynamicBitSetUnmanaged.Iterator(.{
                .kind = .set,
                .direction = .forward,
            }),

            pub fn next(self: *Iterator) ?T {
                const index = self.iter.next() orelse return null;
                return self.items[index];
            }

            pub fn next_ptr(self: *Iterator) ?*T {
                const index = self.iter.next() orelse return null;
                return &self.items[index];
            }

            pub fn next_index(self: *Iterator) ?usize {
                return self.iter.next();
            }
        };

        const Self = @This();
        allocator: mem.Allocator,
        // Buffer for the Pool.
        items: []T,
        dirty: std.DynamicBitSetUnmanaged,
        kind: PoolKind,

        /// Initalizes our items buffer as undefined.
        pub fn init(allocator: mem.Allocator, size: usize, kind: PoolKind) !Self {
            return .{
                .allocator = allocator,
                .items = try allocator.alloc(T, size),
                .dirty = try .initEmpty(allocator, size),
                .kind = kind,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
            self.dirty.deinit(self.allocator);
        }

        /// Deinitalizes our items buffer with a passed in hook.
        pub fn deinit_with_hook(
            self: *Self,
            args: anytype,
            deinit_hook: ?*const fn (buffer: []T, args: @TypeOf(args)) void,
        ) void {
            if (deinit_hook) |hook| {
                @call(.auto, hook, .{ self.items, args });
            }

            self.allocator.free(self.items);
            self.dirty.deinit(self.allocator);
        }

        pub fn get(self: *const Self, index: usize) T {
            assert(index < self.items.len);
            return self.items[index];
        }

        pub fn get_ptr(self: *const Self, index: usize) *T {
            assert(index < self.items.len);
            return &self.items[index];
        }

        /// Is this empty?
        pub fn empty(self: *const Self) bool {
            return self.dirty.count() == 0;
        }

        /// Is this full?
        pub fn full(self: *const Self) bool {
            return self.dirty.count() == self.items.len;
        }

        /// Returns the number of clean (or available) slots.
        pub fn clean(self: *const Self) usize {
            return self.items.len - self.dirty.count();
        }

        fn grow(self: *Self) Error!void {
            assert(self.kind == .grow);

            const old_slice = self.items;
            const new_size = std.math.ceilPowerOfTwoAssert(usize, self.items.len + 1);

            if (self.allocator.remap(self.items, new_size)) |new_slice| {
                self.items = new_slice;
            } else if (self.allocator.resize(self.items, new_size)) {
                self.items = self.items.ptr[0..new_size];
            } else {
                const new_slice = try self.allocator.alloc(T, new_size);
                errdefer self.allocator.free(new_slice);
                @memcpy(new_slice[0..self.items.len], self.items);
                self.items = new_slice;
                self.allocator.free(old_slice);
            }
            try self.dirty.resize(self.allocator, new_size, false);

            assert(self.items.len == new_size);
            assert(self.dirty.bit_length == new_size);
        }

        /// Linearly probes for an available slot in the pool.
        /// If dynamic, this *might* grow the Pool.
        ///
        /// Returns the index into the Pool.
        pub fn borrow(self: *Self) Error!usize {
            var iter = self.dirty.iterator(.{ .kind = .unset });
            const index = iter.next() orelse switch (self.kind) {
                .static => return error.Full,
                .grow => {
                    const last_index = self.items.len;
                    try self.grow();
                    return self.borrow_assume_unset(last_index);
                },
            };

            self.dirty.set(index);
            return index;
        }

        /// Linearly probes for an available slot in the pool.
        /// Uses a provided hint value as the starting index.
        ///
        /// Returns the index into the Pool.
        pub fn borrow_hint(self: *Self, hint: usize) Error!usize {
            const length = self.items.len;
            for (0..length) |i| {
                const index = @mod(hint + i, length);
                if (!self.dirty.isSet(index)) {
                    self.dirty.set(index);
                    return index;
                }
            }

            switch (self.kind) {
                .static => return error.Full,
                .grow => {
                    const last_index = self.items.len;
                    try self.grow();
                    return self.borrow_assume_unset(last_index);
                },
            }
        }

        /// Attempts to borrow at the given index.
        /// Asserts that it is an available slot.
        /// This will never grow the Pool.
        pub fn borrow_assume_unset(self: *Self, index: usize) usize {
            assert(!self.dirty.isSet(index));
            self.dirty.set(index);
            return index;
        }

        /// Releases the item with the given index back to the Pool.
        /// Asserts that the given index was borrowed.
        pub fn release(self: *Self, index: usize) void {
            assert(self.dirty.isSet(index));
            self.dirty.unset(index);
        }

        /// Returns an iterator over the taken values in the Pool.
        pub fn iterator(self: *const Self) Iterator {
            const iter = self.dirty.iterator(.{});
            return .{ .iter = iter, .items = self.items };
        }
    };
}

test "Pool: Initalization (integer)" {
    var byte_pool: Pool(u8) = try .init(testing.allocator, 1024, .static);
    defer byte_pool.deinit();

    for (0..1024) |i| {
        const index = try byte_pool.borrow_hint(i);
        const byte_ptr = byte_pool.get_ptr(index);
        byte_ptr.* = 2;
    }

    for (byte_pool.items) |item| {
        try testing.expectEqual(item, 2);
    }
}

test "Pool: Dynamic Growth (integer)" {
    var byte_pool: Pool(u8) = try .init(testing.allocator, 1, .grow);
    defer byte_pool.deinit();

    const count = 1024;

    for (0..count) |i| {
        const index = try byte_pool.borrow_hint(i);
        const byte_ptr = byte_pool.get_ptr(index);
        byte_ptr.* = 2;
    }

    try testing.expect(byte_pool.items.len >= count);

    for (byte_pool.items[0..count]) |item| {
        try testing.expectEqual(item, 2);
    }
}

test "Pool: Initalization & Deinit (ArrayList)" {
    var list_pool: Pool(std.ArrayList(u8)) = try .init(testing.allocator, 256, .static);
    defer list_pool.deinit();

    for (list_pool.items, 0..) |*item, i| {
        item.* = .empty;
        try item.appendNTimes(testing.allocator, 0, i);
    }

    for (list_pool.items, 0..) |item, i| {
        try testing.expectEqual(item.items.len, i);
    }

    for (list_pool.items) |*item| {
        item.deinit(testing.allocator);
    }
}

test "Pool: BufferPool ([][]u8)" {
    var buffer_pool: Pool([1024]u8) = try .init(testing.allocator, 1024, .static);
    defer buffer_pool.deinit();

    for (buffer_pool.items) |*item| {
        mem.copyForwards(u8, item, "ABCDEF");
    }

    for (buffer_pool.items) |item| {
        try testing.expectEqualStrings("ABCDEF", item[0..6]);
    }
}

test "Pool: Borrowing" {
    var byte_pool: Pool(u8) = try .init(testing.allocator, 1024, .static);
    defer byte_pool.deinit();

    for (0..byte_pool.items.len) |_| {
        _ = try byte_pool.borrow();
    }

    // Expect a Full.
    try testing.expectError(error.Full, byte_pool.borrow());

    for (0..byte_pool.items.len) |i| {
        byte_pool.release(i);
    }
}

test "Pool: Borrowing Hint" {
    var byte_pool: Pool(u8) = try .init(testing.allocator, 1024, .static);
    defer byte_pool.deinit();

    for (0..byte_pool.items.len) |i| {
        _ = try byte_pool.borrow_hint(i);
    }

    for (0..byte_pool.items.len) |i| {
        byte_pool.release(i);
    }
}

test "Pool: Borrowing Unset" {
    var byte_pool: Pool(u8) = try .init(testing.allocator, 1024, .static);
    defer byte_pool.deinit();

    for (0..byte_pool.items.len) |i| {
        _ = byte_pool.borrow_assume_unset(i);
    }

    for (0..byte_pool.items.len) |i| {
        byte_pool.release(i);
    }
}

test "Pool Iterator" {
    var int_pool: Pool(usize) = try .init(testing.allocator, 1024, .static);
    defer int_pool.deinit();

    for (0..(1024 / 2)) |_| {
        const borrowed = try int_pool.borrow();
        const item_ptr = int_pool.get_ptr(borrowed);
        item_ptr.* = borrowed;
    }

    var iter = int_pool.iterator();
    while (iter.next()) |item| {
        try testing.expect(int_pool.dirty.isSet(item));
        int_pool.release(item);
    }

    try testing.expect(int_pool.empty());
}
