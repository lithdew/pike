const std = @import("std");
const os = std.os;
const mem = std.mem;
const math = std.math;
const builtin = std.builtin;
const windows = os.windows;
const ws2_32 = windows.ws2_32;

const assert = std.debug.assert;

const pike = @import("pike.zig");

const Self = @This();

executor: pike.Executor,
handle: os.fd_t = windows.INVALID_HANDLE_VALUE,
afd: os.fd_t = windows.INVALID_HANDLE_VALUE,

fn createAFD() !os.fd_t {
    const NAME = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\GLOBALROOT\\Device\\Afd\\Pike");

    const handle = windows.kernel32.CreateFileW(
        NAME[0..],
        windows.SYNCHRONIZE,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_FLAG_OVERLAPPED,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }

    return handle;
}

pub fn getUnderlyingSocket(socket: ws2_32.SOCKET, ioctl: windows.DWORD) !ws2_32.SOCKET {
    var result: [@sizeOf(ws2_32.SOCKET)]u8 = undefined;
    _ = try windows.WSAIoctl(socket, ioctl, null, result[0..], null, null);
    return @intToPtr(ws2_32.SOCKET, @bitCast(usize, result));
}

pub fn getBaseSocket(socket: ws2_32.SOCKET) !ws2_32.SOCKET {
    const result = getUnderlyingSocket(socket, ws2_32.SIO_BASE_HANDLE);

    if (result) |base_socket| {
        return base_socket;
    } else |err| {}

    inline for (.{ pike.os.SIO_BSP_HANDLE_SELECT, pike.os.SIO_BSP_HANDLE_POLL, pike.os.SIO_BSP_HANDLE }) |ioctl| {
        if (getUnderlyingSocket(socket, ioctl)) |base_socket| {
            if (base_socket != socket) return base_socket;
        } else |err| {}
    }

    return result;
}

pub fn init(opts: pike.DriverOptions) !Self {
    const handle = try windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, undefined, math.maxInt(windows.DWORD));
    errdefer os.close(handle);

    const afd = try createAFD();
    errdefer os.close(afd);

    _ = try windows.CreateIoCompletionPort(afd, handle, 0, 0);

    try pike.os.SetFileCompletionNotificationModes(afd, pike.os.FILE_SKIP_SET_EVENT_ON_HANDLE);

    return Self{ .executor = opts.executor, .handle = handle, .afd = afd };
}

pub fn deinit(self: *Self) void {
    os.close(self.afd);
    os.close(self.handle);
}

pub const READ_EVENTS: windows.ULONG = pike.os.AFD_POLL_RECEIVE | pike.os.AFD_POLL_CONNECT_FAIL | pike.os.AFD_POLL_ACCEPT | pike.os.AFD_POLL_DISCONNECT | pike.os.AFD_POLL_ABORT | pike.os.AFD_POLL_LOCAL_CLOSE;
pub const WRITE_EVENTS: windows.ULONG = pike.os.AFD_POLL_SEND | pike.os.AFD_POLL_CONNECT_FAIL | pike.os.AFD_POLL_ABORT | pike.os.AFD_POLL_LOCAL_CLOSE;

pub fn register(self: *Self, file: *pike.File, comptime event: pike.Event) !void {
    comptime var events: windows.ULONG = 0;
    comptime {
        if (event.read) events |= READ_EVENTS;
        if (event.write) events |= WRITE_EVENTS;
    }
    const base_handle = try getBaseSocket(@ptrCast(ws2_32.SOCKET, file.handle));

    var poll_info = pike.os.AFD_POLL_INFO{
        .Timeout = math.maxInt(windows.LARGE_INTEGER),
        .HandleCount = 1,
        .Exclusive = 0,
        .Handles = [1]pike.os.AFD_HANDLE{.{
            .Handle = base_handle,
            .Status = .SUCCESS,
            .Events = events,
        }},
    };

    const poll_info_ptr = @ptrCast(*c_void, mem.asBytes(&poll_info));
    const poll_info_len = @intCast(windows.DWORD, @sizeOf(@TypeOf(pike.os.AFD_POLL_INFO)));

    const rc = windows.kernel32.DeviceIoControl(
        self.afd,
        pike.os.IOCTL_AFD_POLL,
        poll_info_ptr,
        poll_info_len,
        poll_info_ptr,
        poll_info_len,
        null,
        &file.overlapped,
    );
    if (rc != 0) {
        switch (windows.kernel32.GetLastError()) {
            .IO_PENDING => {},
            else => |err| return windows.unexpectedError(err),
        }
    }

    std.debug.print("RC: {}, Overlapped: {}\n", .{ rc, file.overlapped });
}

pub fn poll(self: *Self, timeout: i32) !void {
    var events: [1024]pike.os.OVERLAPPED_ENTRY = undefined;

    const num_events = try pike.os.GetQueuedCompletionStatusEx(self.handle, &events, @intCast(windows.DWORD, timeout), false);
    std.debug.print("hello world!\n", .{});
    for (events[0..num_events]) |e, i| {
        std.debug.print("Got an event: {}\n", .{e});
    }
}

test "IOCP.createAFD()" {
    if (builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }

    const afd = try createAFD();
    defer os.close(afd);
}
