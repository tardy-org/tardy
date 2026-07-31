pub fn Queue(comptime T: type) type {
    const List = std.DoublyLinkedList(T);
    const Node = List.Node;

    return struct {
        items: List,

        pub fn init(allocator: mem.Allocator) Queue {
            return .{ .allocator = allocator, .items = .{} };
        }

        pub fn deinit(queue: *Queue, allocator: mem.Allocator) void {
            while (queue.items.popLast()) |node| allocator.destroy(node);
        }

        pub fn append(queue: *Queue, allocator: mem.Allocator, item: T) !void {
            const node = try allocator.create(Node);
            node.* = .{ .data = item };
            queue.items.append(node);
        }

        pub fn pop(queue: *Queue, allocator: mem.Allocator) ?T {
            const node = queue.items.popFirst() orelse return null;
            defer allocator.destroy(node);
            return node.data;
        }

        pub fn pop_assert(queue: *Queue, allocator: mem.Allocator) T {
            const node = queue.items.popFirst().?;
            defer allocator.destroy(node);
            return node.data;
        }
    };
}

const std = @import("std");
const mem = std.mem;
