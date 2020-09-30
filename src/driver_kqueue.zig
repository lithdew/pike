const std = @import("std");
const os = std.os;
const time = std.time;

const pike = @import("pike.zig");

const assert = std.debug.assert;

const Self = @This();

executor: pike.Executor,
handle: os.fd_t = -1,

pub fn init(opts: pike.DriverOptions) !Self {
    const handle = try os.kqueue();
    errdefer os.close(handle);

    return Self{ .executor = opts.executor, .handle = handle };
}

pub fn deinit(self: *Self) void {
    os.close(self.handle);
    self.* = undefined;
}

pub fn register(self: *Self, file: *pike.File, comptime event: pike.Event) !void {
    var changelist: [2]os.Kevent = [1]os.Kevent{.{
        .ident = undefined,
        .filter = undefined,
        .flags = os.EV_ADD | os.EV_CLEAR,
        .fflags = 0,
        .data = 0,
        .udata = undefined,
    }} ** 2;
    comptime var changelist_len = 0;

    comptime if (event.read) {
        changelist[changelist_len].filter = os.EVFILT_READ;
        changelist_len += 1;
    };

    comptime if (event.write) {
        changelist[changelist_len].filter = os.EVFILT_WRITE;
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

    const timeout_spec = os.timespec{
        .tv_sec = @divTrunc(timeout, time.ms_per_s),
        .tv_nsec = @rem(timeout, time.ms_per_s) * time.ns_per_ms,
    };

    const num_events = try os.kevent(self.handle, &[0]os.Kevent{}, &events, &timeout_spec);

    for (events[0..num_events]) |e, i| {
        const file = @intToPtr(*pike.File, e.udata);

        if (e.flags & os.EV_ERROR != 0 or e.flags & os.EV_EOF != 0) {
            file.trigger(.{ .read = true });
            file.trigger(.{ .write = true });
        } else if (e.filter == os.EVFILT_READ) {
            file.trigger(.{ .read = true });
        } else if (e.filter == os.EVFILT_WRITE) {
            file.trigger(.{ .write = true });
        }
    }
}
