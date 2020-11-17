const std = @import("std");
const pike = @import("pike.zig");
const posix = @import("os/posix.zig");

const os = std.os;
const linux = os.linux;

const mem = std.mem;

usingnamespace @import("waker.zig");

pub const SignalType = packed struct {
    terminate: bool = false,
    interrupt: bool = false,
    quit: bool = false,
    hup: bool = false,
};

pub const Signal = struct {
    const Self = @This();

    handle: pike.Handle,
    readers: Waker = .{},

    prev: os.sigset_t,

    pub fn init(signal: SignalType) !Self {
        var set = mem.zeroes(os.sigset_t);
        if (signal.terminate) linux.sigaddset(&set, os.SIGTERM);
        if (signal.interrupt) linux.sigaddset(&set, os.SIGINT);
        if (signal.quit) linux.sigaddset(&set, os.SIGQUIT);
        if (signal.hup) linux.sigaddset(&set, os.SIGHUP);

        var prev = mem.zeroes(os.sigset_t);

        try posix.sigprocmask(os.SIG_BLOCK, &set, &prev);
        errdefer posix.sigprocmask(os.SIG_SETMASK, &prev, null) catch {};

        return Self{
            .handle = .{
                .inner = try os.signalfd(-1, &set, os.O_NONBLOCK | os.O_CLOEXEC),
                .wake_fn = wake,
            },
            .prev = prev,
        };
    }

    pub fn deinit(self: *Self) void {
        os.close(self.handle.inner);
        posix.sigprocmask(os.SIG_SETMASK, &self.prev, null) catch {};

        if (self.readers.shutdown()) |task| pike.dispatch(task, .{});
        while (true) self.readers.wait() catch break;
    }

    pub fn registerTo(self: *const Self, notifier: *const pike.Notifier) !void {
        try notifier.register(&self.handle, .{ .read = true });
    }

    inline fn wake(handle: *pike.Handle, opts: pike.WakeOptions) void {
        const self = @fieldParentPtr(Self, "handle", handle);

        if (opts.write_ready) @panic("pike/signal (linux): signalfd unexpectedly reported write-readiness");
        if (opts.read_ready) if (self.readers.notify()) |task| pike.dispatch(task, .{});
        if (opts.shutdown) if (self.readers.shutdown()) |task| pike.dispatch(task, .{});
    }

    pub fn wait(self: *Self) callconv(.Async) !void {
        var info: os.signalfd_siginfo = undefined;

        while (true) {
            const num_bytes = os.read(self.handle.inner, mem.asBytes(&info)) catch |err| switch (err) {
                error.WouldBlock => {
                    try self.readers.wait();
                    continue;
                },
                else => return err,
            };
            if (num_bytes != @sizeOf(@TypeOf(info))) {
                return error.ShortRead;
            }

            return;
        }
    }
};
