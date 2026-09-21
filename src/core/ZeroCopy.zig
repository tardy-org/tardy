pub fn ZeroCopy(comptime T: type) type {
    return struct {
        const ZeroCopy_t = @This();
        list: std.ArrayList(T),

        pub fn init(gpa: mem.Allocator, capacity: usize) !ZeroCopy_t {
            var new: std.ArrayList(T) = try .initCapacity(gpa, capacity);
            new.items.len = 0;

            return .{
                .list = new,
            };
        }

        pub fn deinit(zc: *ZeroCopy_t, gpa: mem.Allocator) void {
            zc.list.deinit(gpa);
        }

        pub fn slice(zc: *const ZeroCopy_t) []T {
            return zc.list.items[0..];
        }

        pub fn len(zc: *const ZeroCopy_t) usize {
            return zc.list.items.len;
        }

        pub fn subslice(zc: *const ZeroCopy_t, options: SubsliceOptions) []T {
            const start: usize = options.start orelse 0;
            const end: usize = options.end orelse zc.list.items.len;
            debug.assert(start <= end);
            debug.assert(end <= zc.list.items.len);

            return zc.list.items[start..end];
        }

        /// This returns a slice that you can write into for zero-copy uses.
        /// This is mostly used when we are passing a buffer to I/O then acting on it.
        ///
        /// The write area that is returned is ONLY valid until the next call of
        /// `get_write_area` or mark_written.
        pub fn get_write_area(zc: *ZeroCopy_t, gpa: mem.Allocator, size: usize) ![]T {
            const available_space = zc.list.capacity - zc.list.items.len;
            if (available_space >= size) {
                return zc.get_write_area_assume_space(size);
            }

            try zc.list.ensureUnusedCapacity(gpa, size);

            return zc.get_write_area_assume_space(size);
        }

        pub fn get_write_area_assume_space(zc: *const ZeroCopy_t, size: usize) []T {
            debug.assert(zc.list.capacity - zc.list.items.len >= size);
            return zc.list.items.ptr[zc.list.items.len..][0..size];
        }

        pub fn mark_written(zc: *ZeroCopy_t, length: usize) void {
            debug.assert(zc.list.items.len + length <= zc.list.capacity);
            zc.list.items.len += length;
        }

        pub fn shrink_retaining_capacity(zc: *ZeroCopy_t, new_size: usize) void {
            zc.list.shrinkRetainingCapacity(new_size);
        }

        pub fn shrink_clear_and_free(
            zc: *ZeroCopy_t,
            gpa: mem.Allocator,
            new_size: usize,
        ) void {
            zc.list.shrinkAndFree(gpa, new_size);
            zc.clear_retaining_capacity();
        }

        pub fn clear_retaining_capacity(zc: *ZeroCopy_t) void {
            zc.list.items.len = 0;
        }

        pub fn clear_and_free(zc: *ZeroCopy_t, gpa: mem.Allocator) void {
            zc.deinit(gpa);
            zc.clear_retaining_capacity();
            zc.list.capacity = 0;
        }
    };
}

const SubsliceOptions = struct {
    start: ?usize = null,
    end: ?usize = null,
};

test "ZeroCopy: First" {
    const gpa = testing.allocator;

    const garbage: [128]u8 = @splat(212);

    var zc: ZeroCopy(u8) = try .init(gpa, 512);
    defer zc.deinit(gpa);

    const write_area = try zc.get_write_area(gpa, garbage.len);
    @memcpy(write_area, garbage[0..]);
    zc.mark_written(write_area.len);

    try testing.expectEqualSlices(
        u8,
        garbage[0..],
        zc.subslice(.{ .end = write_area.len }),
    );
}

test "ZeroCopy: Growth" {
    const gpa = testing.allocator;

    var zc: ZeroCopy(u8) = try .init(gpa, 16);
    defer zc.deinit(gpa);

    const large_data: [32]u8 = @splat(1);
    const write_area = try zc.get_write_area(gpa, large_data.len);
    @memcpy(write_area, &large_data);
    zc.mark_written(write_area.len);

    try testing.expect(zc.list.capacity >= 32);
    try testing.expectEqualSlices(
        u8,
        large_data[0..],
        zc.slice(),
    );
}

test "ZeroCopy: Multiple Writes" {
    const gpa = testing.allocator;

    const hello = "Hello, ";
    const world = "World!";

    var zc: ZeroCopy(u8) = try .init(gpa, hello.len + world.len);
    defer zc.deinit(gpa);

    {
        defer zc.clear_retaining_capacity();

        const area1 = try zc.get_write_area(gpa, hello.len);
        @memcpy(area1, hello);
        zc.mark_written(area1.len);

        const area2 = try zc.get_write_area(gpa, world.len);
        @memcpy(area2, world);
        zc.mark_written(area2.len);

        try testing.expectEqualSlices(
            u8,
            "Hello, World!",
            zc.slice(),
        );
    }

    {
        // without `mark_written`, the same area gets overwritten
        const area1 = try zc.get_write_area(gpa, hello.len);
        @memcpy(area1, hello);

        // returns same area
        const area2 = try zc.get_write_area(gpa, world.len);
        @memcpy(area2, world);
        zc.mark_written(area1.len + area2.len);

        // previous `World!` is still in buffer
        try testing.expectEqualSlices(
            u8,
            "World! World!",
            zc.slice(),
        );
    }
}

test "ZeroCopy: Zero Size Write" {
    const gpa = testing.allocator;
    var zc: ZeroCopy(u8) = try .init(gpa, 8);
    defer zc.deinit(gpa);

    const area = try zc.get_write_area(gpa, 0);
    try testing.expect(area.len == 0);

    zc.mark_written(0);
    try testing.expect(zc.list.items.len == 0);
}

const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;
