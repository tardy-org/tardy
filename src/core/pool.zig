pub fn Pool(comptime T: type) type {
    return struct {
        const Pool_t = @This();
        // Buffer for the Pool.
        items: []T,
        dirty: bit_set.Dynamic,
        kind: Kind,

        /// Initalizes our items buffer as undefined.
        pub fn init(gpa: mem.Allocator, size: usize, kind: Kind) !Pool_t {
            return .{
                .items = try gpa.alloc(T, size),
                .dirty = try .initEmpty(gpa, size),
                .kind = kind,
            };
        }

        pub fn deinit(pool: *Pool_t, gpa: mem.Allocator) void {
            gpa.free(pool.items);
            pool.dirty.deinit(gpa);
        }

        /// Deinitalizes our items buffer with a passed in hook.
        pub fn deinit_with_hook(
            pool: *Pool_t,
            gpa: mem.Allocator,
            args: anytype,
            deinit_hook: ?*const fn (buffer: []T, args: @TypeOf(args)) void,
        ) void {
            if (deinit_hook) |hook|
                @call(.auto, hook, .{ pool.items, args });

            gpa.free(pool.items);
            pool.dirty.deinit(gpa);
        }

        pub fn get(pool: *const Pool_t, index: usize) T {
            debug.assert(index < pool.items.len);
            return pool.items[index];
        }

        pub fn get_ptr(pool: *const Pool_t, index: usize) *T {
            debug.assert(index < pool.items.len);
            return &pool.items[index];
        }

        /// Is this empty?
        pub fn empty(pool: *const Pool_t) bool {
            return pool.dirty.count() == 0;
        }

        /// Is this full?
        pub fn full(pool: *const Pool_t) bool {
            return pool.dirty.count() == pool.items.len;
        }

        /// Returns the number of clean (or available) slots.
        pub fn clean(pool: *const Pool_t) usize {
            return pool.items.len - pool.dirty.count();
        }

        fn grow(pool: *Pool_t, gpa: mem.Allocator) Error!void {
            debug.assert(pool.kind == .grow);

            const old_slice = pool.items;
            const new_size = math.ceilPowerOfTwoAssert(
                usize,
                pool.items.len + 1,
            );

            if (gpa.remap(pool.items, new_size)) |new_slice|
                pool.items = new_slice
            else if (gpa.resize(pool.items, new_size))
                pool.items = pool.items.ptr[0..new_size]
            else {
                const new_slice = try gpa.alloc(T, new_size);
                errdefer gpa.free(new_slice);

                @memcpy(new_slice[0..pool.items.len], pool.items);

                pool.items = new_slice;
                gpa.free(old_slice);
            }

            try pool.dirty.resize(
                gpa,
                new_size,
                false,
            );

            debug.assert(pool.items.len == new_size);
            debug.assert(pool.dirty.bit_length == new_size);
        }

        /// Linearly probes for an available slot in the pool.
        /// If dynamic, this *might* grow the Pool.
        ///
        /// Returns the index into the Pool.
        pub fn borrow(pool: *Pool_t, gpa: mem.Allocator) Error!usize {
            var iter = pool.dirty.iterator(.{
                .kind = .unset,
            });
            const index = iter.next() orelse switch (pool.kind) {
                .static => return error.Full,
                .grow => {
                    const last_index = pool.items.len;
                    try pool.grow(gpa);
                    return pool.borrow_assume_unset(last_index);
                },
            };

            pool.dirty.set(index);
            return index;
        }

        /// Linearly probes for an available slot in the pool.
        /// Uses a provided hint value as the starting index.
        ///
        /// Returns the index into the Pool.
        pub fn borrow_hint(pool: *Pool_t, gpa: mem.Allocator, hint: usize) Error!usize {
            const length = pool.items.len;
            for (0..length) |i| {
                const index = @mod(hint + i, length);
                if (!pool.dirty.isSet(index)) {
                    pool.dirty.set(index);
                    return index;
                }
            }

            switch (pool.kind) {
                .static => return error.Full,
                .grow => {
                    const last_index = pool.items.len;
                    try pool.grow(gpa);
                    return pool.borrow_assume_unset(last_index);
                },
            }
        }

        /// Attempts to borrow at the given index.
        /// Asserts that it is an available slot.
        /// This will never grow the Pool.
        pub fn borrow_assume_unset(pool: *Pool_t, index: usize) usize {
            debug.assert(!pool.dirty.isSet(index));
            pool.dirty.set(index);
            return index;
        }

        /// Releases the item with the given index back to the Pool.
        /// Asserts that the given index was borrowed.
        pub fn release(pool: *Pool_t, index: usize) void {
            debug.assert(pool.dirty.isSet(index));
            pool.dirty.unset(index);
        }

        /// Returns an iterator over the taken values in the Pool.
        pub fn iterator(pool: *const Pool_t) Iterator {
            const iter = pool.dirty.iterator(.{});
            return .{ .iter = iter, .items = pool.items };
        }

        pub const Iterator = struct {
            items: []T,
            iter: bit_set.Dynamic.Iterator(.{
                .kind = .set,
                .direction = .forward,
            }),

            pub fn next(iter: *Iterator) ?T {
                const index = iter.iter.next() orelse return null;
                return iter.items[index];
            }

            pub fn next_ptr(iter: *Iterator) ?*T {
                const index = iter.iter.next() orelse return null;
                return &iter.items[index];
            }

            pub fn next_index(iter: *Iterator) ?usize {
                return iter.iter.next();
            }
        };
    };
}

