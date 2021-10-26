const std = @import("std");
const pike = @import("pike.zig");
const Waker = @import("waker.zig").Waker;
const os = std.os;
const mem = std.mem;

pub const Event = struct {
    const Self = @This();

    handle: pike.Handle,
    readers: Waker = .{},
    writers: Waker = .{},

    pub fn init() !Self {
        return Self{
            .handle = .{
                .inner = try os.eventfd(0, os.linux.EFD.CLOEXEC | os.linux.EFD.NONBLOCK),
                .wake_fn = wake,
            },
        };
    }

    pub fn deinit(self: *Self) void {
        os.close(self.handle.inner);

        if (self.writers.shutdown()) |task| pike.dispatch(task, .{});
        if (self.readers.shutdown()) |task| pike.dispatch(task, .{});
    }

    pub fn registerTo(self: *const Self, notifier: *const pike.Notifier) !void {
        try notifier.register(&self.handle, .{ .read = true, .write = true });
    }

    fn wake(handle: *pike.Handle, batch: *pike.Batch, opts: pike.WakeOptions) void {
        const self = @fieldParentPtr(Self, "handle", handle);

        if (opts.write_ready) if (self.writers.notify()) |task| batch.push(task);
        if (opts.read_ready) if (self.readers.notify()) |task| batch.push(task);
        if (opts.shutdown) {
            if (self.writers.shutdown()) |task| batch.push(task);
            if (self.readers.shutdown()) |task| batch.push(task);
        }
    }

    fn ErrorUnionOf(comptime func: anytype) std.builtin.TypeInfo.ErrorUnion {
        return @typeInfo(@typeInfo(@TypeOf(func)).Fn.return_type.?).ErrorUnion;
    }

    fn call(self: *Self, comptime function: anytype, args: anytype, comptime opts: pike.CallOptions) !ErrorUnionOf(function).payload {
        while (true) {
            const result = @call(.{ .modifier = .always_inline }, function, args) catch |err| switch (err) {
                error.WouldBlock => {
                    if (comptime opts.write) {
                        try self.writers.wait(.{ .use_lifo = true });
                    } else if (comptime opts.read) {
                        try self.readers.wait(.{});
                    }
                    continue;
                },
                else => return err,
            };

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
        var frame = async self.read();
        try self.write(1);
        try await frame;
    }
};
