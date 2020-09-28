const std = @import("std");

const Self = @This();

const Event = enum(u1) {
    Read,
    Write,
};

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

pub inline fn recover(ptr: usize) ?*Node {
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

pub fn wait(self: *Self, comptime event: Event) callconv(.Async) void {
    const head = switch (event) {
        .Read => &self.readers,
        .Write => &self.writers,
    };

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

pub fn set(self: *Self, comptime event: Event) ?*Node {
    const head = switch (event) {
        .Read => &self.readers,
        .Write => &self.writers,
    };

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

pub fn next(self: *Self, comptime event: Event) ?*Node {
    const head = switch (event) {
        .Read => &self.readers,
        .Write => &self.writers,
    };

    const lock = self.lock.acquire();
    defer lock.release();

    if (head.* & IS_READY != 0 or head.* == @ptrToInt(@as(?*Node, null))) {
        return null;
    }

    return shift(head);
}

test "waker: wait" {
    const testing = std.testing;

    var waker: Self = .{};

    var A = async waker.wait(.Write);
    var B = async waker.wait(.Write);
    var C = async waker.wait(.Write);

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

    testing.expect(waker.set(.Write).? == a);
    resume a.?.frame;

    testing.expect(waker.set(.Write).? == b.?);
    resume b.?.frame;

    testing.expect(waker.set(.Write).? == c.?);
    resume c.?.frame;

    testing.expect(waker.set(.Write) == null);
    testing.expect(waker.writers & Self.IS_READY != 0);

    var D = async waker.wait(.Write);
    testing.expect(waker.writers == @ptrToInt(@as(?*Self.Node, null)));

    nosuspend await A;
    nosuspend await B;
    nosuspend await C;
    nosuspend await D;
}
