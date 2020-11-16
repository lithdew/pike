const std = @import("std");
const pike = @import("pike.zig");

const mem = std.mem;
const meta = std.meta;
const math = std.math;
const testing = std.testing;

const assert = std.debug.assert;

pub const Waker = packed struct {
    pub const Node = List(pike.Task).Node;

    const Address = meta.Int(.unsigned, meta.bitCount(usize) - 1);
    const Self = @This();

    ready: bool = false,
    pointer: Address = @ptrToInt(@as(?*Node, null)),

    fn append(self: *Self, node: *Node) void {
        var pointer = @intToPtr(?*Node, @intCast(usize, self.pointer) << 1);
        defer self.pointer = @truncate(Address, @ptrToInt(pointer) >> 1);

        List(pike.Task).append(&pointer, node);
    }

    fn prepend(self: *Self, node: *Node) void {
        var pointer = @intToPtr(?*Node, @intCast(usize, self.pointer) << 1);
        defer self.pointer = @truncate(Address, @ptrToInt(pointer) >> 1);

        List(pike.Task).prepend(&pointer, node);
    }

    fn pop(self: *Self) ?*Node {
        var pointer = @intToPtr(?*Node, @intCast(usize, self.pointer) << 1);
        defer self.pointer = @truncate(Address, @ptrToInt(pointer) >> 1);

        return List(pike.Task).pop(&pointer);
    }

    pub fn wait(self: *Self, lock: *std.Mutex) callconv(.Async) void {
        const held = lock.acquire();

        if (self.ready) {
            self.ready = false;
            held.release();
            return;
        }

        var node = Node{ .data = pike.Task.init(@frame()) };

        suspend {
            self.append(&node);
            held.release();
        }
    }

    pub fn wake(self: *Self) ?*Node {
        if (self.ready) return null;

        if (self.pointer == @ptrToInt(@as(?*Node, null))) {
            self.ready = true;
            return null;
        }

        return self.pop();
    }

    pub fn next(self: *Self) ?*Node {
        if (self.ready or self.pointer == @ptrToInt(@as(?*Node, null))) {
            return null;
        }

        return self.pop();
    }
};

