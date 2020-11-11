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
    const Self = @This();

    inner: os.fd_t,

    pub fn init(handle: os.fd_t) Self {
        return Self{ .inner = handle };
    }

    pub fn deinit(self: *const Self) void {
        windows.closesocket(@ptrCast(ws2_32.SOCKET, self.inner)) catch {};
    }
};

pub const Notifier = struct {
    const Self = @This();

    const Overlapped = struct {
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

    pub fn call(handle: *Handle, comptime function: anytype, raw_args: anytype, comptime opts: pike.CallOptions) callconv(.Async) !Overlapped {
        var overlapped = Overlapped.init(@frame());
        var args = raw_args;

        comptime var i = 0;
        inline while (i < args.len) : (i += 1) {
            if (comptime @TypeOf(args[i]) == *windows.OVERLAPPED) {
                args[i] = &overlapped.inner;
            }
        }

        @call(.{ .modifier = .always_inline }, function, args) catch |err| switch (err) {
            error.WouldBlock => {
                suspend;
            },
            else => return err,
        };

        return overlapped;
    }
};
