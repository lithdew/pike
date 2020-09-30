const std = @import("std");
const os = std.os;
const math = std.math;
const windows = os.windows;
const ws2_32 = windows.ws2_32;

const pike = @import("pike.zig");

const Self = @This();

executor: pike.Executor,
handle: os.fd_t = windows.INVALID_HANDLE_VALUE,

const EMPTY_BUFFER: []u8 = &[0]u8{};
const EMPTY_WSABUF = [1]ws2_32.WSABUF{.{ .len = @intCast(windows.ULONG, EMPTY_BUFFER.len), .buf = EMPTY_BUFFER.ptr }};

pub fn init(opts: pike.DriverOptions) !Self {
    const handle = try windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, undefined, math.maxInt(windows.DWORD));
    errdefer os.close(handle);

    return Self{ .executor = opts.executor, .handle = handle };
}

pub fn deinit(self: *Self) void {
    os.close(self.handle);
}

pub fn register(self: *Self, file: *pike.File, comptime event: pike.Event) !void {
    _ = try windows.CreateIoCompletionPort(file.handle, self.handle, @ptrToInt(file), 0);

    if (event.read) {
        // const rc = ws2_32.WSARecv(@ptrCast(ws2_32.SOCKET, file.handle), EMPTY_WSABUF[0..], @intCast(windows.ULONG, EMPTY_WSABUF.len), null, ws2_32.MSG_PEEK, null, null);
        // if (rc != 0) {
        //     return switch (ws2_32.WSAGetLastError()) {
        //         .WSAENOTSOCK => unreachable,
        //         .WSAEINVAL => unreachable,
        //         .WSAEFAULT => unreachable,
        //         .WSAEWOULDBLOCK => unreachable,
        //         else => |err| return windows.unexpectedWSAError(err),
        //     };
        // }
    }
}

pub fn poll(self: *Self, timeout: i32) !void {
    var events: [1024]pike.os.OVERLAPPED_ENTRY = undefined;

    const num_events = try pike.os.GetQueuedCompletionStatusEx(self.handle, &events, @intCast(windows.DWORD, timeout), false);
    for (events[0..num_events]) |e, i| {
        const file = @intToPtr(*pike.File, e.lpCompletionKey);
        file.trigger(.{ .read = true });
    }
    // TODO(kenta): implement
}
