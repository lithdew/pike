const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const mem = std.mem;

usingnamespace @import("waker.zig");

pub const Event = struct {
    const Self = @This();

    inner: os.Kevent,
    notifier: os.fd_t,

    var count: u32 = 0;

    pub fn init() !Self {
        const ident = @atomicRmw(u32, &count, .Add, 1, .SeqCst);

        return Self{
            .inner = .{
                .ident = @intCast(usize, ident),
                .filter = os.EVFILT_USER,
                .flags = os.EV_ADD | os.EV_DISABLE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            },
            .notifier = -1,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = @atomicRmw(u32, &count, .Sub, 1, .SeqCst);

        self.inner.flags = os.EV_DELETE;
        self.inner.fflags = 0;

        if ((os.kevent(self.notifier, @as(*const [1]os.Kevent, &self.inner), &[0]os.Kevent{}, null) catch unreachable) != 0) {
            @panic("pike/event (darwin): unexpectedly registered new events while calling deinit()");
        }
    }

    pub fn registerTo(self: *Self, notifier: *const pike.Notifier) !void {
        self.notifier = notifier.handle;

        if ((try os.kevent(self.notifier, @as(*const [1]os.Kevent, &self.inner), &[0]os.Kevent{}, null)) != 0) {
            return error.Unexpected;
        }

        self.inner.flags = os.EV_ENABLE;
        self.inner.fflags = os.NOTE_TRIGGER;
    }

    pub fn post(self: *const Self) callconv(.Async) !void {
        if ((try os.kevent(self.notifier, @as(*const [1]os.Kevent, &self.inner), &[0]os.Kevent{}, null)) != 0) {
            return error.Unexpected;
        }
    }
};
