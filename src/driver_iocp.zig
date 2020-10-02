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
    const NAME = std.unicode.utf8ToUtf16LeStringLiteral("\\Device\\Afd\\Pike");

    var attr = windows.OBJECT_ATTRIBUTES{
        .Length = @sizeOf(windows.OBJECT_ATTRIBUTES),
        .RootDirectory = null,
        .ObjectName = &windows.UNICODE_STRING{
            .Length = @intCast(windows.USHORT, NAME.len * @divExact(std.meta.bitCount(windows.WCHAR), 8)),
            .MaximumLength = @intCast(windows.USHORT, NAME.len * @divExact(std.meta.bitCount(windows.WCHAR), 8)),
            .Buffer = @intToPtr([*]windows.WCHAR, @ptrToInt(NAME)),
        },
        .Attributes = 0,
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };

    var iosb: windows.IO_STATUS_BLOCK = undefined;
    var afd = windows.INVALID_HANDLE_VALUE;

    const status = windows.ntdll.NtCreateFile(
        &afd,
        windows.SYNCHRONIZE,
        &attr,
        &iosb,
        null,
        0,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
        windows.FILE_OPEN,
        @as(windows.ULONG, 0),
        null,
        @as(windows.ULONG, 0),
    );
    if (status != .SUCCESS) return windows.unexpectedStatus(status);

    return afd;
}

pub fn getUnderlyingSocket(socket: ws2_32.SOCKET, ioctl: windows.DWORD) !ws2_32.SOCKET {
    var result: [@sizeOf(ws2_32.SOCKET)]u8 = undefined;
    _ = try windows.WSAIoctl(socket, ioctl, null, result[0..], null, null);
    return @intToPtr(ws2_32.SOCKET, @bitCast(usize, result));
}

pub fn getBaseSocket(socket: ws2_32.SOCKET) !ws2_32.SOCKET {
    const result = getUnderlyingSocket(socket, ws2_32.SIO_BASE_HANDLE);

    if (result) |base_socket| { return base_socket; } else |err| {}

    inline for (.{pike.os.SIO_BSP_HANDLE_SELECT, pike.os.SIO_BSP_HANDLE_POLL, pike.os.SIO_BSP_HANDLE}) |ioctl| {
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

pub fn register(self: *Self, file: *pike.File, comptime event: pike.Event) !void {
    _ = try windows.CreateIoCompletionPort(file.handle, self.handle, @ptrToInt(file), 0);

    var poll_info = pike.os.AFD_POLL_INFO{
        .Timeout = math.maxInt(windows.LARGE_INTEGER),
        .NumberOfHandles = 1,
        .Exclusive = 0,
        .Handles = [1]pike.os.AFD_HANDLE{.{
            .Handle = file.handle,
            .Status = .SUCCESS,
            .Events = 999,
        }},
    };

    const poll_info_ptr = mem.asBytes(&poll_info);
    const poll_info_len = @intCast(windows.ULONG, @sizeOf(@TypeOf(pike.os.AFD_POLL_INFO)));

    const status = windows.ntdll.NtDeviceIoControlFile(
        self.afd,
        null,
        null,
        null,
        iosb,
        pike.os.IOCTL_AFD_POLL,
        poll_info_ptr,
        poll_info_len,
        poll_info_ptr,
        poll_info_len,
    );

    if (status != .SUCCESS and status != .PENDING) {
        return windows.unexpectedStatus(status);
    }
}

pub fn poll(self: *Self, timeout: i32) !void {
    var events: [1024]pike.os.OVERLAPPED_ENTRY = undefined;

    const num_events = try pike.os.GetQueuedCompletionStatusEx(self.handle, &events, @intCast(windows.DWORD, timeout), false);
    for (events[0..num_events]) |e, i| {}
    // TODO(kenta): implement
}

test "IOCP.createAFD()" {
    if (builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }

    const afd = try createAFD();
    defer os.close(afd);
}