test "Pool: Initalization (integer)" {
    const gpa = testing.allocator;

    var byte_pool: Pool(u8) = try .init(gpa, 1024, .static);
    defer byte_pool.deinit(gpa);

    for (0..1024) |i| {
        const index = try byte_pool.borrow_hint(gpa, i);
        const byte_ptr = byte_pool.get_ptr(index);
        byte_ptr.* = 2;
    }

    for (byte_pool.items) |item| {
        try testing.expectEqual(item, 2);
    }
}

test "Pool: Dynamic Growth (integer)" {
    const gpa = testing.allocator;

    var byte_pool: Pool(u8) = try .init(gpa, 1, .grow);
    defer byte_pool.deinit(gpa);

    const count = 1024;

    for (0..count) |i| {
        const index = try byte_pool.borrow_hint(gpa, i);
        const byte_ptr = byte_pool.get_ptr(index);
        byte_ptr.* = 2;
    }

    try testing.expect(byte_pool.items.len >= count);

    for (byte_pool.items[0..count]) |item|
        try testing.expectEqual(item, 2);
}

test "Pool: Initalization & Deinit (ArrayList)" {
    const gpa = testing.allocator;

    var list_pool: Pool(std.ArrayList(u8)) = try .init(
        gpa,
        256,
        .static,
    );
    defer list_pool.deinit(gpa);

    for (list_pool.items, 0..) |*item, i| {
        item.* = .empty;
        try item.appendNTimes(gpa, 0, i);
    }

    for (list_pool.items, 0..) |item, i|
        try testing.expectEqual(item.items.len, i);

    for (list_pool.items) |*item|
        item.deinit(gpa);
}

test "Pool: BufferPool ([][]u8)" {
    const gpa = testing.allocator;

    var buffer_pool: Pool([1024]u8) = try .init(gpa, 1024, .static);
    defer buffer_pool.deinit(gpa);

    for (buffer_pool.items) |*item|
        @memcpy(item[0..6], "ABCDEF");

    for (buffer_pool.items) |item|
        try testing.expectEqualStrings("ABCDEF", item[0..6]);
}

test "Pool: Borrowing" {
    const gpa = testing.allocator;

    var byte_pool: Pool(u8) = try .init(gpa, 1024, .static);
    defer byte_pool.deinit(gpa);

    for (0..byte_pool.items.len) |_|
        _ = try byte_pool.borrow(gpa);

    // Expect a Full.
    try testing.expectError(
        error.Full,
        byte_pool.borrow(gpa),
    );

    for (0..byte_pool.items.len) |i|
        byte_pool.release(i);
}

test "Pool: Borrowing Hint" {
    const gpa = testing.allocator;

    var byte_pool: Pool(u8) = try .init(gpa, 1024, .static);
    defer byte_pool.deinit(gpa);

    for (0..byte_pool.items.len) |i|
        _ = try byte_pool.borrow_hint(gpa, i);

    for (0..byte_pool.items.len) |i|
        byte_pool.release(i);
}

test "Pool: Borrowing Unset" {
    const gpa = testing.allocator;

    var byte_pool: Pool(u8) = try .init(gpa, 1024, .static);
    defer byte_pool.deinit(gpa);

    for (0..byte_pool.items.len) |i|
        _ = byte_pool.borrow_assume_unset(i);

    for (0..byte_pool.items.len) |i|
        byte_pool.release(i);
}

test "Pool Iterator" {
    const gpa = testing.allocator;

    var int_pool: Pool(usize) = try .init(gpa, 1024, .static);
    defer int_pool.deinit(gpa);

    for (0..(1024 / 2)) |_| {
        const borrowed = try int_pool.borrow(gpa);
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

pub const Error = error{Full} || OoM;

pub const Kind = enum {
    /// This keeps the Pool at a static size, never growing.
    static,
    /// This allows the Pool to grow but never shrink.
    grow,
};

const std = @import("std");
const math = std.math;
const bit_set = std.bit_set;
const debug = std.debug;
const testing = std.testing;
const mem = std.mem;
const OoM = mem.Allocator.Error;
