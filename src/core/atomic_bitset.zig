const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Value;

pub const AtomicDynamicBitSet = struct {
    allocator: std.mem.Allocator,
    words: []Atomic(usize),
    lock: std.Io.RwLock,
    /// Not safe to access. Use `get_bit_length`.
    bit_length: usize,

    pub fn init(allocator: std.mem.Allocator, size: usize, default: bool) !AtomicDynamicBitSet {
        const word_count = try std.math.divCeil(usize, size, @bitSizeOf(usize));
        const words = try allocator.alloc(Atomic(usize), word_count);
        errdefer allocator.free(words);
        const value: usize = if (default) std.math.maxInt(usize) else 0;
        for (words) |*word| word.* = .{ .raw = value };
        return .{ .allocator = allocator, .words = words, .lock = .{}, .bit_length = size };
    }

    pub fn deinit(self: *AtomicDynamicBitSet, allocator: std.mem.Allocator) void {
        self.lock.lock();
        defer self.lock.unlock();
        allocator.free(self.words);
    }

    fn resize(self: *AtomicDynamicBitSet, allocator: std.mem.Allocator, new_size: usize, default: bool) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const new_word_count = try std.math.divCeil(usize, new_size, @bitSizeOf(usize));
        assert(new_word_count > self.words.len);

        const value: usize = if (default) std.math.maxInt(usize) else 0;
        const old_words = self.words;
        if (allocator.resize(self.words, new_word_count)) {
            for (self.words[old_words.len..]) |*word| word.* = .{ .raw = value };
        } else {
            defer allocator.free(old_words);
            const new_words = try allocator.alloc(Atomic(usize), new_word_count);
            std.mem.copyForwards(Atomic(usize), new_words[0..old_words.len], old_words[0..]);
            for (new_words[old_words.len..]) |*word| word.* = .{ .raw = value };
            self.words = new_words;
            self.bit_length = new_size;
        }
    }

    pub fn is_empty(self: *AtomicDynamicBitSet) bool {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        for (self.words) |*word| if (word.load(.acquire) != 0) return false;
        return true;
    }

    pub fn get_bit_length(self: *AtomicDynamicBitSet) usize {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.bit_length;
    }

    pub fn set(self: *AtomicDynamicBitSet, index: usize) !void {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        if (index > self.bit_length) {
            self.lock.unlockShared();
            try self.resize(self.allocator, try std.math.ceilPowerOfTwo(usize, index), false);
            self.lock.lockShared();
        }
        assert(self.bit_length >= index);

        const word = index / @bitSizeOf(usize);
        assert(word < self.words.len);
        const mask: usize = @as(usize, 1) << @intCast(@mod(index, @bitSizeOf(usize)));
        _ = self.words[word].fetchOr(mask, .release);
    }

    pub fn is_set(self: *AtomicDynamicBitSet, index: usize) bool {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        assert(self.bit_length >= index);

        const word = index / @bitSizeOf(usize);
        assert(word < self.words.len);
        const mask: usize = @as(usize, 1) << @intCast(@mod(index, @bitSizeOf(usize)));
        return (self.words[word].load(.acquire) & mask) != 0;
    }

    pub fn unset(self: *AtomicDynamicBitSet, index: usize) void {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        assert(self.bit_length >= index);

        const word = index / @bitSizeOf(usize);
        assert(word < self.words.len);
        var mask: usize = std.math.maxInt(usize);
        mask ^= @as(usize, 1) << @intCast(@mod(index, @bitSizeOf(usize)));
        _ = self.words[word].fetchAnd(mask, .release);
    }

    pub fn unset_all(self: *AtomicDynamicBitSet) void {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        for (self.words) |*word| word.store(0, .release);
    }
};
