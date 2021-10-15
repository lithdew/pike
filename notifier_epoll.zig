const std = @import("std");
const pike = @import("pike.zig");
const posix = @import("os/posix.zig");

const os = std.os;
const net = std.net;
const mem = std.mem;

pub inline fn init() !void {}
pub inline fn deinit() void {}

pub const Handle = struct {
    inner: os.fd_t,
    wake_fn: fn (self: *Handle, batch: *pike.Batch, opts: pike.WakeOptions) void,

    pub inline fn wake(self: *Handle, batch: *pike.Batch, opts: pike.WakeOptions) void {
        self.wake_fn(self, batch, opts);
    }
};

pub const Notifier = struct {
    const Self = @This();

    handle: i32,

    pub fn init() !Self {
        const handle = try os.epoll_create1(os.linux.EPOLL.CLOEXEC);
        errdefer os.close(handle);

        return Self{ .handle = handle };
    }

    pub fn deinit(self: *const Self) void {
        os.close(self.handle);
    }

    pub fn register(self: *const Self, handle: *const Handle, comptime opts: pike.PollOptions) !void {
        if (handle.inner == -1) return;

        var events: u32 = os.linux.EPOLL.ET | os.linux.EPOLL.ERR | os.linux.EPOLL.RDHUP;
        if (opts.read) events |= os.linux.EPOLL.IN;
        if (opts.write) events |= os.linux.EPOLL.OUT;

        _ = os.linux.epoll_ctl(self.handle, os.linux.EPOLL.CTL_ADD, handle.inner, &os.linux.epoll_event{
            .events = events,
            .data = .{ .ptr = @ptrToInt(handle) },
        });
    }

    pub fn poll(self: *const Self, timeout: i32) !void {
        var events: [128]os.linux.epoll_event = undefined;

        var batch: pike.Batch = .{};
        defer pike.dispatch(batch, .{});

        const num_events = os.epoll_wait(self.handle, &events, timeout);
        for (events[0..num_events]) |e| {
            if (e.data.ptr == 0) continue;

            const handle = @intToPtr(*Handle, e.data.ptr);

            const shutdown = e.events & (os.linux.EPOLL.ERR | os.linux.EPOLL.RDHUP) != 0;
            const read_ready = e.events & os.linux.EPOLL.IN != 0;
            const write_ready = e.events & os.linux.EPOLL.OUT != 0;

            handle.wake(&batch, .{
                .shutdown = shutdown,
                .read_ready = read_ready,
                .write_ready = write_ready,
            });
        }
    }
};
