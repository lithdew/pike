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

        while (self.readers.wake(&self.lock)) |frame| pike.dispatch(pike.scope, frame);
        while (self.writers.wake(&self.lock)) |frame| pike.dispatch(pike.scope, frame);
    }

    pub fn registerTo(self: *const Self, notifier: *const pike.Notifier) !void {
        try notifier.register(&self.handle, .{ .read = true, .write = true });
    }

    inline fn wake(handle: *pike.Handle, opts: pike.WakeOptions) void {
        const self = @fieldParentPtr(Self, "handle", handle);
        if (opts.read_ready) if (self.readers.wake(&self.lock)) |frame| pike.dispatch(pike.scope, frame);
        if (opts.write_ready) if (self.writers.wake(&self.lock)) |frame| pike.dispatch(pike.scope, frame);
    }

    fn write(self: *Self, amount: u64) callconv(.Async) !void {
        defer if (self.writers.next(&self.lock)) |frame| pike.dispatch(pike.scope, frame);

        while (true) {
            const num_bytes = os.write(self.handle.inner, mem.asBytes(&amount)) catch |err| switch (err) {
                error.WouldBlock => {
                    self.writers.wait(&self.lock);
                    continue;
                },
                else => return err,
            };

            if (num_bytes != @sizeOf(@TypeOf(amount))) {
                return error.ShortWrite;
            }

            return;
        }
    }

    fn read(self: *Self) callconv(.Async) !void {
        defer if (self.writers.next(&self.lock)) |frame| pike.dispatch(pike.scope, frame);

        var counter: u64 = 0;

        while (true) {
            const num_bytes = os.read(self.handle.inner, mem.asBytes(&counter)) catch |err| switch (err) {
                error.WouldBlock => {
                    self.readers.wait(&self.lock);
                    continue;
                },
                else => return err,
            };

            if (num_bytes != @sizeOf(@TypeOf(counter))) {
                return error.ShortRead;
            }

            return;
        }
    }

    pub fn post(self: *Self) callconv(.Async) !void {
        try self.write(1);
        try self.read();
    }
};
