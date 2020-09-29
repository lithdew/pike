const std = @import("std");
const pike = @import("pike.zig");

const Self = @This();

const Node = struct {
    next: ?*Node align(IS_READY + 1) = null,
    prev: ?*Node = null,
    tail: ?*Node = null,
    frame: anyframe,
};

const IS_READY = 1 << 0;

lock: std.Mutex = .{},
readers: usize = @ptrToInt(@as(?*Node, null)),
writers: usize = @ptrToInt(@as(?*Node, null)),

inline fn recover(ptr: usize) ?*Node {
    return @intToPtr(?*Node, ptr & ~@as(usize, IS_READY));
}

inline fn append(ptr: *usize, node: *Node) void {
    var head = recover(ptr.*);
    if (head != null) {
        node.prev = head.?.tail;
        head.?.tail.?.next = node;
    } else {
        head = node;
    }
    head.?.tail = node;
    ptr.* = @ptrToInt(head);
}

inline fn shift(ptr: *usize) ?*Node {
    var head = recover(ptr.*);
    var node = head;

    head = head.?.next;
    if (head != null) {
        head.?.prev = null;
    }
    ptr.* = @ptrToInt(head);

    return node;
}

pub fn wait(self: *Self, comptime event: pike.Event) callconv(.Async) void {
    const head = if (event.read)
        &self.readers
    else if (event.write)
        &self.writers
    else
        @compileError("unknown event type");

    const lock = self.lock.acquire();

    if (head.* & IS_READY != 0) {
        head.* = @ptrToInt(@as(?*Node, null));
        lock.release();
        return;
    }

    suspend {
        append(head, &Node{ .frame = @frame() });
        lock.release();
    }
}

pub fn set(self: *Self, comptime event: pike.Event) ?*Node {
    const head = if (event.read)
        &self.readers
    else if (event.write)
        &self.writers
    else
        @compileError("unknown event type");

    const lock = self.lock.acquire();
    defer lock.release();

    if (head.* & IS_READY != 0) {
        return null;
    }

    if (head.* == 0) {
        head.* = IS_READY;
        return null;
    }

    return shift(head);
}

pub fn next(self: *Self, comptime event: pike.Event) ?*Node {
    const head = if (event.read)
        &self.readers
    else if (event.write)
        &self.writers
    else
        @compileError("unknown event type");

    const lock = self.lock.acquire();
    defer lock.release();

    if (head.* & IS_READY != 0 or head.* == @ptrToInt(@as(?*Node, null))) {
        return null;
    }

    return shift(head);
}

test "Waker.wait" {
    const testing = std.testing;

    var waker: Self = .{};

    var A = async waker.wait(.{ .write = true });
    var B = async waker.wait(.{ .write = true });
    var C = async waker.wait(.{ .write = true });

    var ptr = Self.recover(waker.writers);

    testing.expect(ptr != null);
    testing.expect(ptr.?.tail != null);

    var a = Self.recover(waker.writers);
    var b = a.?.next;
    var c = b.?.next;
    var d = c.?.next;

    testing.expect(waker.writers != @ptrToInt(@as(?*Self.Node, null)));
    testing.expect(a.?.tail.? == c.?);

    testing.expect(b != null);
    testing.expect(c != null);
    testing.expect(d == null);

    testing.expect(waker.set(.{ .write = true }).? == a);
    resume a.?.frame;

    testing.expect(waker.set(.{ .write = true }).? == b.?);
    resume b.?.frame;

    testing.expect(waker.set(.{ .write = true }).? == c.?);
    resume c.?.frame;

    testing.expect(waker.set(.{ .write = true }) == null);
    testing.expect(waker.writers & Self.IS_READY != 0);

    var D = async waker.wait(.{ .write = true });
    testing.expect(waker.writers == @ptrToInt(@as(?*Self.Node, null)));

    nosuspend await A;
    nosuspend await B;
    nosuspend await C;
    nosuspend await D;
}
