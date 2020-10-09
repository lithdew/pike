const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const mem = std.mem;

const assert = std.debug.assert;

const Self = @This();

const Event = packed struct {
    terminate: bool = false,
    interrupt: bool = false,
    quit: bool = false,
    hup: bool = false,
};

file: pike.File,

pub fn init(driver: *pike.Driver, comptime event: Event) !Self {
    var m = mem.zeroes(os.sigset_t);
    if (event.terminate) os.darwin.sigaddset(&m, os.SIGTERM);
    if (event.interrupt) os.darwin.sigaddset(&m, os.SIGINT);
    if (event.quit) os.darwin.sigaddset(&m, os.SIGQUIT);
    if (event.hup) os.darwin.sigaddset(&m, os.SIGHUP);
    assert(os.darwin.sigprocmask(os.SIG_BLOCK, &m, null) == 0);

    const handle = try os.kqueue();

    var changelist: [4]os.Kevent = [1]os.Kevent{.{
        .ident = undefined,
        .filter = os.EVFILT_SIGNAL,
        .flags = os.EV_ADD,
        .fflags = 0,
        .data = 0,
        .udata = undefined,
    }} ** 4;

    comptime var changelist_len = 0;

    comptime if (event.terminate) {
        changelist[changelist_len].ident = os.SIGTERM;
        changelist_len += 1;
    };

    comptime if (event.interrupt) {
        changelist[changelist_len].ident = os.SIGINT;
        changelist_len += 1;
    };

    comptime if (event.quit) {
        changelist[changelist_len].ident = os.SIGQUIT;
        changelist_len += 1;
    };

    comptime if (event.hup) {
        changelist[changelist_len].ident = os.SIGHUP;
        changelist_len += 1;
    };

    assert((try os.kevent(handle, changelist[0..changelist_len], &[0]os.Kevent{}, null)) == 0);

    return Self{ .file = .{ .handle = handle, .driver = driver } };
}

pub fn deinit(self: *Self) void {
    self.file.close();
}

pub fn wait(self: *Self) callconv(.Async) !void {
    while (true) {
        var events: [1]os.Kevent = undefined;

        switch (try os.kevent(self.file.handle, &[0]os.Kevent{}, &events, &os.timespec{ .tv_sec = 0, .tv_nsec = 0 })) {
            0 => { // Wait for a signal to be received.
                self.file.waker.wait(.{ .read = true });
                continue;
            },
            1 => { // An expected signal was received.
                self.file.schedule(.{ .read = true });
                return;
            },
            else => { // An unexpected number of events was received.
                return error.ShortRead;
            },
        }
    }
}
