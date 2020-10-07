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
        .kqueue => M: {
            var m = mem.zeroes(os.sigset_t);
            if (mask.terminate) os.darwin.sigaddset(&m, os.SIGTERM);
            if (mask.interrupt) os.darwin.sigaddset(&m, os.SIGINT);
            if (mask.quit) os.darwin.sigaddset(&m, os.SIGQUIT);
            if (mask.hup) os.darwin.sigaddset(&m, os.SIGHUP);
            assert(os.darwin.sigprocmask(os.SIG_BLOCK, &m, null) == 0);

            var handle = try os.kqueue();

            var changelist: [5]os.Kevent = [1]os.Kevent{.{
                .ident = undefined,
                .filter = os.EVFILT_SIGNAL,
                .flags = os.EV_ADD,
                .fflags = 0,
                .data = 0,
                .udata = undefined,
            }} ** 5;

            comptime var changelist_len = 0;

            comptime if (mask.terminate) {
                changelist[changelist_len].ident = os.SIGTERM;
                changelist_len += 1;
            };

            comptime if (mask.interrupt) {
                changelist[changelist_len].ident = os.SIGINT;
                changelist_len += 1;
            };

            comptime if (mask.quit) {
                changelist[changelist_len].ident = os.SIGQUIT;
                changelist_len += 1;
            };

            comptime if (mask.hup) {
                changelist[changelist_len].ident = os.SIGHUP;
                changelist_len += 1;
            };

            assert((try os.kevent(handle, changelist[0..changelist_len], &[0]os.Kevent{}, null)) == 0);

            break :M handle;
        },
        else => @compileError("Unsupported OS"),
    };

    return Self{ .file = .{ .handle = handle, .driver = driver } };
}

pub fn wait(self: *Self) callconv(.Async) !void {
    switch (pike.driver_type) {
        .epoll => {
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
        },
        .kqueue => {
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
        },
        else => @compileError("Unsupported OS"),
    }
}
