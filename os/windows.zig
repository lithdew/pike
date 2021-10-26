const std = @import("std");

const mem = std.mem;
const math = std.math;

const os = std.os;
const windows = os.windows;
const ws2_32 = windows.ws2_32;

pub const FILE_SKIP_COMPLETION_PORT_ON_SUCCESS = 0x1;
pub const FILE_SKIP_SET_EVENT_ON_HANDLE = 0x2;

pub const CTRL_C_EVENT: windows.DWORD = 0;
pub const CTRL_BREAK_EVENT: windows.DWORD = 1;
pub const CTRL_CLOSE_EVENT: windows.DWORD = 2;
pub const CTRL_LOGOFF_EVENT: windows.DWORD = 5;
pub const CTRL_SHUTDOWN_EVENT: windows.DWORD = 6;

pub const HANDLER_ROUTINE = fn (dwCtrlType: windows.DWORD) callconv(.C) windows.BOOL;

pub const OVERLAPPED_ENTRY = extern struct {
    lpCompletionKey: windows.ULONG_PTR,
    lpOverlapped: ?windows.LPOVERLAPPED,
    Internal: windows.ULONG_PTR,
    dwNumberOfBytesTransferred: windows.DWORD,
};

pub fn loadWinsockExtensionFunction(comptime T: type, sock: ws2_32.SOCKET, guid: windows.GUID) !T {
    var function: T = undefined;
    var num_bytes: windows.DWORD = undefined;

    const rc = ws2_32.WSAIoctl(
        sock,
        @import("windows/ws2_32.zig").SIO_GET_EXTENSION_FUNCTION_POINTER,
        @ptrCast(*const c_void, &guid),
        @sizeOf(windows.GUID),
        &function,
        @sizeOf(T),
        &num_bytes,
        null,
        null,
    );

    if (rc == ws2_32.SOCKET_ERROR) {
        return switch (ws2_32.WSAGetLastError()) {
            .WSAEOPNOTSUPP => error.OperationNotSupported,
            .WSAENOTSOCK => error.FileDescriptorNotASocket,
            else => |err| windows.unexpectedWSAError(err),
        };
    }

    if (num_bytes != @sizeOf(T)) {
        return error.ShortRead;
    }

    return function;
}

pub fn SetConsoleCtrlHandler(handler_routine: ?HANDLER_ROUTINE, add: bool) !void {
    const success = @import("windows/kernel32.zig").SetConsoleCtrlHandler(
        handler_routine,
        if (add) windows.TRUE else windows.FALSE,
    );

    if (success == windows.FALSE) {
        return switch (windows.kernel32.GetLastError()) {
            else => |err| windows.unexpectedError(err),
        };
    }
}

pub fn SetFileCompletionNotificationModes(handle: windows.HANDLE, flags: windows.UCHAR) !void {
    const success = @import("windows/kernel32.zig").SetFileCompletionNotificationModes(handle, flags);

    if (success == windows.FALSE) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
}

pub const GetQueuedCompletionStatusError = error{
    Aborted,
    Cancelled,
    EOF,
    Timeout,
} || os.UnexpectedError;

pub fn GetQueuedCompletionStatusEx(
    completion_port: windows.HANDLE,
    completion_port_entries: []windows.OVERLAPPED_ENTRY,
    timeout_ms: ?windows.DWORD,
    alertable: bool,
) GetQueuedCompletionStatusError!u32 {
    var num_entries_removed: u32 = 0;

    const success = @import("windows/kernel32.zig").GetQueuedCompletionStatusEx(
        completion_port,
        completion_port_entries.ptr,
        @intCast(windows.ULONG, completion_port_entries.len),
        &num_entries_removed,
        timeout_ms orelse windows.INFINITE,
        @boolToInt(alertable),
    );

    if (success == windows.FALSE) {
        return switch (windows.kernel32.GetLastError()) {
            .ABANDONED_WAIT_0 => error.Aborted,
            .OPERATION_ABORTED => error.Cancelled,
            .HANDLE_EOF => error.EOF,
            .IMEOUT => error.Timeout,
            else => |err| windows.unexpectedError(err),
        };
    }

    return num_entries_removed;
}

