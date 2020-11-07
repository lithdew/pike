const std = @import("std");
const meta = std.meta;
const math = std.math;
const testing = std.testing;

const assert = std.debug.assert;

pub const Waker = packed struct {
    const Address = meta.Int(.unsigned, meta.bitCount(usize) - 1);
    const Self = @This();

    ready: bool = false,
    pointer: Address = @ptrToInt(@as(?*List(anyframe).Node, null)),

    fn append(self: *Self, node: *List(anyframe).Node) void {
        var pointer = @intToPtr(?*List(anyframe).Node, @intCast(usize, self.pointer) << 1);
        defer self.pointer = @truncate(Address, @ptrToInt(pointer) >> 1);

        List(anyframe).append(&pointer, node);
    }

    fn prepend(self: *Self, node: *List(anyframe).Node) void {
        var pointer = @intToPtr(?*List(anyframe).Node, @intCast(usize, self.pointer) << 1);
        defer self.pointer = @truncate(Address, @ptrToInt(pointer) >> 1);

        List(anyframe).prepend(&pointer, node);
    }

    fn pop(self: *Self) ?anyframe {
        var pointer = @intToPtr(?*List(anyframe).Node, @intCast(usize, self.pointer) << 1);
        defer self.pointer = @truncate(Address, @ptrToInt(pointer) >> 1);

        return List(anyframe).pop(&pointer);
    }

    pub fn wait(self: *Self, lock: *std.Mutex) callconv(.Async) void {
        const held = lock.acquire();

        if (self.ready) {
            self.ready = false;
            held.release();
            return;
        }

        suspend {
            self.append(&List(anyframe).Node{ .data = @frame() });
            held.release();
        }
    }

    pub fn wake(self: *Self, lock: *std.Mutex) ?anyframe {
        const held = lock.acquire();
        defer held.release();

        if (self.ready) return null;

        if (self.pointer == @ptrToInt(@as(?*List(anyframe).Node, null))) {
            self.ready = true;
            return null;
        }

        return self.pop();
    }

    pub fn next(self: *Self, lock: *std.Mutex) ?anyframe {
        const held = lock.acquire();
        defer held.release();

        if (self.ready or self.pointer == @ptrToInt(@as(?*List(anyframe).Node, null))) {
            return null;
        }

        return self.pop();
    }
};

test "Waker.wake() / Waker.wait()" {
    var lock: std.Mutex = .{};
    var waker: Waker = .{};

    testing.expect(waker.wake(&lock) == @as(?anyframe, null));
    testing.expect(waker.ready);

    nosuspend waker.wait(&lock);
    testing.expect(!waker.ready);

    var A = async waker.wait(&lock);
    var B = async waker.wait(&lock);
    var C = async waker.wait(&lock);

    resume waker.wake(&lock).?;
    resume waker.wake(&lock).?;
    resume waker.wake(&lock).?;

    testing.expect(waker.wake(&lock) == @as(?anyframe, null));
    testing.expect(waker.ready);

    nosuspend await A;
    nosuspend await B;
    nosuspend await C;
}

fn List(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            data: T,
            next: ?*Self.Node = null,
            prev: ?*Self.Node = null,
            tail: ?*Self.Node = null,
        };

        pub fn append(self: *?*Self.Node, node: *Self.Node) void {
            assert(node.tail == null);
            assert(node.prev == null);
            assert(node.next == null);

            if (self.*) |head| {
                assert(head.prev == null);

                const tail = head.tail orelse unreachable;

                node.prev = tail;
                tail.next = node;

                head.tail = node;
            } else {
                node.tail = node;
                self.* = node;
            }
        }

        pub fn prepend(self: *?*Self.Node, node: *Self.Node) void {
            assert(node.tail == null);
            assert(node.prev == null);
            assert(node.next == null);

            if (self.*) |head| {
                assert(head.prev == null);

                node.tail = head.tail;
                head.tail = null;

                node.next = head;
                head.prev = node;

                self.* = node;
            } else {
                node.tail = node;
                self.* = node;
            }
        }

        pub fn pop(self: *?*Self.Node) ?T {
            if (self.*) |head| {
                assert(head.prev == null);

                self.* = head.next;
                if (self.*) |next| {
                    next.tail = head.tail;
                    next.prev = null;
                }

                return head.data;
            }

            return null;
        }
    };
}

test "List.append() / List.prepend() / List.pop()" {
    const U8List = List(u8);
    const Node = U8List.Node;

    var list: ?*Node = null;

    var A = Node{ .data = 'A' };
    var B = Node{ .data = 'B' };
    var C = Node{ .data = 'C' };
    var D = Node{ .data = 'D' };

    U8List.append(&list, &C);
    U8List.prepend(&list, &B);
    U8List.append(&list, &D);
    U8List.prepend(&list, &A);

    const expected = "ABCD";

    var i: usize = 0;
    while (U8List.pop(&list)) |data| : (i += 1) {
        testing.expectEqual(data, expected[i]);
    }
}
