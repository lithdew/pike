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
        const handle = try os.kqueue();

        var changelist: [4]os.Kevent = [_]os.Kevent{.{
            .ident = undefined,
            .filter = os.EVFILT_SIGNAL,
            .flags = os.EV_ADD,
            .fflags = 0,
            .data = 0,
            .udata = undefined,
        }} ** 4;

        var set = mem.zeroes(os.sigset_t);
        var count: usize = 0;

        if (signal.terminate) {
            system.sigaddset(&set, os.SIGTERM);
            changelist[count].ident = os.SIGTERM;
            count += 1;
        }

        if (signal.interrupt) {
            system.sigaddset(&set, os.SIGINT);
            changelist[count].ident = os.SIGINT;
            count += 1;
        }

        if (signal.quit) {
            system.sigaddset(&set, os.SIGQUIT);
            changelist[count].ident = os.SIGQUIT;
            count += 1;
        }

        if (signal.hup) {
            system.sigaddset(&set, os.SIGHUP);
            changelist[count].ident = os.SIGHUP;
            count += 1;
        }

        var prev = mem.zeroes(os.sigset_t);

        try posix.sigprocmask(os.SIG_BLOCK, &set, &prev);
        errdefer posix.sigprocmask(os.SIG_SETMASK, &prev, null) catch {};

        if ((try os.kevent(handle, changelist[0..count], &[0]os.Kevent{}, null)) != 0) {
            return error.Unexpected;
        }

        return Self{
            .handle = .{
                .inner = handle,
                .wake_fn = wake,
            },
            .prev = prev,
        };
    }

    pub fn deinit(self: *Self) void {
        os.close(self.handle.inner);
        posix.sigprocmask(os.SIG_SETMASK, &self.prev, null) catch {};

        var head: ?*Waker.Node = null;

        const held = self.lock.acquire();
        while (self.readers.wake()) |node| {
            node.next = head;
            node.prev = null;
            head = node;
        }
        held.release();

        while (head) |node| : (head = node.next) {
            pike.dispatch(&node.data);
        }
    }

    pub fn registerTo(self: *const Self, notifier: *const pike.Notifier) !void {
        try notifier.register(&self.handle, .{ .read = true });
    }

    inline fn wake(handle: *pike.Handle, opts: pike.WakeOptions) void {
        const self = @fieldParentPtr(Self, "handle", handle);

        if (opts.write_ready) @panic("pike/signal (linux): kqueue unexpectedly reported write-readiness");

        const held = self.lock.acquire();
        const read_node = if (opts.read_ready) self.readers.wake() else null;
        held.release();

        if (read_node) |node| pike.dispatch(&node.data);
    }

    pub fn wait(self: *Self) callconv(.Async) !void {
        var events: [1]os.Kevent = undefined;

        while (true) {
            const num_events = try os.kevent(
                self.handle.inner,
                &[0]os.Kevent{},
                &events,
                &os.timespec{ .tv_sec = 0, .tv_nsec = 0 },
            );

            switch (num_events) {
                0 => {
                    self.readers.wait(&self.lock);
                    continue;
                },
                1 => {
                    const held = self.lock.acquire();
                    const read_node = self.readers.next();
                    held.release();

                    if (read_node) |node| pike.dispatch(&node.data);
                },
                else => return error.ShortRead,
            }
        }
    }
};