pub fn pollBaseSocket(socket: ws2_32.SOCKET, ioctl_code: windows.DWORD) !ws2_32.SOCKET {
    var base_socket: ws2_32.SOCKET = undefined;
    var num_bytes: windows.DWORD = 0;

    const rc = ws2_32.WSAIoctl(
        socket,
        ioctl_code,
        null,
        0,
        @ptrCast([*]u8, &base_socket),
        @sizeOf(ws2_32.SOCKET),
        &num_bytes,
        null,
        null,
    );

    if (rc == ws2_32.SOCKET_ERROR) {
        return switch (ws2_32.WSAGetLastError()) {
            .WSAEOPNOTSUPP => error.OperationNotSupported,
            else => |err| windows.unexpectedWSAError(err),
        };
    }

    if (num_bytes != @sizeOf(ws2_32.SOCKET)) {
        return error.ShortRead;
    }

    return base_socket;
}

pub fn getBaseSocket(socket: ws2_32.SOCKET) !ws2_32.SOCKET {
    const err = if (pollBaseSocket(socket, @import("windows/ws2_32.zig").SIO_BASE_HANDLE)) |base_socket| return base_socket else |err| err;

    inline for (.{
        @import("windows/ws2_32.zig").SIO_BSP_HANDLE_SELECT,
        @import("windows/ws2_32.zig").SIO_BSP_HANDLE_POLL,
        @import("windows/ws2_32.zig").SIO_BSP_HANDLE,
    }) |ioctl_code| {
        if (pollBaseSocket(socket, ioctl_code)) |base_socket| return base_socket else |_| {}
    }

    return err;
}

pub fn GetAcceptExSockaddrs(socket: ws2_32.SOCKET, buf: []const u8, local_addr_len: u32, remote_addr_len: u32, local_addr: **ws2_32.sockaddr, remote_addr: **ws2_32.sockaddr) !void {
    const func = try loadWinsockExtensionFunction(@import("windows/ws2_32.zig").GetAcceptExSockaddrs, socket, @import("windows/ws2_32.zig").WSAID_GETACCEPTEXSOCKADDRS);

    var local_addr_ptr_len = @as(c_int, @sizeOf(ws2_32.sockaddr));
    var remote_addr_ptr_len = @as(c_int, @sizeOf(ws2_32.sockaddr));

    func(
        buf.ptr,
        0,
        local_addr_len,
        remote_addr_len,
        local_addr,
        &local_addr_ptr_len,
        remote_addr,
        &remote_addr_ptr_len,
    );
}

pub fn AcceptEx(listening_socket: ws2_32.SOCKET, accepted_socket: ws2_32.SOCKET, buf: []u8, local_addr_len: u32, remote_addr_len: u32, num_bytes: *windows.DWORD, overlapped: *windows.OVERLAPPED) !void {
    const func = try loadWinsockExtensionFunction(@import("windows/ws2_32.zig").AcceptEx, listening_socket, @import("windows/ws2_32.zig").WSAID_ACCEPTEX);

    const success = func(
        listening_socket,
        accepted_socket,
        buf.ptr,
        0,
        local_addr_len,
        remote_addr_len,
        num_bytes,
        overlapped,
    );

    if (success == windows.FALSE) {
        return switch (ws2_32.WSAGetLastError()) {
            .WSAECONNRESET => error.ConnectionResetByPeer,
            .WSAEFAULT => error.BadAddress,
            .WSAEINVAL => error.SocketNotListening,
            .WSAEMFILE => error.ProcessFdQuotaExceeded,
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAENOBUFS => error.FileDescriptorNotASocket,
            .WSAEOPNOTSUPP => error.OperationNotSupported,
            .WSA_IO_PENDING, .WSAEWOULDBLOCK => error.WouldBlock,
            else => |err| windows.unexpectedWSAError(err),
        };
    }
}

pub fn ConnectEx(sock: ws2_32.SOCKET, sock_addr: *const ws2_32.sockaddr, sock_len: ws2_32.socklen_t, overlapped: *windows.OVERLAPPED) !void {
    const func = try loadWinsockExtensionFunction(@import("windows/ws2_32.zig").ConnectEx, sock, @import("windows/ws2_32.zig").WSAID_CONNECTEX);

    const success = func(sock, sock_addr, @intCast(c_int, sock_len), null, 0, null, overlapped);
    if (success == windows.FALSE) {
        return switch (ws2_32.WSAGetLastError()) {
            .WSAEADDRINUSE => error.AddressInUse,
            .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
            .WSAECONNREFUSED => error.ConnectionRefused,
            .WSAETIMEDOUT => error.ConnectionTimedOut,
            .WSAEFAULT => error.BadAddress,
            .WSAEINVAL => error.NotYetBound,
            .WSAEISCONN => error.AlreadyConnected,
            .WSAENOTSOCK => error.NotASocket,
            .WSAEACCES => error.BroadcastNotEnabled,
            .WSAENOBUFS => error.SystemResources,
            .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
            .WSA_IO_PENDING, .WSAEINPROGRESS, .WSAEWOULDBLOCK => error.WouldBlock,
            .WSAEHOSTUNREACH, .WSAENETUNREACH => error.NetworkUnreachable,
            else => |err| windows.unexpectedWSAError(err),
        };
    }
}

