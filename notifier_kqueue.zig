const std = @import("std");
const pike = @import("pike.zig");
const posix = @import("os/posix.zig");

const os = std.os;
const net = std.net;
const mem = std.mem;
const time = std.time;

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

    handle: os.fd_t,

    pub fn init() !Self {
        const handle = try os.kqueue();
        errdefer os.close(handle);

        return Self{ .handle = handle };
    }

    pub fn deinit(self: *const Self) void {
        os.close(self.handle);
    }

    pub fn register(self: *const Self, handle: *const Handle, comptime opts: pike.PollOptions) !void {
        if (handle.inner == -1) return;

        var changelist = [_]os.Kevent{
            .{
                .ident = undefined,
                .filter = undefined,
                .flags = os.EV_ADD | os.EV_CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = undefined,
            },
        } ** 2;

        comptime var changelist_len = 0;

        comptime {
            if (opts.read) {
                changelist[changelist_len].filter = os.EVFILT_READ;
                changelist_len += 1;
            }

            if (opts.write) {
                changelist[changelist_len].filter = os.EVFILT_WRITE;
                changelist_len += 1;
            }
        }

        for (changelist[0..changelist_len]) |*event| {
            event.ident = @intCast(usize, handle.inner);
            event.udata = @ptrToInt(handle);
        }

        _ = try os.kevent(self.handle, changelist[0..changelist_len], &[0]os.Kevent{}, null);
    }

    pub fn poll(self: *const Self, timeout: i32) !void {
        var events: [128]os.Kevent = undefined;

        var batch: pike.Batch = .{};
        defer pike.dispatch(batch, .{});

        const timeout_spec = os.timespec{
            .tv_sec = @divTrunc(timeout, time.ms_per_s),
            .tv_nsec = @rem(timeout, time.ms_per_s) * time.ns_per_ms,
        };

        const num_events = try os.kevent(self.handle, &[0]os.Kevent{}, events[0..], &timeout_spec);

        for (events[0..num_events]) |e| {
            const handle = @intToPtr(*Handle, e.udata);

            const notify = e.filter == os.EVFILT_USER;
            const shutdown = e.flags & (os.EV_ERROR | os.EV_EOF) != 0;
            const read_ready = e.filter == os.EVFILT_READ;
            const write_ready = e.filter == os.EVFILT_WRITE;

            handle.wake(&batch, .{
                .notify = notify,
                .shutdown = shutdown,
                .read_ready = read_ready,
                .write_ready = write_ready,
            });
        }
    }
};
