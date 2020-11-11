const std = @import("std");
const pike = @import("pike.zig");
const posix = @import("os/posix.zig");

const os = std.os;
const net = std.net;
const mem = std.mem;
const time = std.time;

usingnamespace @import("waker.zig");

pub inline fn init() !void {}
pub inline fn deinit() void {}

pub const Handle = struct {
    const Self = @This();

    inner: os.fd_t,

    lock: std.Mutex = .{},
    readers: Waker = .{},
    writers: Waker = .{},

    pub fn init(inner: os.fd_t) Self {
        return Self{ .inner = inner };
    }

    pub fn deinit(self: *const Self) void {
        os.close(self.inner);
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

        const num_events = try os.kevent(self.handle, changelist[0..changelist_len], &[0]os.Kevent{}, null);
    }

    pub fn poll(self: *const Self, timeout: i32) !void {
        var events: [1024]os.Kevent = undefined;

        const timeout_spec = os.timespec{
            .tv_sec = @divTrunc(timeout, time.ms_per_s),
            .tv_nsec = @rem(timeout, time.ms_per_s) * time.ns_per_ms,
        };

        const num_events = try os.kevent(self.handle, &[0]os.Kevent{}, events[0..], &timeout_spec);

        for (events[0..num_events]) |e| {
            const err = e.flags & os.EV_ERROR != 0;
            const eof = e.flags & os.EV_EOF != 0;

            const readable = (err or eof) or e.filter == os.EVFILT_READ;
            const writable = (err or eof) or e.filter == os.EVFILT_WRITE;

            const read_ready = (err or eof) or readable;
            const write_ready = (err or eof) or writable;

            const handle = @intToPtr(*Handle, e.udata);

            if (read_ready) if (handle.readers.wake(&handle.lock)) |frame| resume frame;
            if (write_ready) if (handle.writers.wake(&handle.lock)) |frame| resume frame;
        }
    }

    pub fn call(handle: *Handle, comptime function: anytype, args: anytype, comptime opts: pike.CallOptions) callconv(.Async) @typeInfo(@TypeOf(function)).Fn.return_type.? {
        defer if (comptime opts.read) if (handle.readers.next(&handle.lock)) |frame| resume frame;
        defer if (comptime opts.write) if (handle.writers.next(&handle.lock)) |frame| resume frame;

        while (true) {
            const result = @call(.{ .modifier = .always_inline }, function, args) catch |err| switch (err) {
                error.WouldBlock => {
                    if (comptime opts.read) handle.readers.wait(&handle.lock);
                    if (comptime opts.write) handle.writers.wait(&handle.lock);
                    continue;
                },
                else => return err,
            };

            return result;
        }
    }
};