pub fn bind_(sock: ws2_32.SOCKET, sock_addr: *const ws2_32.sockaddr, sock_len: ws2_32.socklen_t) !void {
    const rc = ws2_32.bind(sock, sock_addr, @intCast(c_int, sock_len));
    if (rc == ws2_32.SOCKET_ERROR) {
        return switch (ws2_32.WSAGetLastError()) {
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAEACCES => error.AccessDenied,
            .WSAEADDRINUSE => error.AddressInUse,
            .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
            .WSAEFAULT => error.BadAddress,
            .WSAEINPROGRESS => error.WouldBlock,
            .WSAEINVAL => error.AlreadyBound,
            .WSAENOBUFS => error.NoEphemeralPortsAvailable,
            .WSAENOTSOCK => error.NotASocket,
            else => |err| windows.unexpectedWSAError(err),
        };
    }
}

pub fn listen_(sock: ws2_32.SOCKET, backlog: usize) !void {
    const rc = ws2_32.listen(sock, @intCast(c_int, backlog));
    if (rc == ws2_32.SOCKET_ERROR) {
        return switch (ws2_32.WSAGetLastError()) {
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAEADDRINUSE => error.AddressInUse,
            .WSAEISCONN => error.AlreadyConnected,
            .WSAEINVAL => error.SocketNotBound,
            .WSAEMFILE, .WSAENOBUFS => error.SystemResources,
            .WSAENOTSOCK => error.FileDescriptorNotASocket,
            .WSAEOPNOTSUPP => error.OperationNotSupported,
            .WSAEINPROGRESS => error.WouldBlock,
            else => |err| windows.unexpectedWSAError(err),
        };
    }
}

pub fn connect(sock: ws2_32.SOCKET, sock_addr: *const ws2_32.sockaddr, len: ws2_32.socklen_t) !void {
    const rc = ws2_32.connect(sock, sock_addr, @intCast(i32, len));
    if (rc == ws2_32.SOCKET_ERROR) {
        return switch (ws2_32.WSAGetLastError()) {
            .WSAEADDRINUSE => error.AddressInUse,
            .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
            .WSAECONNREFUSED => error.ConnectionRefused,
            .WSAETIMEDOUT => error.ConnectionTimedOut,
            .WSAEFAULT => error.BadAddress,
            .WSAEINVAL => error.ListeningSocket,
            .WSAEISCONN => error.AlreadyConnected,
            .WSAENOTSOCK => error.NotASocket,
            .WSAEACCES => error.BroadcastNotEnabled,
            .WSAENOBUFS => error.SystemResources,
            .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
            .WSAEINPROGRESS, .WSAEWOULDBLOCK => error.WouldBlock,
            .WSAEHOSTUNREACH, .WSAENETUNREACH => error.NetworkUnreachable,
            else => |err| windows.unexpectedWSAError(err),
        };
    }
}

pub fn recv(sock: ws2_32.SOCKET, buf: []u8) !usize {
    const rc = @import("windows/ws2_32.zig").recv(sock, buf.ptr, @intCast(c_int, buf.len), 0);
    if (rc == ws2_32.SOCKET_ERROR) {
        return switch (ws2_32.WSAGetLastError()) {
            .WSANOTINITIALISED => error.WinsockNotInitialized,
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAEFAULT => error.BadBuffer,
            .WSAENOTCONN => error.SocketNotConnected,
            .WSAEINTR => error.Cancelled,
            .WSAEINPROGRESS, .WSAEWOULDBLOCK => error.WouldBlock,
            .WSAENETRESET => error.NetworkReset,
            .WSAENOTSOCK => error.NotASocket,
            .WSAEOPNOTSUPP => error.FlagNotSupported,
            .WSAESHUTDOWN => error.EndOfFile,
            .WSAEMSGSIZE => error.MessageTooLarge,
            .WSAEINVAL => error.SocketNotBound,
            .WSAECONNABORTED => error.ConnectionAborted,
            .WSAETIMEDOUT => error.Timeout,
            .WSAECONNRESET => error.Refused,
            else => |err| windows.unexpectedWSAError(err),
        };
    }

    return @intCast(usize, rc);
}

