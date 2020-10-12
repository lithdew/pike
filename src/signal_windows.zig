const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const windows = os.windows;

const mem = std.mem;
const meta = std.meta;

const Self = @This();

const Event = packed struct {
    terminate: bool = false,
    interrupt: bool = false,
    quit: bool = false,
    hup: bool = false,
};

var waker: Waker(Event) = .{};

handle: pike.Handle,

fn handler(dwCtrlType: windows.DWORD) callconv(.Stdcall) windows.BOOL {
    switch (dwCtrlType) {
        pike.os.CTRL_C_EVENT, pike.os.CTRL_BREAK_EVENT => {
            if (waker.set(.{ .interrupt = true, .terminate = true })) |node| {
                resume node.frame;
            }
            return windows.FALSE;
        },
        pike.os.CTRL_CLOSE_EVENT => {
            if (waker.set(.{ .hup = true })) |node| {
                resume node.frame;
            }
            return windows.FALSE;
        },
        pike.os.CTRL_LOGOFF_EVENT, pike.os.CTRL_SHUTDOWN_EVENT => {
            if (waker.set(.{ .quit = true })) |node| {
                resume node.frame;
            }
            return windows.FALSE;
        },
        else => return windows.FALSE,
    }
}

pub fn init(driver: *pike.Driver, comptime event: Event) !Self {
    try pike.os.SetConsoleCtrlHandler(handler, true);
    return Self{ .handle = .{ .inner = windows.INVALID_HANDLE_VALUE, .driver = driver } };
}

pub fn deinit(self: *Self) void {
    pike.os.SetConsoleCtrlHandler(handler, false) catch |err| @panic(@errorName(err));
}

pub fn wait(self: *Self) callconv(.Async) !void {
    waker.wait(.{ .interrupt = true, .terminate = true, .hup = true, .quit = true });
}

pub fn Waker(comptime Set: type) type {
    const set_count = @bitSizeOf(Set);
    const set_int = meta.Int(false, set_count);

    return struct {
        const Node = struct {
            next: [set_count]?*Node = [1]?*Node{null} ** set_count,
            prev: [set_count]?*Node = [1]?*Node{null} ** set_count,
            frame: anyframe,
        };

        const IS_READY = 1 << 0;

        lock: std.Mutex = .{},
        head: [set_count]usize = [1]usize{@ptrToInt(@as(?*Node, null))} ** set_count,
        tail: [set_count]usize = [1]usize{@ptrToInt(@as(?*Node, null))} ** set_count,

        inline fn recover(ptr: usize) ?*Node {
            return @intToPtr(?*Node, ptr & ~@as(usize, IS_READY));
        }

        inline fn append(self: *@This(), comptime ptr: usize, node: *Node) void {
            const head = recover(self.head[ptr]);

            if (head == null) {
                self.head[ptr] = @ptrToInt(node);
            } else {
                const tail = recover(self.tail[ptr]) orelse unreachable;
                tail.next[ptr] = node;
            }

            self.tail[ptr] = @ptrToInt(node);
        }

        inline fn shift(self: *@This(), comptime ptr: usize) ?*Node {
            const head = recover(self.head[ptr]) orelse unreachable;

            self.head[ptr] = @ptrToInt(head.next[ptr]);
            if (recover(self.head[ptr])) |new_head| {
                new_head.prev[ptr] = null;
            } else {
                self.tail[ptr] = @ptrToInt(@as(?*Node, null));
            }

            return head;
        }

        pub fn wait(self: *@This(), comptime event: Set) callconv(.Async) void {
            comptime const set_bits = @bitCast(set_int, event);

            if (set_bits == @as(set_int, 0)) {
                return;
            }

            comptime var i = 0;
            comptime var j = 0;

            const lock = self.lock.acquire();

            var ready = false;
            inline while (i < set_count) : (i += 1) {
                if (set_bits & (1 << i) == 0) continue;

                if (self.head[i] & IS_READY != 0) {
                    self.head[i] = @ptrToInt(@as(?*Node, null));
                    ready = true;
                }
            }

            if (ready) {
                lock.release();
            } else {
                suspend {
                    var node = &Node{ .frame = @frame() };
                    inline while (j < set_count) : (j += 1) {
                        if (set_bits & (1 << j) != 0) self.append(j, node);
                    }
                    lock.release();
                }
            }
        }

        pub fn set(self: *@This(), comptime event: Set) ?*Node {
            comptime const set_bits = @bitCast(set_int, event);

            const lock = self.lock.acquire();
            defer lock.release();

            comptime var i = 0;

            inline while (i < set_count) : (i += 1) {
                if (set_bits & (1 << i) == 0) continue;

                if (self.head[i] & IS_READY == 0 and self.head[i] != @ptrToInt(@as(?*Node, null))) {
                    const node_ptr = self.shift(i);

                    if (node_ptr) |node| {
                        comptime var j = 0;

                        inline while (j < set_count) : (j += 1) {
                            if (j == i) continue;

                            if (node.prev[j]) |prev| {
                                prev.next[j] = node.next[j];
                            } else if (self.head[j] == @ptrToInt(node_ptr)) {
                                self.head[j] = @ptrToInt(node.next[j]);
                                if (self.head[j] == @ptrToInt(@as(?*Node, null))) {
                                    self.tail[j] = @ptrToInt(@as(?*Node, null));
                                }
                            }
                        }
                    }

                    comptime var k = 0;

                    inline while (k < set_count) : (k += 1) {
                        if (k == i) continue;

                        if (set_bits & (1 << k) == 0) continue;

                        if (self.head[k] == @ptrToInt(@as(?*Node, null))) {
                            self.head[k] = IS_READY;
                        }
                    }

                    return node_ptr;
                }
            }

            comptime var l = 0;

            inline while (l < set_count) : (l += 1) {
                if (set_bits & (1 << l) == 0) continue;

                if (self.head[l] == @ptrToInt(@as(?*Node, null))) {
                    self.head[l] = IS_READY;
                }
            }

            return null;
        }
    };
}

const testing = std.testing;

test "Waker.wait() / Waker.set()" {
    const S = Waker(Event);

    var signal = S{};

    var A = async signal.wait(.{ .terminate = true, .quit = true });
    var B = async signal.wait(.{ .terminate = true, .hup = true });

    testing.expect(signal.head[0] != @ptrToInt(@as(?*S.Node, null)));
    testing.expect(signal.head[1] == @ptrToInt(@as(?*S.Node, null)));
    testing.expect(signal.head[2] != @ptrToInt(@as(?*S.Node, null)));
    testing.expect(signal.head[3] != @ptrToInt(@as(?*S.Node, null)));

    var A_node = signal.set(.{ .terminate = true }) orelse unreachable;
    resume A_node.frame;

    testing.expect(signal.head[0] != @ptrToInt(@as(?*S.Node, null)));
    testing.expect(signal.head[1] == @ptrToInt(@as(?*S.Node, null)));
    testing.expect(signal.head[2] == @ptrToInt(@as(?*S.Node, null)));
    testing.expect(signal.head[3] != @ptrToInt(@as(?*S.Node, null)));

    var B_node = signal.set(.{ .terminate = true }) orelse unreachable;
    resume B_node.frame;

    testing.expect(signal.head[0] == @ptrToInt(@as(?*S.Node, null)));
    testing.expect(signal.head[1] == @ptrToInt(@as(?*S.Node, null)));
    testing.expect(signal.head[2] == @ptrToInt(@as(?*S.Node, null)));
    testing.expect(signal.head[3] == @ptrToInt(@as(?*S.Node, null)));

    nosuspend await A;
    nosuspend await B;
}
