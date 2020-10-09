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
    if (event.terminate) os.linux.sigaddset(&m, os.SIGTERM);
    if (event.interrupt) os.linux.sigaddset(&m, os.SIGINT);
    if (event.quit) os.linux.sigaddset(&m, os.SIGQUIT);
    if (event.hup) os.linux.sigaddset(&m, os.SIGHUP);
    assert(os.linux.sigprocmask(os.SIG_BLOCK, &m, null) == 0);

    const handle = try os.signalfd(-1, &m, 0);

    return Self{ .file = .{ .handle = handle, .driver = driver } };
}

pub fn deinit(self: *Self) void {
    self.file.close();
}

pub fn wait(self: *Self) callconv(.Async) !void {
    var buf: [@sizeOf(os.signalfd_siginfo)]u8 = undefined;
    while (true) {
        const n = os.read(self.file.handle, &buf) catch |err| switch (err) {
            error.WouldBlock => {
                self.file.waker.wait(.{ .read = true });
                continue;
            },
            else => return err,
        };

        if (n != buf.len) return error.ShortRead;

        self.file.schedule(.{ .read = true });

        return;
    }
}
