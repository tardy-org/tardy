const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// Storage is deleteless and clobberless.
pub const Storage = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(*anyopaque),

    pub fn init(allocator: std.mem.Allocator) Storage {
        return .{
            .arena = .init(allocator),
            .map = .{},
        };
    }

    pub fn deinit(self: Storage) void {
        self.arena.deinit();
    }

    /// Store a pointer that is not managed.
    /// This will NOT CLONE the item.
    /// This asserts that no other item has the same name.
    pub fn store_ptr(self: *Storage, name: []const u8, item: anytype) !void {
        assert(@typeInfo(@TypeOf(item)) == .Pointer);
        try self.map.putNoClobber(self.arena.allocator(), name, @ptrCast(item));
    }

    pub fn store_alloc_ret(self: *Storage, name: []const u8, item: anytype) !*@TypeOf(item) {
        const allocator = self.arena.allocator();
        const clone = try allocator.create(@TypeOf(item));
        errdefer allocator.destroy(clone);
        clone.* = item;
        try self.map.putNoClobber(allocator, name, @ptrCast(clone));
        return clone;
    }

    /// Store a new item in the Storage.
    /// This will CLONE (allocate) the item that you pass in and manage the clone.
    /// This asserts that no other item has the same name.
    pub fn store_alloc(self: *Storage, name: []const u8, item: anytype) !void {
        _ = try self.store_alloc_ret(name, item);
    }

    /// Get an item that is within the Storage.
    /// This asserts that the item you are looking for exists.
    pub fn get(self: *Storage, name: []const u8, comptime T: type) T {
        return self.get_ptr(name, T).*;
    }

    /// Get a const (immutable) pointer to an item that is within the Storage.
    /// This asserts that the item you are looking for exists.
    pub fn get_const_ptr(self: *Storage, name: []const u8, comptime T: type) *const T {
        const got = self.map.get(name).?;
        return @ptrCast(@alignCast(got));
    }

    /// Get a (mutable) pointer to an item that is within the Storage.
    /// This asserts that the item you are looking for exists.
    pub fn get_ptr(self: *Storage, name: []const u8, comptime T: type) *T {
        const got = self.map.get(name).?;
        return @ptrCast(@alignCast(got));
    }
};

test "Storage Storing" {
    var storage: Storage = .init(testing.allocator);
    defer storage.deinit();

    const byte: u8 = 100;
    try storage.store_alloc("byte", byte);

    const index: usize = 9447721;
    try storage.store_alloc("index", index);

    const value: u32 = 100;
    try storage.store_alloc("value", value);

    const value_ptr = storage.get_ptr("value", u32);
    try testing.expectEqual(value_ptr.*, 100);
    value_ptr.* += 100;

    try testing.expectEqual(byte, storage.get("byte", u8));
    try testing.expectEqual(index, storage.get("index", usize));
    try testing.expectEqual(value + 100, storage.get("value", u32));
}
