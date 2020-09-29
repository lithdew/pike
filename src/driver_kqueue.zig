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

pub fn register(self: *Self, file: *pike.File, comptime event: pike.Event) !void {
    var changelist: [2]os.Kevent = undefined;
    comptime var changelist_len = 0;

    comptime if (event.read) {
        changelist[changelist_len].filter = os.EVFILT_READ;
        changelist[changelist_len].flags = os.EV_ADD | os.EV_ENABLE | os.EV_CLEAR;
        changelist[changelist_len].fflags = 0;
        changelist[changelist_len].data = 0;
        changelist_len += 1;
    };

    comptime if (event.write) {
        changelist[changelist_len].filter = os.EVFILT_WRITE;
        changelist[changelist_len].flags = os.EV_ADD | os.EV_ENABLE | os.EV_CLEAR;
        changelist[changelist_len].fflags = 0;
        changelist[changelist_len].data = 0;
        changelist_len += 1;
    };

    for (changelist[0..changelist_len]) |*evt| {
        evt.ident = @intCast(usize, file.handle);
        evt.udata = @ptrToInt(file);
    }

    assert((try os.kevent(self.handle, changelist[0..changelist_len], &[0]os.Kevent{}, null)) == 0);
}

pub fn poll(self: *Self, timeout: i32) !void {
    var events: [1024]os.Kevent = undefined;

    const num_events = try os.kevent(self.handle, &[0]os.Kevent{}, &events, &os.timespec{ .tv_sec = 0, .tv_nsec = @intCast(c_long, timeout) });

    for (events[0..num_events]) |e, i| {
        const file = @intToPtr(*pike.File, e.udata);

        if (e.filter == os.EVFILT_READ) {
            if (file.waker.set(.{ .read = true })) |node| {
                resume node.frame;
            }
        }

        if (e.filter == os.EVFILT_WRITE) {
            if (file.waker.set(.{ .write = true })) |node| {
                resume node.frame;
            }
        }
    }
}
