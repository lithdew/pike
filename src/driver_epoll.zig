const std = @import("std");
const os = std.os;
const time = std.time;

const pike = @import("pike.zig");

const Self = @This();

handle: os.fd_t = -1,

pub fn init(self: *Self) !void {
    const handle = try os.epoll_create1(os.EPOLL_CLOEXEC);
    errdefer os.close(handle);

    self.* = .{ .handle = handle };
}

pub fn deinit(self: *Self) void {
    os.close(self.handle);
    self.* = undefined;
}

pub fn register(self: *Self, file: *pike.File) !void {
    var ev: os.epoll_event = .{ .events = os.EPOLLET | os.EPOLLIN | os.EPOLLOUT, .data = .{ .ptr = @ptrToInt(file) } };

    try os.epoll_ctl(self.handle, os.EPOLL_CTL_ADD, file.handle, &ev);
}

pub fn poll(self: *Self, timeout: i32) !void {
    var events: [1024]os.epoll_event = undefined;

    const num_events = os.epoll_wait(self.handle, &events, @divTrunc(timeout, time.ns_per_ms));

    for (events[0..num_events]) |e, i| {
        const file = @intToPtr(*pike.File, e.data.ptr);

        if (e.events & os.EPOLLIN != 0) {
            if (file.waker.set(.Read)) |node| {
                resume node.frame;
            }
        }

        if (e.events & os.EPOLLOUT != 0) {
            if (file.waker.set(.Write)) |node| {
                resume node.frame;
            }
        }
    }
}
