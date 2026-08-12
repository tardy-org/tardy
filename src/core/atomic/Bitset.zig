/// An Atomic Dynamic Bitset
pub const Bitset = @This();

words: []atomic.Value(usize),
lock: std.Io.RwLock,
/// Not safe to access. Use `get_bit_length`.
bit_length: usize,

pub fn init(gpa: mem.Allocator, size: usize, default: bool) !Bitset {
    const word_count = @divCeil(size, @bitSizeOf(usize));
    const words = try gpa.alloc(
        atomic.Value(usize),
        word_count,
    );
    errdefer gpa.free(words);

    const value: usize = if (default) math.maxInt(usize) else 0;
    for (words) |*word| word.* = .{ .raw = value };

    return .{
        .words = words,
        .lock = .init,
        .bit_length = size,
    };
}

pub fn deinit(bitset: *Bitset, gpa: mem.Allocator, io: std.Io) void {
    bitset.lock.lockUncancelable(io);
    defer bitset.lock.unlock(io);

    gpa.free(bitset.words);
}

fn resize(
    bitset: *Bitset,
    gpa: mem.Allocator,
    io: std.Io,
    new_size: usize,
    default: bool,
) !void {
    bitset.lock.lockUncancelable(io);
    defer bitset.lock.unlock(io);

    const new_word_count = @divCeil(new_size, @bitSizeOf(usize));
    debug.assert(new_word_count > bitset.words.len);

    const value: usize = if (default) math.maxInt(usize) else 0;
    const old_words = bitset.words;

    if (gpa.resize(bitset.words, new_word_count)) {
        for (bitset.words[old_words.len..]) |*word| word.* = .{
            .raw = value,
        };
    } else {
        defer gpa.free(old_words);
        const new_words = try gpa.alloc(
            atomic.Value(usize),
            new_word_count,
        );
        @memcpy(new_words[0..old_words.len], old_words[0..]);
        for (new_words[old_words.len..]) |*word| word.* = .{
            .raw = value,
        };
        bitset.words = new_words;
        bitset.bit_length = new_size;
    }
}

pub fn is_empty(bitset: *Bitset, io: std.Io) bool {
    bitset.lock.lockSharedUncancelable(io);
    defer bitset.lock.unlockShared(io);

    for (bitset.words) |*word| if (word.load(.acquire) != 0) return false;
    return true;
}

pub fn get_bit_length(bitset: *Bitset, io: std.Io) usize {
    bitset.lock.lockSharedUncancelable(io);
    defer bitset.lock.unlockShared(io);

    return bitset.bit_length;
}

pub fn set(bitset: *Bitset, gpa: mem.Allocator, io: std.Io, index: usize) !void {
    bitset.lock.lockSharedUncancelable(io);
    defer bitset.lock.unlockShared(io);

    if (index > bitset.bit_length) {
        bitset.lock.unlockShared(io);
        defer bitset.lock.lockSharedUncancelable(io);

        try bitset.resize(
            gpa,
            io,
            try math.ceilPowerOfTwo(usize, index),
            false,
        );
    }
    debug.assert(bitset.bit_length >= index);

    const word = index / @bitSizeOf(usize);
    debug.assert(word < bitset.words.len);
    const mask: usize = @as(usize, 1) << @intCast(@mod(index, @bitSizeOf(usize)));
    _ = bitset.words[word].fetchOr(mask, .release);
}

pub fn is_set(bitset: *Bitset, io: std.Io, index: usize) bool {
    bitset.lock.lockSharedUncancelable(io);
    defer bitset.lock.unlockShared(io);
    debug.assert(bitset.bit_length >= index);

    const word = index / @bitSizeOf(usize);
    debug.assert(word < bitset.words.len);
    const mask: usize = @as(usize, 1) << @intCast(@mod(index, @bitSizeOf(usize)));
    return (bitset.words[word].load(.acquire) & mask) != 0;
}

pub fn unset(bitset: *Bitset, io: std.Io, index: usize) void {
    bitset.lock.lockSharedUncancelable(io);
    defer bitset.lock.unlockShared(io);
    debug.assert(bitset.bit_length >= index);

    const word = index / @bitSizeOf(usize);
    debug.assert(word < bitset.words.len);
    var mask: usize = math.maxInt(usize);
    mask ^= @as(usize, 1) << @intCast(@mod(index, @bitSizeOf(usize)));
    _ = bitset.words[word].fetchAnd(mask, .release);
}

pub fn unset_all(bitset: *Bitset, io: std.Io) void {
    bitset.lock.lockSharedUncancelable(io);
    defer bitset.lock.unlockShared(io);

    for (bitset.words) |*word| word.store(0, .release);
}

const std = @import("std");
const mem = std.mem;
const math = std.math;
const debug = std.debug;
const atomic = std.atomic;
