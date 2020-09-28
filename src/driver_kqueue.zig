const std = @import("std");
const os = std.os;

const pike = @import("pike.zig");

const assert = std.debug.assert;

const Self = @This();

handle: os.fd_t = -1,

pub fn init(self: *Self) !void {
    const handle = try os.kqueue();
    errdefer os.close(handle);

    self.* = .{ .handle = handle };
}

pub fn deinit(self: *Self) void {
    os.close(self.handle);
    self.* = undefined;
}

pub fn register(self: *Self, file: *pike.File) !void {
    const changelist = [2]os.Kevent{
        .{
            .ident = @intCast(usize, file.handle),
            .filter = os.EVFILT_READ,
            .flags = os.EV_ADD | os.EV_ENABLE | os.EV_CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = @ptrToInt(file),
        },
        .{
            .ident = @intCast(usize, file.handle),
            .filter = os.EVFILT_WRITE,
            .flags = os.EV_ADD | os.EV_ENABLE | os.EV_CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = @ptrToInt(file),
        },
    };

    assert((try os.kevent(self.handle, &changelist, &[0]os.Kevent{}, null)) == 0);
}

pub fn poll(self: *Self, timeout: i32) !void {
    var events: [1024]os.Kevent = undefined;

    const num_events = try os.kevent(self.handle, &[0]os.Kevent{}, &events, &os.timespec{ .tv_sec = 0, .tv_nsec = @intCast(c_long, timeout) });

    for (events[0..num_events]) |e, i| {
        const file = @intToPtr(*pike.File, e.udata);

        if (e.filter == os.EVFILT_READ) {
            if (file.waker.set(.Read)) |node| {
                resume node.frame;
            }
        }

        if (e.filter == os.EVFILT_WRITE) {
            if (file.waker.set(.Write)) |node| {
                resume node.frame;
            }
        }
    }
}
