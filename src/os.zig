const std = @import("std");
const builtin = std.builtin;
const os = std.os;
const windows = os.windows;
const ws2_32 = windows.ws2_32;

pub const OVERLAPPED_ENTRY = extern struct {
    lpCompletionKey: windows.ULONG_PTR,
    lpOverlapped: windows.LPOVERLAPPED,
    Internal: windows.ULONG_PTR,
    dwNumberOfBytesTransferred: windows.DWORD,
};

const funcs = struct {
    extern "kernel32" fn GetQueuedCompletionStatusEx(
        CompletionPort: windows.HANDLE,
        lpCompletionPortEntries: [*]OVERLAPPED_ENTRY,
        ulCount: windows.ULONG,
        ulNumEntriesRemoved: *windows.ULONG,
        dwMilliseconds: windows.DWORD,
        fAlertable: windows.BOOL,
    ) callconv(.Stdcall) windows.BOOL;

    extern "ws2_32" fn bind(s: ws2_32.SOCKET, addr: [*c]const std.os.sockaddr, namelen: std.os.socklen_t) callconv(.Stdcall) c_int;
    extern "ws2_32" fn listen(s: ws2_32.SOCKET, backlog: c_int) callconv(.Stdcall) c_int;
    extern "ws2_32" fn accept(s: ws2_32.SOCKET, addr: [*c]std.os.sockaddr, addrlen: [*c]std.os.socklen_t) callconv(.Stdcall) ws2_32.SOCKET;
    extern "ws2_32" fn setsockopt(s: ws2_32.SOCKET, level: c_int, optname: c_int, optval: [*c]const u8, optlen: c_int) callconv(.Stdcall) c_int;
};

pub const GetQueuedCompletionStatusError = error{
    Aborted,
    Cancelled,
    EOF,
    Timeout,
} || os.UnexpectedError;

pub fn GetQueuedCompletionStatusEx(
    completion_port: windows.HANDLE,
    completion_port_entries: []OVERLAPPED_ENTRY,
    timeout_ms: ?windows.DWORD,
    alertable: bool,
) GetQueuedCompletionStatusError!u32 {
    var num_entries_removed: u32 = 0;

    const result = funcs.GetQueuedCompletionStatusEx(
        completion_port,
        completion_port_entries.ptr,
        @intCast(windows.ULONG, completion_port_entries.len),
        &num_entries_removed,
        timeout_ms orelse windows.INFINITE,
        @boolToInt(alertable),
    );

    if (result == windows.FALSE) {
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

pub const SOL_SOCKET = if (builtin.os.tag == .windows) 0xffff else os.SOL_SOCKET;
pub const SO_REUSEADDR = if (builtin.os.tag == .windows) 0x0004 else os.SO_REUSEADDR;

pub fn setsockopt(sock: os.fd_t, level: u32, optname: u32, opt: []const u8) os.SetSockOptError!void {
    if (builtin.os.tag == .windows) {
        const rc = funcs.setsockopt(@ptrCast(ws2_32.SOCKET, sock), @intCast(c_int, level), @intCast(c_int, optname), opt.ptr, @intCast(c_int, opt.len));
        if (rc != 0) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAENOTSOCK => unreachable,
                .WSAEINVAL => unreachable,
                .WSAEFAULT => unreachable,
                .WSAENOPROTOOPT => error.InvalidProtocolOption,
                else => |err| return windows.unexpectedWSAError(err),
            };
        }
    } else {
        return os.setsockopt(sock, level, optname, opt);
    }
}

pub fn bind(sock: os.fd_t, addr: *const os.sockaddr, len: os.socklen_t) os.BindError!void {
    if (builtin.os.tag == .windows) {
        const rc = funcs.bind(@ptrCast(ws2_32.SOCKET, sock), addr, len);
        if (rc != 0) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAEACCES => error.AccessDenied,
                .WSAEADDRINUSE => error.AddressInUse,
                .WSAEINVAL => unreachable,
                .WSAENOTSOCK => unreachable,
                .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
                .WSAEFAULT => unreachable,
                else => |err| return windows.unexpectedWSAError(err),
            };
        }
    } else {
        return os.bind(sock, addr, len);
    }
}

pub const ListenError = error{
    /// Another socket is already listening on the same port.
    /// For Internet domain sockets, the  socket referred to by sockfd had not previously
    /// been bound to an address and, upon attempting to bind it to an ephemeral port, it
    /// was determined that all port numbers in the ephemeral port range are currently in
    /// use.  See the discussion of /proc/sys/net/ipv4/ip_local_port_range in ip(7).
    AddressInUse,

    /// The file descriptor sockfd does not refer to a socket.
    FileDescriptorNotASocket,

    /// The socket is not of a type that supports the listen() operation.
    OperationNotSupported,
} || os.UnexpectedError;

pub fn listen(sock: os.fd_t, backlog: u32) ListenError!void {
    if (builtin.os.tag == .windows) {
        const rc = funcs.listen(@ptrCast(ws2_32.SOCKET, sock), @intCast(c_int, backlog));
        if (rc != 0) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAEADDRINUSE => error.AddressInUse,
                .WSAENOTSOCK => error.FileDescriptorNotASocket,
                .WSAEOPNOTSUPP => error.OperationNotSupported,
                else => |err| return windows.unexpectedWSAError(err),
            };
        }
    } else {
        os.listen(sock, backlog) catch |err| return @errSetCast(ListenError, err);
    }
}

pub fn accept(sock: os.fd_t, addr: *os.sockaddr, addr_size: *os.socklen_t, flags: u32) os.AcceptError!os.fd_t {
    if (builtin.os.tag == .windows) {
        while (true) {
            const rc = funcs.accept(@ptrCast(ws2_32.SOCKET, sock), addr, addr_size);
            if (rc == ws2_32.INVALID_SOCKET) {
                return switch (ws2_32.WSAGetLastError()) {
                    .WSAEINTR => continue,
                    .WSAEWOULDBLOCK => error.WouldBlock,
                    .WSAECONNRESET => error.ConnectionAborted,
                    .WSAEFAULT => unreachable,
                    .WSAEINVAL => unreachable,
                    .WSAENOTSOCK => unreachable,
                    .WSAEMFILE => error.ProcessFdQuotaExceeded,
                    .WSAENOBUFS => error.SystemResources,
                    .WSAEOPNOTSUPP => unreachable,
                    else => |err| return windows.unexpectedWSAError(err),
                };
            }

            return @ptrCast(os.fd_t, rc);
        }
    } else {
        return os.accept(sock, addr, addr_size, flags);
    }
}
