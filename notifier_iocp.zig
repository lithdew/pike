const std = @import("std");
const pike = @import("pike.zig");
const windows = @import("os/windows.zig");
const ws2_32 = @import("os/windows/ws2_32.zig");

const os = std.os;
const net = std.net;
const math = std.math;

pub inline fn init() !void {
    _ = try windows.WSAStartup(2, 2);
}

pub inline fn deinit() void {
    windows.WSACleanup() catch {};
}

pub const Handle = struct {
    inner: os.fd_t,
};

pub const Overlapped = struct {
    inner: windows.OVERLAPPED,
    task: pike.Task,

    pub fn init(task: pike.Task) Overlapped {
        return .{
            .inner = .{
                .Internal = 0,
                .InternalHigh = 0,
                .Offset = 0,
                .OffsetHigh = 0,
                .hEvent = null,
            },
            .task = task,
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

    pub fn register(self: *const Self, handle: *const Handle, comptime _: pike.PollOptions) !void {
        if (handle.inner == windows.INVALID_HANDLE_VALUE) return;

        _ = try windows.CreateIoCompletionPort(handle.inner, self.handle, 0, 0);

        try windows.SetFileCompletionNotificationModes(
            handle.inner,
            windows.FILE_SKIP_SET_EVENT_ON_HANDLE | windows.FILE_SKIP_COMPLETION_PORT_ON_SUCCESS,
        );
    }

    pub fn poll(self: *const Self, timeout: i32) !void {
        var events: [128]windows.OVERLAPPED_ENTRY = undefined;

        var batch: pike.Batch = .{};
        defer pike.dispatch(batch, .{});

        const num_events = windows.GetQueuedCompletionStatusEx(
            self.handle,
            &events,
            @intCast(windows.DWORD, timeout),
            false,
        ) catch |err| switch (err) {
            error.Timeout => return,
            else => return err,
        };

        for (events[0..num_events]) |event| {
            const overlapped = @fieldParentPtr(Overlapped, "inner", event.lpOverlapped orelse continue);
            batch.push(&overlapped.task);
        }
    }
};
