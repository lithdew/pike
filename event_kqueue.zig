const std = @import("std");
const pike = @import("pike.zig");
const Waker = @import("waker.zig").Waker;

const os = std.os;

pub const Event = struct {
    const Self = @This();

    handle: pike.Handle = .{
        .inner = -1,
        .wake_fn = wake,
    },
    waker: Waker = .{},

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

        if (self.waker.shutdown()) |task| pike.dispatch(task, .{});
    }

    pub fn registerTo(self: *Self, notifier: *const pike.Notifier) !void {
        self.notifier = notifier.handle;
        self.inner.udata = @ptrToInt(self);

        if ((try os.kevent(self.notifier, @as(*const [1]os.Kevent, &self.inner), &[0]os.Kevent{}, null)) != 0) {
            return error.Unexpected;
        }

        self.inner.flags = os.EV_ENABLE;
        self.inner.fflags = os.NOTE_TRIGGER;
    }

    inline fn wake(handle: *pike.Handle, batch: *pike.Batch, opts: pike.WakeOptions) void {
        const self = @fieldParentPtr(Self, "handle", handle);

        if (opts.write_ready) @panic("pike/event (darwin): kqueue unexpectedly reported write-readiness");
        if (opts.read_ready) @panic("pike/event (darwin): kqueue unexpectedly reported read-readiness");
        if (opts.notify) if (self.waker.notify()) |task| batch.push(task);
        if (opts.shutdown) if (self.waker.shutdown()) |task| batch.push(task);
    }

    pub fn post(self: *Self) callconv(.Async) !void {
        if ((try os.kevent(self.notifier, @as(*const [1]os.Kevent, &self.inner), &[0]os.Kevent{}, null)) != 0) {
            return error.Unexpected;
        }

        try self.waker.wait(.{});
    }
};
