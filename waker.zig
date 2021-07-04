const std = @import("std");
const pike = @import("pike.zig");

const mem = std.mem;
const meta = std.meta;
const math = std.math;
const testing = std.testing;

const assert = std.debug.assert;

pub const Waker = struct {
    const EMPTY = 0;
    const NOTIFIED: usize = 1;
    const SHUTDOWN: usize = 2;

    state: usize = EMPTY,

    pub const Node = struct {
        dead: bool = false,
        task: pike.Task,
    };

    pub fn wait(self: *Waker, args: anytype) !void {
        var node: Node = .{ .task = pike.Task.init(@frame()) };

        suspend {
            var state = @atomicLoad(usize, &self.state, .Monotonic);

            while (true) {
                const new_state = switch (state) {
                    EMPTY => @ptrToInt(&node),
                    NOTIFIED => EMPTY,
                    SHUTDOWN => {
                        node.dead = true;
                        pike.dispatch(&node.task, .{ .use_lifo = true });
                        break;
                    },
                    else => unreachable,
                };

                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    new_state,
                    .Release,
                    .Monotonic,
                ) orelse {
                    if (new_state == EMPTY) pike.dispatch(&node.task, args);
                    break;
                };
            }
        }

        if (node.dead) return error.OperationCancelled;
    }

    pub fn notify(self: *Waker) ?*pike.Task {
        var state = @atomicLoad(usize, &self.state, .Monotonic);

        while (true) {
            const new_state = switch (state) {
                EMPTY => NOTIFIED,
                NOTIFIED, SHUTDOWN => return null,
                else => EMPTY,
            };

            state = @cmpxchgWeak(usize, &self.state, state, new_state, .Acquire, .Monotonic) orelse {
                if (new_state == NOTIFIED) return null;
                const node = @intToPtr(*Node, state);
                return &node.task;
            };
        }
    }

    pub fn shutdown(self: *Waker) ?*pike.Task {
        return switch (@atomicRmw(usize, &self.state, .Xchg, SHUTDOWN, .AcqRel)) {
            EMPTY, NOTIFIED, SHUTDOWN => null,
            else => |state| {
                const node = @intToPtr(*Node, state);
                node.dead = true;
                return &node.task;
            },
        };
    }
};

test "Waker.wait() / Waker.notify() / Waker.shutdown()" {
    var waker: Waker = .{};

    {
        var frame = async waker.wait(.{});
        pike.dispatch(waker.notify().?, .{});
        try nosuspend await frame;
    }

    {
        testing.expect(waker.shutdown() == null);
        testing.expectError(error.OperationCancelled, nosuspend waker.wait(.{}));
    }
}

pub fn PackedWaker(comptime Frame: type, comptime Set: type) type {
    const set_fields = meta.fields(Set);
    const set_count = set_fields.len;

    return struct {
        pub const FrameList = PackedList(Frame, Set);
        pub const FrameNode = FrameList.Node;
        const Self = @This();

        ready: [set_count]bool = [_]bool{false} ** set_count,
        heads: [set_count]?*FrameNode = [_]?*FrameNode{null} ** set_count,

        pub fn wait(self: *Self, set: Set) bool {
            var any_ready = false;
            inline for (set_fields) |field, field_index| {
                if (@field(set, field.name) and self.ready[field_index]) {
                    if (self.ready[field_index]) {
                        self.ready[field_index] = false;
                        any_ready = true;
                    }
                }
            }

            return any_ready;
        }

        pub fn wake(self: *Self, set: Set) ?*FrameList.Node {
            return FrameList.pop(&self.heads, set) orelse blk: {
                inline for (set_fields) |field, field_index| {
                    if (@field(set, field.name) and self.heads[field_index] == null) {
                        self.ready[field_index] = true;
                    }
                }

                break :blk null;
            };
        }

        pub fn next(self: *Self, set: Set) ?*FrameList.Node {
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
        fn do(waker: *PackedWaker(*Scope, Set), set: Set, completed: *bool) callconv(.Async) void {
            defer completed.* = true;

            if (waker.wait(set)) return;

            suspend {
                var scope = Scope{ .inner = @frame() };
                var node = meta.Child(@TypeOf(waker)).FrameNode{ .data = &scope };
                meta.Child(@TypeOf(waker)).FrameList.append(&waker.heads, set, &node);
            }
        }
    };

    var waker: PackedWaker(*Scope, Set) = .{};

    testing.expect(waker.wake(.{ .a = true, .b = true, .c = true, .d = true }) == null);
    testing.expect(mem.allEqual(bool, &waker.ready, true));

    testing.expect(waker.wait(.{ .a = true, .b = true, .c = true, .d = true }));
    testing.expect(mem.allEqual(bool, &waker.ready, false));

    var A_done = false;
    var B_done = false;
    var C_done = false;
    var D_done = false;

    var A = async Test.do(&waker, .{ .a = true, .c = true }, &A_done);
    var B = async Test.do(&waker, .{ .a = true, .b = true, .c = true }, &B_done);
    var C = async Test.do(&waker, .{ .a = true, .b = true, .d = true }, &C_done);
    var D = async Test.do(&waker, .{ .d = true }, &D_done);

    resume waker.wake(.{ .b = true }).?.data.inner;
    nosuspend await B;
    testing.expect(B_done);

    resume waker.wake(.{ .b = true }).?.data.inner;
    nosuspend await C;
    testing.expect(C_done);

    resume waker.wake(.{ .a = true }).?.data.inner;
    nosuspend await A;
    testing.expect(A_done);

    resume waker.wake(.{ .d = true }).?.data.inner;
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

        pub fn pop(heads: *[set_count]?*Self.Node, set: U) ?*Self.Node {
            inline for (set_fields) |field, field_index| {
                if (@field(set, field.name) and heads[field_index] != null) {
                    const head = heads[field_index] orelse unreachable;

                    comptime var j = 0;
                    inline while (j < set_count) : (j += 1) {
                        if (head.prev[j]) |prev| prev.next[j] = if (prev != head.next[j]) head.next[j] else null;
                        if (head.next[j]) |next| next.prev[j] = head.prev[j];
                        if (heads[j] == head) heads[j] = head.next[j];
                    }

                    return head;
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

    testing.expect(U8List.pop(&heads, .{ .b = true }).?.data == C.data);
    testing.expect(U8List.pop(&heads, .{ .b = true }).?.data == B.data);
    testing.expect(U8List.pop(&heads, .{ .a = true }).?.data == A.data);
    testing.expect(U8List.pop(&heads, .{ .d = true }).?.data == D.data);

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

    testing.expect(U8List.pop(&heads, .{ .a = true }).?.data == B.data);
    testing.expect(heads[0] == &A);
    testing.expect(heads[0].?.prev[0] == &A);
    testing.expect(mem.allEqual(?*Node, &heads[0].?.next, null));

    testing.expect(U8List.pop(&heads, .{ .a = true }).?.data == A.data);
    testing.expect(mem.allEqual(?*Node, &heads, null));
}
