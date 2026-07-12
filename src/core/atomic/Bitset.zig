/// An Atomic Dynamic Bitset
pub const Bitset = @This();

allocator: mem.Allocator,
words: []atomic.Value(usize),
lock: std.Io.RwLock,
/// Not safe to access. Use `get_bit_length`.
bit_length: usize,

pub fn init(allocator: mem.Allocator, size: usize, default: bool) !Bitset {
    const word_count = try std.math.divCeil(usize, size, @bitSizeOf(usize));
    const words = try allocator.alloc(atomic.Value(usize), word_count);
    errdefer allocator.free(words);
    const value: usize = if (default) std.math.maxInt(usize) else 0;
    for (words) |*word| word.* = .{ .raw = value };
    return .{
        .allocator = allocator,
        .words = words,
        .lock = .init,
        .bit_length = size,
    };
}

pub fn deinit(self: *Bitset, allocator: mem.Allocator, io: std.Io) void {
    self.lock.lockUncancelable(io);
    defer self.lock.unlock(io);

    allocator.free(self.words);
}

fn resize(self: *Bitset, allocator: mem.Allocator, io: std.Io, new_size: usize, default: bool) !void {
    self.lock.lockUncancelable(io);
    defer self.lock.unlock(io);

    const new_word_count = @divCeil(new_size, @bitSizeOf(usize));
    debug.assert(new_word_count > self.words.len);

    const value: usize = if (default) std.math.maxInt(usize) else 0;
    const old_words = self.words;
    if (allocator.resize(self.words, new_word_count)) {
        for (self.words[old_words.len..]) |*word| word.* = .{
            .raw = value,
        };
    } else {
        defer allocator.free(old_words);
        const new_words = try allocator.alloc(
            atomic.Value(usize),
            new_word_count,
        );
        @memcpy(new_words[0..old_words.len], old_words[0..]);
        for (new_words[old_words.len..]) |*word| word.* = .{
            .raw = value,
        };
        self.words = new_words;
        self.bit_length = new_size;
    }
}

pub fn is_empty(self: *Bitset, io: std.Io) bool {
    self.lock.lockSharedUncancelable(io);
    defer self.lock.unlockShared(io);

    for (self.words) |*word| if (word.load(.acquire) != 0) return false;
    return true;
}

pub fn get_bit_length(self: *Bitset, io: std.Io) usize {
    self.lock.lockSharedUncancelable(io);
    defer self.lock.unlockShared(io);

    return self.bit_length;
}

pub fn set(self: *Bitset, io: std.Io, index: usize) !void {
    self.lock.lockSharedUncancelable(io);
    defer self.lock.unlockShared(io);

    if (index > self.bit_length) {
        self.lock.unlockShared(io);
        defer self.lock.lockSharedUncancelable(io);

        try self.resize(
            self.allocator,
            io,
            try std.math.ceilPowerOfTwo(usize, index),
            false,
        );
    }
    debug.assert(self.bit_length >= index);

    const word = index / @bitSizeOf(usize);
    debug.assert(word < self.words.len);
    const mask: usize = @as(usize, 1) << @intCast(@mod(index, @bitSizeOf(usize)));
    _ = self.words[word].fetchOr(mask, .release);
}

pub fn is_set(self: *Bitset, io: std.Io, index: usize) bool {
    self.lock.lockSharedUncancelable(io);
    defer self.lock.unlockShared(io);
    debug.assert(self.bit_length >= index);

    const word = index / @bitSizeOf(usize);
    debug.assert(word < self.words.len);
    const mask: usize = @as(usize, 1) << @intCast(@mod(index, @bitSizeOf(usize)));
    return (self.words[word].load(.acquire) & mask) != 0;
}

pub fn unset(self: *Bitset, io: std.Io, index: usize) void {
    self.lock.lockSharedUncancelable(io);
    defer self.lock.unlockShared(io);
    debug.assert(self.bit_length >= index);

    const word = index / @bitSizeOf(usize);
    debug.assert(word < self.words.len);
    var mask: usize = std.math.maxInt(usize);
    mask ^= @as(usize, 1) << @intCast(@mod(index, @bitSizeOf(usize)));
    _ = self.words[word].fetchAnd(mask, .release);
}

pub fn unset_all(self: *Bitset, io: std.Io) void {
    self.lock.lockSharedUncancelable(io);
    defer self.lock.unlockShared(io);

    for (self.words) |*word| word.store(0, .release);
}

const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const atomic = std.atomic;
