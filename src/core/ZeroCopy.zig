pub fn ZeroCopy(comptime T: type) type {
    return struct {
        const ZeroCopy_t = @This();
        ptr: [*]T,
        len: usize,
        capacity: usize,

        pub fn init(allocator: mem.Allocator, capacity: usize) !ZeroCopy_t {
            const slice = try allocator.alloc(T, capacity);
            return .{
                .ptr = slice.ptr,
                .len = 0,
                .capacity = capacity,
            };
        }

        pub fn deinit(zc: *ZeroCopy_t, allocator: mem.Allocator) void {
            allocator.free(zc.ptr[0..zc.capacity]);
        }

        pub fn as_slice(zc: *const ZeroCopy_t) []T {
            return zc.ptr[0..zc.len];
        }

        pub fn subslice(zc: *const ZeroCopy_t, options: SubsliceOptions) []T {
            const start: usize = options.start orelse 0;
            const end: usize = options.end orelse zc.len;
            debug.assert(start <= end);
            debug.assert(end <= zc.len);

            return zc.ptr[start..end];
        }

        /// This returns a slice that you can write into for zero-copy uses.
        /// This is mostly used when we are passing a buffer to I/O then acting on it.
        ///
        /// The write area that is returned is ONLY valid until the next call of
        /// `get_write_area` or mark_written.
        pub fn get_write_area(
            zc: *ZeroCopy_t,
            allocator: mem.Allocator,
            size: usize,
        ) ![]T {
            const available_space = zc.capacity - zc.len;
            if (available_space >= size) {
                return zc.ptr[zc.len .. zc.len + size];
            } else {
                const old_slice = zc.ptr[0..zc.capacity];
                const new_size = try std.math.ceilPowerOfTwo(
                    usize,
                    zc.capacity + size,
                );

                if (allocator.remap(
                    zc.ptr[0..zc.capacity],
                    new_size,
                )) |new| {
                    zc.ptr = new.ptr;
                    zc.capacity = new.len;
                } else if (allocator.resize(
                    zc.ptr[0..zc.capacity],
                    new_size,
                )) {
                    zc.capacity = new_size;
                } else {
                    const new_slice = try allocator.alloc(T, new_size);
                    @memcpy(new_slice[0..zc.len], zc.ptr[0..zc.len]);
                    allocator.free(old_slice);

                    zc.ptr = new_slice.ptr;
                    zc.capacity = new_slice.len;
                }

                debug.assert(zc.capacity - zc.len >= size);
                return zc.ptr[zc.len .. zc.len + size];
            }
        }

        pub fn get_write_area_assume_space(zc: *const ZeroCopy_t, size: usize) []T {
            debug.assert(zc.capacity - zc.len >= size);
            return zc.ptr[zc.len .. zc.len + size];
        }

        pub fn mark_written(zc: *ZeroCopy_t, length: usize) void {
            debug.assert(zc.len + length <= zc.capacity);
            zc.len += length;
        }

        pub fn shrink_retaining_capacity(zc: *ZeroCopy_t, new_size: usize) void {
            debug.assert(new_size <= zc.len);
            zc.len = new_size;
        }

        pub fn shrink_clear_and_free(
            zc: *ZeroCopy_t,
            allocator: mem.Allocator,
            new_size: usize,
        ) !void {
            debug.assert(new_size <= zc.len);
            if (!allocator.resize(
                zc.ptr[0..zc.capacity],
                new_size,
            )) {
                const slice = try allocator.realloc(
                    zc.ptr[0..zc.capacity],
                    new_size,
                );
                zc.ptr = slice.ptr;
            }
            zc.capacity = new_size;
            zc.len = 0;
        }

        pub fn clear_retaining_capacity(zc: *ZeroCopy_t) void {
            zc.len = 0;
        }

        pub fn clear_and_free(zc: *ZeroCopy_t, allocator: mem.Allocator) void {
            allocator.free(zc.ptr[0..zc.capacity]);
            zc.len = 0;
            zc.capacity = 0;
        }
    };
}

const SubsliceOptions = struct {
    start: ?usize = null,
    end: ?usize = null,
};

test "ZeroCopy: First" {
    const garbage: [128]u8 = @splat(212);

    var zc: ZeroCopy(u8) = try .init(testing.allocator, 512);
    defer zc.deinit(testing.allocator);

    const write_area = try zc.get_write_area(
        testing.allocator,
        garbage.len,
    );
    @memcpy(write_area, garbage[0..]);
    zc.mark_written(write_area.len);

    try testing.expectEqualSlices(
        u8,
        garbage[0..],
        zc.as_slice()[0..write_area.len],
    );
}

test "ZeroCopy: Growth" {
    var zc: ZeroCopy(u8) = try .init(testing.allocator, 16);
    defer zc.deinit(testing.allocator);

    const large_data: [32]u8 = @splat(1);
    const write_area = try zc.get_write_area(
        testing.allocator,
        large_data.len,
    );
    @memcpy(write_area, &large_data);
    zc.mark_written(write_area.len);

    try testing.expect(zc.capacity >= 32);
    try testing.expectEqualSlices(
        u8,
        large_data[0..],
        zc.as_slice(),
    );
}

test "ZeroCopy: Multiple Writes" {
    var zc: ZeroCopy(u8) = try .init(testing.allocator, 64);
    defer zc.deinit(testing.allocator);

    const data1 = "Hello, ";
    const data2 = "World!";

    const area1 = try zc.get_write_area(
        testing.allocator,
        data1.len,
    );
    @memcpy(area1, data1);
    zc.mark_written(area1.len);

    const area2 = try zc.get_write_area(
        testing.allocator,
        data2.len,
    );
    @memcpy(area2, data2);
    zc.mark_written(area2.len);

    try testing.expectEqualSlices(
        u8,
        "Hello, World!",
        zc.as_slice(),
    );
}

test "ZeroCopy: Zero Size Write" {
    var zc: ZeroCopy(u8) = try .init(testing.allocator, 8);
    defer zc.deinit(testing.allocator);

    const area = try zc.get_write_area(testing.allocator, 0);
    try testing.expect(area.len == 0);
    zc.mark_written(0);
    try testing.expect(zc.len == 0);
}

const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;
