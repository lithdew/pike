const std = @import("std");
const pike = @import("pike.zig");
const posix = @import("os/posix.zig");

const os = std.os;
const system = os.system;

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
    prev: os.sigset_t,

    lock: std.Mutex = .{},
    readers: Waker = .{},

    pub fn init(signal: SignalType) !Self {
        var set = mem.zeroes(os.sigset_t);
        if (signal.terminate) system.sigaddset(&set, os.SIGTERM);
        if (signal.interrupt) system.sigaddset(&set, os.SIGINT);
        if (signal.quit) system.sigaddset(&set, os.SIGQUIT);
        if (signal.hup) system.sigaddset(&set, os.SIGHUP);

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

    pub fn deinit(self: *const Self) void {
        os.close(self.handle.inner);
        posix.sigprocmask(os.SIG_SETMASK, &self.prev, null) catch {};
    }

    fn wake(handle: *pike.Handle, opts: pike.WakeOptions) void {
        const self = @fieldParentPtr(Self, "handle", handle);
        if (opts.read_ready) if (self.readers.wake(&self.lock)) |frame| resume frame;
        if (opts.write_ready) @panic("pike/signal (linux): signalfd unexpectedly reported write-readiness");
    }

    pub fn wait(self: *Self) callconv(.Async) !void {
        defer if (self.readers.next(&self.lock)) |frame| resume frame;

        var info: os.signalfd_siginfo = undefined;

        while (true) {
            const num_bytes = os.read(self.handle.inner, mem.asBytes(&info)) catch |err| switch (err) {
                error.WouldBlock => {
                    self.readers.wait(&self.lock);
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
