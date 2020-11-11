const std = @import("std");
const epoll = @import("epoll.zig");

pub const PollOptions = packed struct {
    read: bool = false,
    write: bool = false,
};

pub const CallOptions = packed struct {
    read: bool = false,
    write: bool = false,
};

pub const Handle = struct {};

pub const Notifier = struct {
    inner: usize,
    vtable: struct {
        register: fn (self: usize, handle: *const Handle, comptime opts: PollOptions) anyerror!void,
        poll: fn (self: usize, timeout: i32) anyerror!void,
    },

    pub fn from(inner: anytype) Notifier {
        const Impl = meta.Child(@TypeOf(inner));

        return .{
            .inner = inner,
            .vtable = .{
                .register = @ptrCast(fn (self: usize, handle: *const Handle, comptime opts: PollOptions) anyerror!void, Impl.register),
                .poll = @ptrCast(fn (self: usize, timeout: i32) anyerror!void, Impl.poll),
            },
        };
    }

    pub inline fn register(handle: *const Handle, comptime opts: PollOptions) !void {
        return self.vtable.register(self.inner, handle, opts);
    }

    pub inline fn poll(timeout: i32) !void {
        return self.vtable.poll(timeout);
    }
};
