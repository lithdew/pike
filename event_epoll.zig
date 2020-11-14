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

        var buf: [128]anyframe = undefined;
        var len: usize = 0;

        const held = self.lock.acquire();
        while (self.readers.wake()) |frame| : (len += 1) {
            if (len == @sizeOf(@TypeOf(buf))) break;
            buf[len] = frame;
        }
        while (self.writers.wake()) |frame| : (len += 1) {
            if (len == @sizeOf(@TypeOf(buf))) break;
            buf[len] = frame;
        }
        held.release();

        for (buf[0..len]) |frame| pike.dispatch(pike.scope, frame);
    }

    pub fn registerTo(self: *const Self, notifier: *const pike.Notifier) !void {
        try notifier.register(&self.handle, .{ .read = true, .write = true });
    }

    inline fn wake(handle: *pike.Handle, opts: pike.WakeOptions) void {
        const self = @fieldParentPtr(Self, "handle", handle);

        const held = self.lock.acquire();
        const read_frame = if (opts.read_ready) self.readers.wake() else null;
        const write_frame = if (opts.write_ready) self.writers.wake() else null;
        held.release();

        if (read_frame) |frame| pike.dispatch(pike.scope, frame);
        if (write_frame) |frame| pike.dispatch(pike.scope, frame);
    }

    fn write(self: *Self, amount: u64) callconv(.Async) !void {
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

            const held = self.lock.acquire();
            const write_frame = self.writers.next();
            held.release();

            if (write_frame) |frame| pike.dispatch(pike.scope, frame);

            return;
        }
    }

    fn read(self: *Self) callconv(.Async) !void {
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

            const held = self.lock.acquire();
            const read_frame = self.readers.next();
            held.release();

            if (read_frame) |frame| pike.dispatch(pike.scope, frame);

            return;
        }
    }

    pub fn post(self: *Self) callconv(.Async) !void {
        try self.write(1);
        try self.read();
    }
};
