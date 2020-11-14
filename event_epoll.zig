const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const mem = std.mem;

usingnamespace @import("waker.zig");

pub const Event = struct {
    const Self = @This();

    handle: pike.Handle,

    lock: std.Mutex = .{},
    readers: Waker = .{},
    writers: Waker = .{},

    pub fn init() !Self {
        return Self{
            .handle = .{
                .inner = try os.eventfd(0, os.EFD_CLOEXEC | os.EFD_NONBLOCK),
                .wake_fn = wake,
            },
        };
    }

    pub fn deinit(self: *Self) void {
        os.close(self.handle.inner);

        var head: ?*Waker.Node = null;

        const held = self.lock.acquire();
        while (self.readers.wake()) |node| {
            node.next = head;
            node.prev = null;
            head = node;
        }
        while (self.writers.wake()) |node| {
            node.next = head;
            node.prev = null;
            head = node;
        }
        held.release();

        while (head) |node| : (head = node.next) {
            pike.dispatch(pike.scope, node.data);
        }
    }

    pub fn registerTo(self: *const Self, notifier: *const pike.Notifier) !void {
        try notifier.register(&self.handle, .{ .read = true, .write = true });
    }

    inline fn wake(handle: *pike.Handle, opts: pike.WakeOptions) void {
        const self = @fieldParentPtr(Self, "handle", handle);

        const held = self.lock.acquire();
        const read_node = if (opts.read_ready) self.readers.wake() else null;
        const write_node = if (opts.write_ready) self.writers.wake() else null;
        held.release();

        if (read_node) |node| pike.dispatch(pike.scope, node.data);
        if (write_node) |node| pike.dispatch(pike.scope, node.data);
    }

    fn call(self: *Self, comptime function: anytype, args: anytype, comptime opts: pike.CallOptions) callconv(.Async) @typeInfo(@TypeOf(function)).Fn.return_type.? {
        while (true) {
            const result = @call(.{ .modifier = .always_inline }, function, args) catch |err| switch (err) {
                error.WouldBlock => {
                    if (comptime opts.read) self.readers.wait(&self.lock);
                    if (comptime opts.write) self.writers.wait(&self.lock);
                    continue;
                },
                else => return err,
            };

            const held = self.lock.acquire();
            const read_node = if (comptime opts.read) self.readers.next() else null;
            const write_node = if (comptime opts.write) self.writers.next() else null;
            held.release();

            if (read_node) |node| pike.dispatch(pike.scope, node.data);
            if (write_node) |node| pike.dispatch(pike.scope, node.data);

            return result;
        }
    }

    fn write(self: *Self, amount: u64) callconv(.Async) !void {
        const num_bytes = try self.call(os.write, .{
            self.handle.inner,
            mem.asBytes(&amount),
        }, .{ .write = true });

        if (num_bytes != @sizeOf(@TypeOf(amount))) {
            return error.ShortWrite;
        }
    }

    fn read(self: *Self) callconv(.Async) !void {
        var counter: u64 = 0;

        const num_bytes = try self.call(os.read, .{
            self.handle.inner,
            mem.asBytes(&counter),
        }, .{ .read = true });

        if (num_bytes != @sizeOf(@TypeOf(counter))) {
            return error.ShortRead;
        }
    }

    pub fn post(self: *Self) callconv(.Async) !void {
        try self.write(1);
        try self.read();
    }
};
