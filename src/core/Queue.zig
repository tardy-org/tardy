pub fn Queue(comptime T: type) type {
    const List = std.SinglyLinkedList;
    const Data = struct {
        data: T,
        node: List.Node = .{},
    };

    return struct {
        list: List,

        pub const init: Queue = .{ .list = .{} };

        pub fn deinit(queue: *Queue, gpa: mem.Allocator) void {
            while (queue.list.popLast()) |node| gpa.destroy(node);
        }

        pub fn append(queue: *Queue, gpa: mem.Allocator, item: T) !void {
            const data = try gpa.create(Data);
            data.* = .{ .data = item };
            queue.list.append(&data.node);
        }

        pub fn pop(queue: *Queue, gpa: mem.Allocator) ?T {
            const node = queue.list.popFirst() orelse return null;
            defer gpa.destroy(node);
            return node.data;
        }

        pub fn pop_assert(queue: *Queue, gpa: mem.Allocator) T {
            const node = queue.list.popFirst().?;
            defer gpa.destroy(node);
            return node.data;
        }
    };
}

const std = @import("std");
const mem = std.mem;
