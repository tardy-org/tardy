pub fn Queue(comptime T: type) type {
    const List = std.DoublyLinkedList(T);
    const Node = List.Node;

    return struct {
        allocator: mem.Allocator,
        items: List,

        pub fn init(allocator: mem.Allocator) Queue {
            return .{ .allocator = allocator, .items = List{} };
        }

        pub fn deinit(self: *Queue) void {
            while (self.items.pop()) |node| self.allocator.destroy(node);
        }

        pub fn append(self: *Queue, item: T) !void {
            const node = try self.allocator.create(Node);
            node.* = .{ .data = item };
            self.items.append(node);
        }

        pub fn pop(self: *Queue) ?T {
            const node = self.items.popFirst() orelse return null;
            defer self.allocator.destroy(node);
            return node.data;
        }

        pub fn pop_assert(self: *Queue) T {
            const node = self.items.popFirst().?;
            defer self.allocator.destroy(node);
            return node.data;
        }
    };
}

const std = @import("std");
const mem = std.mem;
