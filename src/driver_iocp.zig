const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const windows = os.windows;
const ws2_32 = windows.ws2_32;

const mem = std.mem;
const math = std.math;
const builtin = std.builtin;

const assert = std.debug.assert;

const Self = @This();

executor: pike.Executor,
handle: os.fd_t = windows.INVALID_HANDLE_VALUE,
afd: os.fd_t = windows.INVALID_HANDLE_VALUE,

pub fn init(opts: pike.DriverOptions) !Self {
    const handle = try windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, undefined, math.maxInt(windows.DWORD));
    errdefer os.close(handle);

    const afd = try pike.os.createAFD("Pike");
    errdefer os.close(afd);

    const afd_port = try windows.CreateIoCompletionPort(afd, handle, 0, 0);

    try pike.os.SetFileCompletionNotificationModes(afd, pike.os.FILE_SKIP_SET_EVENT_ON_HANDLE);

    return Self{ .executor = opts.executor, .handle = handle, .afd = afd };
}

pub fn deinit(self: *Self) void {
    os.close(self.afd);
    os.close(self.handle);
}

pub fn register(self: *Self, handle: *pike.Handle, comptime event: pike.Event) !void {
    // This function does nothing on Windows.
}

pub fn poll(self: *Self, timeout: i32) !void {
    var events: [1024]pike.os.OVERLAPPED_ENTRY = undefined;

    const num_events = pike.os.GetQueuedCompletionStatusEx(self.handle, &events, @intCast(windows.DWORD, timeout), false) catch |err| switch (err) {
        error.Timeout => return,
        else => return err,
    };

    for (events[0..num_events]) |e, i| {
        const handle = pike.Handle.fromOverlapped(e.lpOverlapped);

        if (handle.waker.data.pending.read) {
            handle.trigger(.{ .read = true });
        }
        if (handle.waker.data.pending.write) {
            handle.trigger(.{ .write = true });
        }
    }
}