test "Waker.wake() / Waker.wait()" {
    var lock: std.Mutex = .{};
    var waker: Waker = .{};

    testing.expect(waker.wake() == @as(?*Waker.Node, null));
    testing.expect(waker.ready);

    nosuspend waker.wait(&lock);
    testing.expect(!waker.ready);

    var A = async waker.wait(&lock);
    var B = async waker.wait(&lock);
    var C = async waker.wait(&lock);

    pike.dispatch(&waker.wake().?.data);
    pike.dispatch(&waker.wake().?.data);
    pike.dispatch(&waker.wake().?.data);

    testing.expect(waker.wake() == @as(?*Waker.Node, null));
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

        pub fn pop(self: *?*Self.Node) ?*Self.Node {
            if (self.*) |head| {
                assert(head.prev == null);

                self.* = head.next;
                if (self.*) |next| {
                    next.tail = head.tail;
                    next.prev = null;
                }

                return head;
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
    while (U8List.pop(&list)) |node| : (i += 1) {
        testing.expectEqual(node.data, expected[i]);
    }
}

pub fn PackedWaker(comptime Frame: type, comptime Set: type) type {
    const set_fields = meta.fields(Set);
    const set_count = set_fields.len;

    return struct {
        const FrameList = PackedList(Frame, Set);
        const FrameNode = FrameList.Node;
        const Self = @This();

        ready: [set_count]bool = [_]bool{false} ** set_count,
        heads: [set_count]?*FrameNode = [_]?*FrameNode{null} ** set_count,

        pub fn wait(self: *Self, lock: *std.Mutex, set: Set, data: Frame, frame: *anyframe) callconv(.Async) void {
            const held = lock.acquire();

            var any_ready = false;
            inline for (set_fields) |field, field_index| {
                if (@field(set, field.name) and self.ready[field_index]) {
                    if (self.ready[field_index]) {
                        self.ready[field_index] = false;
                        any_ready = true;
                    }
                }
            }

            if (any_ready) {
                held.release();
            } else {
                var node = FrameNode{ .data = data };

                suspend {
                    FrameList.append(&self.heads, set, &node);
                    frame.* = @frame();
                    held.release();
                }
            }
        }

        pub fn wake(self: *Self, lock: *std.Mutex, set: Set) ?Frame {
            const held = lock.acquire();
            defer held.release();

            return FrameList.pop(&self.heads, set) orelse blk: {
                inline for (set_fields) |field, field_index| {
                    if (@field(set, field.name) and self.heads[field_index] == null) {
                        self.ready[field_index] = true;
                    }
                }

                break :blk null;
            };
        }

        pub fn next(self: *Self, lock: *std.Mutex, set: Set) ?Frame {
            const held = lock.acquire();
            defer held.release();

            inline for (set_fields) |field, field_index| {
                if (@field(set, field.name) and self.heads[field_index] == null) {
                    return null;
                }
            }

            return FrameList.pop(&self.heads, set);
        }
    };
}

test "PackedWaker.wake() / PackedWaker.wait()" {
    const Set = struct {
        a: bool = false,
        b: bool = false,
        c: bool = false,
        d: bool = false,
    };

    const Scope = struct {
        inner: anyframe,
    };

    const Test = struct {
        fn do(waker: *PackedWaker(*Scope, Set), lock: *std.Mutex, set: Set, completed: *bool) callconv(.Async) void {
            defer completed.* = true;

            var scope = Scope{ .inner = undefined };
            waker.wait(lock, set, &scope, &scope.inner);
        }
    };

    var lock: std.Mutex = .{};
    var waker: PackedWaker(*Scope, Set) = .{};

    testing.expect(waker.wake(&lock, .{ .a = true, .b = true, .c = true, .d = true }) == null);
    testing.expect(mem.allEqual(bool, &waker.ready, true));

    var scope = Scope{ .inner = undefined };
    nosuspend waker.wait(&lock, .{ .a = true, .b = true, .c = true, .d = true }, &scope, &scope.inner);
    testing.expect(mem.allEqual(bool, &waker.ready, false));

    var A_done = false;
    var B_done = false;
    var C_done = false;
    var D_done = false;

    var A = async Test.do(&waker, &lock, .{ .a = true, .c = true }, &A_done);
    var B = async Test.do(&waker, &lock, .{ .a = true, .b = true, .c = true }, &B_done);
    var C = async Test.do(&waker, &lock, .{ .a = true, .b = true, .d = true }, &C_done);
    var D = async Test.do(&waker, &lock, .{ .d = true }, &D_done);

    resume waker.wake(&lock, .{ .b = true }).?.inner;
    nosuspend await B;
    testing.expect(B_done);

    resume waker.wake(&lock, .{ .b = true }).?.inner;
    nosuspend await C;
    testing.expect(C_done);

    resume waker.wake(&lock, .{ .a = true }).?.inner;
    nosuspend await A;
    testing.expect(A_done);

    resume waker.wake(&lock, .{ .d = true }).?.inner;
    nosuspend await D;
    testing.expect(D_done);
}

fn PackedList(comptime T: type, comptime U: type) type {
    const set_fields = meta.fields(U);
    const set_count = set_fields.len;

    return struct {
        const Self = @This();

        pub const Node = struct {
            data: T,
            next: [set_count]?*Self.Node = [_]?*Node{null} ** set_count,
            prev: [set_count]?*Self.Node = [_]?*Node{null} ** set_count,
        };

        pub fn append(heads: *[set_count]?*Self.Node, set: U, node: *Self.Node) void {
            assert(mem.allEqual(?*Self.Node, &node.prev, null));
            assert(mem.allEqual(?*Self.Node, &node.next, null));

            inline for (set_fields) |field, i| {
                if (@field(set, field.name)) {
                    if (heads[i]) |head| {
                        const tail = head.prev[i] orelse unreachable;

                        node.prev[i] = tail;
                        tail.next[i] = node;

                        head.prev[i] = node;
                    } else {
                        node.prev[i] = node;
                        heads[i] = node;
                    }
                }
            }
        }

        pub fn prepend(heads: *[set_count]?*Self.Node, set: U, node: *Self.Node) void {
            assert(mem.allEqual(?*Self.Node, &node.prev, null));
            assert(mem.allEqual(?*Self.Node, &node.next, null));

            inline for (set_fields) |field, i| {
                if (@field(set, field.name)) {
                    if (heads[i]) |head| {
                        node.prev[i] = head;
                        node.next[i] = head;

                        head.prev[i] = node;
                        heads[i] = node;
                    } else {
                        node.prev[i] = node;
                        heads[i] = node;
                    }
                }
            }
        }

        pub fn pop(heads: *[set_count]?*Self.Node, set: U) ?T {
            inline for (set_fields) |field, field_index| {
                if (@field(set, field.name) and heads[field_index] != null) {
                    const head = heads[field_index] orelse unreachable;

                    comptime var j = 0;
                    inline while (j < set_count) : (j += 1) {
                        if (head.prev[j]) |prev| prev.next[j] = if (prev != head.next[j]) head.next[j] else null;
                        if (head.next[j]) |next| next.prev[j] = head.prev[j];
                        if (heads[j] == head) heads[j] = head.next[j];
                    }

                    return head.data;
                }
            }

            return null;
        }
    };
}

test "PackedList.append() / PackedList.prepend() / PackedList.pop()" {
    const Set = struct {
        a: bool = false,
        b: bool = false,
        c: bool = false,
        d: bool = false,
    };

    const U8List = PackedList(u8, Set);
    const Node = U8List.Node;

    var heads: [@sizeOf(Set)]?*Node = [_]?*Node{null} ** @sizeOf(Set);

    var A = Node{ .data = 'A' };
    var B = Node{ .data = 'B' };
    var C = Node{ .data = 'C' };
    var D = Node{ .data = 'D' };

    U8List.append(&heads, .{ .a = true, .c = true }, &A);
    U8List.append(&heads, .{ .a = true, .b = true, .c = true }, &B);
    U8List.prepend(&heads, .{ .a = true, .b = true, .d = true }, &C);
    U8List.append(&heads, .{ .d = true }, &D);

    testing.expect(U8List.pop(&heads, .{ .b = true }) == C.data);
    testing.expect(U8List.pop(&heads, .{ .b = true }) == B.data);
    testing.expect(U8List.pop(&heads, .{ .a = true }) == A.data);
    testing.expect(U8List.pop(&heads, .{ .d = true }) == D.data);

    testing.expect(mem.allEqual(?*Node, &heads, null));
}

test "PackedList.append() / PackedList.prepend() / PackedList.pop()" {
    const Set = struct {
        a: bool = false,
        b: bool = false,
        c: bool = false,
        d: bool = false,
    };

    const U8List = PackedList(u8, Set);
    const Node = U8List.Node;

    var heads: [@sizeOf(Set)]?*Node = [_]?*Node{null} ** @sizeOf(Set);

    var A = Node{ .data = 'A' };
    var B = Node{ .data = 'B' };
    var C = Node{ .data = 'C' };
    var D = Node{ .data = 'D' };

    U8List.append(&heads, .{ .a = true, .b = true }, &A);
    testing.expect(heads[0] == &A and heads[0].?.prev[0] == &A and heads[0].?.next[0] == null);
    testing.expect(heads[1] == &A and heads[1].?.prev[1] == &A and heads[1].?.next[1] == null);
    testing.expect(heads[2] == null);
    testing.expect(heads[3] == null);

    U8List.prepend(&heads, .{ .a = true, .c = true }, &B);
    testing.expect(heads[0] == &B and heads[0].?.prev[0] == &A and heads[0].?.prev[0].?.next[0] == null);
    testing.expect(heads[1] == &A and heads[1].?.prev[1] == &A and heads[1].?.prev[1].?.next[1] == null);
    testing.expect(heads[2] == &B and heads[2].?.prev[2] == &B and heads[2].?.prev[2].?.next[2] == null);
    testing.expect(heads[3] == null);

    testing.expect(U8List.pop(&heads, .{ .a = true }) == B.data);
    testing.expect(heads[0] == &A);
    testing.expect(heads[0].?.prev[0] == &A);
    testing.expect(mem.allEqual(?*Node, &heads[0].?.next, null));

    testing.expect(U8List.pop(&heads, .{ .a = true }) == A.data);
    testing.expect(mem.allEqual(?*Node, &heads, null));
}