pub fn getsockopt(comptime T: type, handle: ws2_32.SOCKET, level: c_int, opt: c_int) !T {
    var val: T = undefined;
    var val_len: c_int = @sizeOf(T);

    const result = @import("windows/ws2_32.zig").getsockopt(handle, level, opt, @ptrCast([*]u8, &val), &val_len);
    if (result == ws2_32.SOCKET_ERROR) {
        return switch (ws2_32.WSAGetLastError()) {
            .WSAEFAULT => error.InvalidParameter,
            .WSAENOPROTOOPT => error.UnsupportedOption,
            .WSAENOTSOCK => error.NotASocket,
            else => |err| windows.unexpectedWSAError(err),
        };
    }

    return val;
}

pub fn shutdown(socket: ws2_32.SOCKET, how: c_int) !void {
    const result = @import("windows/ws2_32.zig").shutdown(socket, how);
    if (result == ws2_32.SOCKET_ERROR) {
        return switch (ws2_32.WSAGetLastError()) {
            .WSAECONNABORTED => error.ConnectionAborted,
            .WSAECONNRESET => error.ConnectionResetByPeer,
            .WSAEINPROGRESS => error.WouldBlock,
            .WSAEINVAL => error.BadArgument,
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAENOTCONN => error.SocketNotConnected,
            .WSAENOTSOCK => error.FileDescriptorNotASocket,
            else => |err| windows.unexpectedWSAError(err),
        };
    }
}

pub const SetSockOptError = error{
    /// The socket is already connected, and a specified option cannot be set while the socket is connected.
    AlreadyConnected,

    /// The option is not supported by the protocol.
    InvalidProtocolOption,

    /// The send and receive timeout values are too big to fit into the timeout fields in the socket structure.
    TimeoutTooBig,

    /// Insufficient resources are available in the system to complete the call.
    SystemResources,

    NetworkSubsystemFailed,
    FileDescriptorNotASocket,
    SocketNotBound,
    SocketNotConnected,
    AlreadyShutdown,
} || std.os.UnexpectedError;

pub fn setsockopt(sock: ws2_32.SOCKET, level: u32, opt: u32, val: ?[]const u8) SetSockOptError!void {
    const rc = ws2_32.setsockopt(sock, level, opt, if (val) |v| v.ptr else null, if (val) |v| @intCast(ws2_32.socklen_t, v.len) else 0);
    if (rc == ws2_32.SOCKET_ERROR) {
        switch (ws2_32.WSAGetLastError()) {
            .WSANOTINITIALISED => unreachable,
            .WSAENETDOWN => return error.NetworkSubsystemFailed,
            .WSAEFAULT => unreachable,
            .WSAENOTSOCK => return error.FileDescriptorNotASocket,
            .WSAEINVAL => return error.SocketNotBound,
            .WSAENOTCONN => return error.SocketNotConnected,
            .WSAESHUTDOWN => return error.AlreadyShutdown,
            else => |err| return windows.unexpectedWSAError(err),
        }
    }
}

pub fn WSASendTo(sock: ws2_32.SOCKET, buf: []const u8, flags: windows.DWORD, addr: ?*const ws2_32.sockaddr, addr_len: ws2_32.socklen_t, overlapped: *windows.OVERLAPPED) !void {
    var wsa_buf = ws2_32.WSABUF{
        .len = @truncate(u32, buf.len),
        .buf = @intToPtr([*]u8, @ptrToInt(buf.ptr)),
    };

    const rc = ws2_32.WSASendTo(sock, @intToPtr([*]ws2_32.WSABUF, @ptrToInt(&wsa_buf)), 1, null, flags, addr, @intCast(c_int, addr_len), @ptrCast(*ws2_32.WSAOVERLAPPED, overlapped), null);

    if (rc == ws2_32.SOCKET_ERROR) {
        return switch (ws2_32.WSAGetLastError()) {
            .WSAECONNABORTED => error.ConnectionAborted,
            .WSAECONNRESET => error.ConnectionResetByPeer,
            .WSAEFAULT => error.BadBuffer,
            .WSAEINPROGRESS, .WSAEWOULDBLOCK, .WSA_IO_PENDING => error.WouldBlock,
            .WSAEINTR => error.Cancelled,
            .WSAEINVAL => error.SocketNotBound,
            .WSAEMSGSIZE => error.MessageTooLarge,
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAENETRESET => error.NetworkReset,
            .WSAENOBUFS => error.BufferDeadlock,
            .WSAENOTCONN => error.SocketNotConnected,
            .WSAENOTSOCK => error.FileDescriptorNotASocket,
            .WSAEOPNOTSUPP => error.OperationNotSupported,
            .WSAESHUTDOWN => error.AlreadyShutdown,
            .WSAETIMEDOUT => error.Timeout,
            .WSA_OPERATION_ABORTED => error.OperationAborted,
            else => |err| windows.unexpectedWSAError(err),
        };
    }
}

