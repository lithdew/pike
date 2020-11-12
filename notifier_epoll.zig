const std = @import("std");
const pike = @import("pike.zig");
const posix = @import("os/posix.zig");

const os = std.os;
const net = std.net;
const mem = std.mem;

usingnamespace @import("waker.zig");

pub inline fn init() !void {}
pub inline fn deinit() void {}

pub const Handle = struct {
    inner: os.fd_t,
    wake_fn: fn (self: *Handle, opts: pike.WakeOptions) void,

    pub inline fn wake(self: *Handle, opts: pike.WakeOptions) void {
        self.wake_fn(self, opts);
    }
};

pub const Notifier = struct {
    const Self = @This();

    handle: i32,

    pub fn init() !Self {
        const handle = try os.epoll_create1(os.EPOLL_CLOEXEC);
        errdefer os.close(handle);

        return Self{ .handle = handle };
    }

    pub fn deinit(self: *const Self) void {
        os.close(self.handle);
    }

    pub fn register(self: *const Self, handle: *const Handle, comptime opts: pike.PollOptions) !void {
        if (handle.inner == -1) return;

        var events: u32 = os.EPOLLET;
        if (opts.read) events |= os.EPOLLIN;
        if (opts.write) events |= os.EPOLLOUT;

        try os.epoll_ctl(self.handle, os.EPOLL_CTL_ADD, handle.inner, &os.epoll_event{
            .events = events,
            .data = .{ .ptr = @ptrToInt(handle) },
        });
    }

    pub fn poll(self: *const Self, timeout: i32) !void {
        var events: [128]os.epoll_event = undefined;

        const num_events = os.epoll_wait(self.handle, &events, timeout);
        for (events[0..num_events]) |e| {
            if (e.data.ptr == 0) continue;

            const handle = @intToPtr(*Handle, e.data.ptr);

            const read_ready = (e.events & os.EPOLLERR != 0 or e.events & os.EPOLLHUP != 0) or e.events & os.EPOLLIN != 0;
            const write_ready = (e.events & os.EPOLLERR != 0 or e.events & os.EPOLLHUP != 0) or e.events & os.EPOLLOUT != 0;

            handle.wake(.{ .read_ready = read_ready, .write_ready = write_ready });
        }
    }
};
