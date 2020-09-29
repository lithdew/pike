const std = @import("std");
const os = std.os;
const mem = std.mem;

const pike = @import("pike.zig");

const assert = std.debug.assert;

pub const Mask = packed struct {
    terminate: bool = false,
    interrupt: bool = false,
    quit: bool = false,
    hup: bool = false,
};

const Self = @This();

file: pike.File,

pub usingnamespace pike.Handle(Self);

pub fn init(driver: *pike.Driver, comptime mask: Mask) !Self {
    const handle = switch (pike.driver_type) {
        .epoll => M: {
            var m = mem.zeroes(os.sigset_t);
            if (mask.terminate) os.linux.sigaddset(&m, os.SIGTERM);
            if (mask.interrupt) os.linux.sigaddset(&m, os.SIGINT);
            if (mask.quit) os.linux.sigaddset(&m, os.SIGQUIT);
            if (mask.hup) os.linux.sigaddset(&m, os.SIGHUP);
            assert(os.linux.sigprocmask(os.SIG_BLOCK, &m, null) == 0);

            break :M try os.signalfd(-1, &m, 0);
        },
        else => @compileError("Unsupported OS"),
    };

    return Self{ .file = .{ .handle = handle, .driver = driver } };
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

        self.file.schedule(.{ .read = true });

        if (n != buf.len) return error.ShortRead;

        return;
    }
}