pub fn WSASend(sock: ws2_32.SOCKET, buf: []const u8, flags: windows.DWORD, overlapped: *windows.OVERLAPPED) !void {
    var wsa_buf = ws2_32.WSABUF{
        .len = @truncate(u32, buf.len),
        .buf = @intToPtr([*]u8, @ptrToInt(buf.ptr)),
    };

    const rc = ws2_32.WSASend(sock, @intToPtr([*]ws2_32.WSABUF, @ptrToInt(&wsa_buf)), 1, null, flags, @ptrCast(*ws2_32.WSAOVERLAPPED, overlapped), null);

    if (rc == ws2_32.SOCKET_ERROR) {
        return switch (ws2_32.WSAGetLastError()) {
            .WSAECONNABORTED => error.ConnectionAborted,
            .WSAECONNRESET => error.ConnectionResetByPeer,
            .WSAEFAULT => error.BadBuffer,
            .WSAEINPROGRESS, .WSAEWOULDBLOCK, .WSA_IO_PENDING => error.WouldBlock,
            .WSAEINTR => error.Cancelled,
            .WSAEINVAL => error.SocketNotBound,
            .WSAEMSGSIZE => error.MessageTooLarge,
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAENETRESET => error.NetworkReset,
            .WSAENOBUFS => error.BufferDeadlock,
            .WSAENOTCONN => error.SocketNotConnected,
            .WSAENOTSOCK => error.FileDescriptorNotASocket,
            .WSAEOPNOTSUPP => error.OperationNotSupported,
            .WSAESHUTDOWN => error.AlreadyShutdown,
            .WSAETIMEDOUT => error.Timeout,
            .WSA_OPERATION_ABORTED => error.OperationAborted,
            else => |err| windows.unexpectedWSAError(err),
        };
    }
}

pub fn WSARecv(sock: ws2_32.SOCKET, buf: []u8, flags: windows.DWORD, overlapped: *windows.OVERLAPPED) !void {
    var wsa_flags: windows.DWORD = flags;
    var wsa_buf = ws2_32.WSABUF{
        .len = @truncate(u32, buf.len),
        .buf = buf.ptr,
    };

    const rc = ws2_32.WSARecv(sock, @intToPtr([*]const ws2_32.WSABUF, @ptrToInt(&wsa_buf)), 1, null, &wsa_flags, @ptrCast(*ws2_32.WSAOVERLAPPED, overlapped), null);

    if (rc == ws2_32.SOCKET_ERROR) {
        return switch (ws2_32.WSAGetLastError()) {
            .WSAECONNABORTED => error.ConnectionAborted,
            .WSAECONNRESET => error.ConnectionResetByPeer,
            .WSAEDISCON => error.ConnectionClosedByPeer,
            .WSAEFAULT => error.BadBuffer,
            .WSAEINPROGRESS, .WSAEWOULDBLOCK, .WSA_IO_PENDING => error.WouldBlock,
            .WSAEINTR => error.Cancelled,
            .WSAEINVAL => error.SocketNotBound,
            .WSAEMSGSIZE => error.MessageTooLarge,
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAENETRESET => error.NetworkReset,
            .WSAENOTCONN => error.SocketNotConnected,
            .WSAENOTSOCK => error.FileDescriptorNotASocket,
            .WSAEOPNOTSUPP => error.OperationNotSupported,
            .WSAESHUTDOWN => error.AlreadyShutdown,
            .WSAETIMEDOUT => error.Timeout,
            .WSA_OPERATION_ABORTED => error.OperationAborted,
            else => |err| windows.unexpectedWSAError(err),
        };
    }
}

