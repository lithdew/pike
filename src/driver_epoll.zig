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

pub fn register(self: *Self, file: *pike.File, comptime event: pike.Event) !void {
    var ev: os.epoll_event = .{ .events = os.EPOLLET, .data = .{ .ptr = @ptrToInt(file) } };
    if (event.read) ev.events |= os.EPOLLIN;
    if (event.write) ev.events |= os.EPOLLOUT;

    try os.epoll_ctl(self.handle, os.EPOLL_CTL_ADD, file.handle, &ev);
}

pub fn poll(self: *Self, timeout: i32) !void {
    var events: [1024]os.epoll_event = undefined;

    const num_events = os.epoll_wait(self.handle, &events, @divTrunc(timeout, time.ns_per_ms));

    for (events[0..num_events]) |e, i| {
        const file = @intToPtr(*pike.File, e.data.ptr);

        if (e.events & os.EPOLLERR != 0 or e.events & os.EPOLLHUP != 0) {
            if (file.waker.set(.{ .read = true })) |node| {
                file.schedule(file, node.frame);
            }

            if (file.waker.set(.{ .write = true })) |node| {
                file.schedule(file, node.frame);
            }
        } else if (e.events & os.EPOLLIN != 0) {
            if (file.waker.set(.{ .read = true })) |node| {
                file.schedule(file, node.frame);
            }
        } else if (e.events & os.EPOLLOUT != 0) {
            if (file.waker.set(.{ .write = true })) |node| {
                file.schedule(file, node.frame);
            }
        }
    }
}
