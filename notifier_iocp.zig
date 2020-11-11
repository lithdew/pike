const std = @import("std");
const pike = @import("pike.zig");
const windows = @import("os/windows.zig");
const ws2_32 = @import("os/windows/ws2_32.zig");

const os = std.os;
const net = std.net;
const math = std.math;

pub inline fn init() !void {
    const info = try windows.WSAStartup(2, 2);
}

pub inline fn deinit() void {
    windows.WSACleanup() catch unreachable;
}

pub const Handle = struct {
    inner: os.fd_t,
};

pub const Overlapped = struct {
    inner: windows.OVERLAPPED,
    frame: anyframe,

    pub fn init(frame: anyframe) Overlapped {
        return .{
            .inner = .{
                .Internal = 0,
                .InternalHigh = 0,
                .Offset = 0,
                .OffsetHigh = 0,
                .hEvent = null,
            },
            .frame = frame,
        };
    }
};

pub const Notifier = struct {
    const Self = @This();

    handle: os.fd_t,

    pub fn init() !Self {
        const handle = try windows.CreateIoCompletionPort(
            windows.INVALID_HANDLE_VALUE,
            null,
            undefined,
            math.maxInt(windows.DWORD),
        );
        errdefer windows.CloseHandle(handle);

        return Self{ .handle = handle };
    }

    pub fn deinit(self: *const Self) void {
        windows.CloseHandle(self.handle);
    }

    pub fn register(self: *const Self, handle: *const Handle, comptime opts: pike.PollOptions) !void {
        const port = try windows.CreateIoCompletionPort(handle.inner, self.handle, 0, 0);

        try windows.SetFileCompletionNotificationModes(
            handle.inner,
            windows.FILE_SKIP_SET_EVENT_ON_HANDLE | windows.FILE_SKIP_COMPLETION_PORT_ON_SUCCESS,
        );
    }

    pub fn poll(self: *const Self, timeout: i32) !void {
        var events: [1024]windows.OVERLAPPED_ENTRY = undefined;

        const num_events = try windows.GetQueuedCompletionStatusEx(self.handle, &events, @intCast(windows.DWORD, timeout), false);

        for (events[0..num_events]) |event| {
            resume @fieldParentPtr(Overlapped, "inner", event.lpOverlapped).frame;
        }
    }
};
