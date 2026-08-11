/// Storage is deleteless and clobberless.
pub const Storage = @This();

state: heap.ArenaAllocator.State,
map: hash_map.String(*anyopaque),

pub const init: Storage = .{
    .state = .init,
    .map = .empty,
};

pub fn deinit(storage: *Storage, gpa: mem.Allocator) void {
    var arena = storage.state.promote(gpa);
    storage.map.deinit(arena.allocator());
    arena.deinit();
}

/// Store a pointer that is not managed.
/// This will NOT CLONE the item.
/// This asserts that no other item has the same name.
pub fn storePtr(
    storage: *Storage,
    gpa: mem.Allocator,
    name: []const u8,
    item: anytype,
) !void {
    debug.assert(@typeInfo(@TypeOf(item)) == .Pointer);

    var arena = storage.state.promote(gpa);
    defer storage.state = arena.state;

    try storage.map.putNoClobber(
        arena.allocator(),
        name,
        @ptrCast(item),
    );
}

/// Store a new item in the Storage.
/// This will CLONE (allocate) the item that you pass in and manage the clone.
/// This asserts that no other item has the same name.
pub fn store(
    storage: *Storage,
    gpa: mem.Allocator,
    name: []const u8,
    item: anytype,
) !void {
    var arena = storage.state.promote(gpa);
    defer storage.state = arena.state;

    const arena_alloc = arena.allocator();
    const clone = try arena_alloc.create(@TypeOf(item));
    errdefer arena_alloc.destroy(clone);

    clone.* = item;

    try storage.map.putNoClobber(
        arena_alloc,
        name,
        @ptrCast(clone),
    );
}

/// Get an item that is within the Storage.
/// This asserts that the item you are looking for exists.
pub fn get(storage: *Storage, name: []const u8, comptime T: type) T {
    return storage.getPtr(name, T).*;
}

/// Get a const (immutable) pointer to an item that is within the Storage.
/// This asserts that the item you are looking for exists.
pub fn getConstPtr(storage: *Storage, name: []const u8, comptime T: type) *const T {
    const got = storage.map.get(name).?;
    return @ptrCast(@alignCast(got));
}

/// Get a (mutable) pointer to an item that is within the Storage.
/// This asserts that the item you are looking for exists.
pub fn getPtr(storage: *Storage, name: []const u8, comptime T: type) *T {
    const got = storage.map.get(name).?;
    return @ptrCast(@alignCast(got));
}

test "Storage Storing" {
    const gpa = testing.allocator;
    var storage: Storage = .init;
    defer storage.deinit(gpa);

    const byte: u8 = 100;
    try storage.store(gpa, "byte", byte);

    const index: usize = 9447721;
    try storage.store(gpa, "index", index);

    const value: u32 = 100;
    try storage.store(gpa, "value", value);

    const value_ptr = storage.getPtr("value", u32);
    try testing.expectEqual(value_ptr.*, 100);
    value_ptr.* += 100;

    try testing.expectEqual(byte, storage.get("byte", u8));
    try testing.expectEqual(
        index,
        storage.get("index", usize),
    );
    try testing.expectEqual(
        value + 100,
        storage.get("value", u32),
    );
}

const std = @import("std");
const heap = std.heap;
const hash_map = std.array_hash_map;
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;