pub fn WSARecvFrom(sock: ws2_32.SOCKET, buf: []u8, flags: windows.DWORD, addr: ?*ws2_32.sockaddr, addr_len: ?*ws2_32.socklen_t, overlapped: *windows.OVERLAPPED) !void {
    var wsa_flags: windows.DWORD = flags;
    var wsa_buf = ws2_32.WSABUF{
        .len = @truncate(u32, buf.len),
        .buf = buf.ptr,
    };

    const rc = ws2_32.WSARecvFrom(sock, @intToPtr([*]const ws2_32.WSABUF, @ptrToInt(&wsa_buf)), 1, null, &wsa_flags, addr, addr_len, @ptrCast(*ws2_32.WSAOVERLAPPED, overlapped), null);

    if (rc == ws2_32.SOCKET_ERROR) {
        return switch (ws2_32.WSAGetLastError()) {
            .WSAECONNABORTED => error.ConnectionAborted,
            .WSAECONNRESET => error.ConnectionResetByPeer,
            .WSAEDISCON => error.ConnectionClosedByPeer,
            .WSAEFAULT => error.BadBuffer,
            .WSAEINPROGRESS, .WSAEWOULDBLOCK, .WSA_IO_PENDING => error.WouldBlock,
            .WSAEINTR => error.Cancelled,
            .WSAEINVAL => error.SocketNotBound,
            .WSAEMSGSIZE => error.MessageTooLarge,
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAENETRESET => error.NetworkReset,
            .WSAENOTCONN => error.SocketNotConnected,
            .WSAENOTSOCK => error.FileDescriptorNotASocket,
            .WSAEOPNOTSUPP => error.OperationNotSupported,
            .WSAESHUTDOWN => error.AlreadyShutdown,
            .WSAETIMEDOUT => error.Timeout,
            .WSA_OPERATION_ABORTED => error.OperationAborted,
            else => |err| windows.unexpectedWSAError(err),
        };
    }
}

pub fn ReadFile_(handle: windows.HANDLE, buf: []u8, overlapped: *windows.OVERLAPPED) !void {
    const len = math.cast(windows.DWORD, buf.len) catch math.maxInt(windows.DWORD);

    const success = windows.kernel32.ReadFile(handle, buf.ptr, len, null, overlapped);
    if (success == windows.FALSE) {
        return switch (windows.kernel32.GetLastError()) {
            .IO_PENDING => error.WouldBlock,
            .OPERATION_ABORTED => error.OperationAborted,
            .BROKEN_PIPE => error.BrokenPipe,
            .HANDLE_EOF, .NETNAME_DELETED => error.EndOfFile,
            else => |err| windows.unexpectedError(err),
        };
    }
}

pub fn WriteFile_(handle: windows.HANDLE, buf: []const u8, overlapped: *windows.OVERLAPPED) !void {
    const len = math.cast(windows.DWORD, buf.len) catch math.maxInt(windows.DWORD);

    const success = windows.kernel32.WriteFile(handle, buf.ptr, len, null, overlapped);
    if (success == windows.FALSE) {
        return switch (windows.kernel32.GetLastError()) {
            .IO_PENDING => error.WouldBlock,
            .OPERATION_ABORTED => error.OperationAborted,
            .BROKEN_PIPE => error.BrokenPipe,
            .HANDLE_EOF, .NETNAME_DELETED => error.EndOfFile,
            else => |err| windows.unexpectedError(err),
        };
    }
}

pub fn CancelIoEx(handle: windows.HANDLE, overlapped: *windows.OVERLAPPED) !void {
    const success = windows.kernel32.CancelIoEx(handle, overlapped);
    if (success == windows.FALSE) {
        return switch (windows.kernel32.GetLastError()) {
            .NOT_FOUND => error.RequestNotFound,
            else => |err| windows.unexpectedError(err),
        };
    }
}

pub fn GetOverlappedResult_(h: windows.HANDLE, overlapped: *windows.OVERLAPPED, wait: bool) !windows.DWORD {
    var bytes: windows.DWORD = undefined;
    if (windows.kernel32.GetOverlappedResult(h, overlapped, &bytes, @boolToInt(wait)) == 0) {
        return switch (windows.kernel32.GetLastError()) {
            .IO_INCOMPLETE => if (!wait) error.WouldBlock else unreachable,
            .OPERATION_ABORTED => error.OperationAborted,
            else => |err| windows.unexpectedError(err),
        };
    }
    return bytes;
}
