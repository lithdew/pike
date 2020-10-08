const std = @import("std");

const mem = std.mem;
const builtin = std.builtin;

const os = std.os;
const windows = os.windows;

const pike = @import("pike.zig");

pub const READ_EVENTS: windows.ULONG = pike.os.AFD_POLL_RECEIVE | pike.os.AFD_POLL_CONNECT_FAIL | pike.os.AFD_POLL_ACCEPT | pike.os.AFD_POLL_DISCONNECT | pike.os.AFD_POLL_ABORT | pike.os.AFD_POLL_LOCAL_CLOSE;
pub const WRITE_EVENTS: windows.ULONG = pike.os.AFD_POLL_SEND | pike.os.AFD_POLL_CONNECT_FAIL | pike.os.AFD_POLL_ABORT | pike.os.AFD_POLL_LOCAL_CLOSE;

const Self = @This();

pub const Data = blk: {
    if (builtin.os.tag == .windows) {
        break :blk struct {
            request: os.windows.OVERLAPPED = .{
                .Internal = 0,
                .InternalHigh = 0,
                .Offset = 0,
                .OffsetHigh = 0,
                .hEvent = null,
            },
            pending: pike.Event = .{},

            pub fn refresh(self: *@This(), event: pike.Event) !void {
                if (self.pending.read == event.read and self.pending.write == event.write) {
                    return;
                }

                const file = @fieldParentPtr(pike.File, "waker", @fieldParentPtr(Self, "data", self));

                if (self.pending.read or self.pending.write) { // Cancel previous AFD poll overlapped request if exists.
                    try pike.os.CancelIoEx(file.handle, &self.request);
                }

                if (event.read) self.pending.read = true;
                if (event.write) self.pending.write = true;

                var events: windows.ULONG = 0;
                if (event.read) events |= READ_EVENTS;
                if (event.write) events |= WRITE_EVENTS;

                try pike.os.refreshAFD(file, events);
            }

            pub fn cancel(self: *@This(), comptime event: pike.Event) !void {
                if (event.read) self.pending.read = false;
                if (event.write) self.pending.write = false;

                try self.refresh(self.pending);
            }

            pub fn reset(self: *@This()) void {
                self.request = .{
                    .Internal = 0,
                    .InternalHigh = 0,
                    .Offset = 0,
                    .OffsetHigh = 0,
                    .hEvent = null,
                };

                self.pending = .{};
            }
        };
    } else {
        break :blk void;
    }
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
data: Data = if (builtin.os.tag == .windows) .{} else {},

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
        head.?.tail = node.?.tail;
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

        if (builtin.os.tag == .windows) {
            self.data.refresh(event) catch |err| @panic(@errorName(err));
        }

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

    if (builtin.os.tag == .windows) {
        self.data.cancel(event) catch |err| @panic(@errorName(err));
    }

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
