const std = @import("std");
const pike = @import("pike.zig");

pub usingnamespace @import("os_bits.zig");

const builtin = std.builtin;
const math = std.math;
const mem = std.mem;

const os = std.os;
const windows = os.windows;
const ws2_32 = windows.ws2_32;

const assert = std.debug.assert;

const funcs = struct {
    extern "kernel32" fn SetFileCompletionNotificationModes(FileHandle: windows.HANDLE, Flags: windows.UCHAR) callconv(.Stdcall) windows.BOOL;

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
    extern "ws2_32" fn setsockopt(s: ws2_32.SOCKET, level: c_int, optname: c_int, optval: [*c]const u8, optlen: os.socklen_t) callconv(.Stdcall) c_int;
    extern "ws2_32" fn getsockopt(s: ws2_32.SOCKET, level: c_int, optname: c_int, optval: [*c]u8, optlen: *os.socklen_t) callconv(.Stdcall) c_int;
};

pub fn getsockoptError(fd: os.fd_t) !void {
    if (builtin.os.tag == .windows) {
        var errno: usize = undefined;
        var errno_size: os.socklen_t = @sizeOf(@TypeOf(errno));

        const result = funcs.getsockopt(@ptrCast(ws2_32.SOCKET, fd), SOL_SOCKET, SO_ERROR, @ptrCast([*c]u8, &errno), &errno_size);
        if (result == ws2_32.SOCKET_ERROR) {
            switch (ws2_32.WSAGetLastError()) {
                .WSAEFAULT => unreachable,
                .WSAENOPROTOOPT => unreachable,
                .WSAENOTSOCK => unreachable,
                else => |err| return windows.unexpectedWSAError(err),
            }
        }

        if (errno != 0) {
            return switch (@intToEnum(ws2_32.WinsockError, @truncate(u16, errno))) {
                .WSAEACCES => error.PermissionDenied,
                .WSAEADDRINUSE => error.AddressInUse,
                .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
                .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
                .WSAEALREADY => unreachable, // The socket is nonblocking and a previous connection attempt has not yet been completed.
                .WSAEBADF => unreachable, // sockfd is not a valid open file descriptor.
                .WSAECONNREFUSED => error.ConnectionRefused,
                .WSAEFAULT => unreachable, // The socket structure address is outside the user's address space.
                .WSAEISCONN => unreachable, // The socket is already connected.
                .WSAENETUNREACH => error.NetworkUnreachable,
                .WSAENOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
                .WSAEPROTOTYPE => unreachable, // The socket type does not support the requested communications protocol.
                .WSAETIMEDOUT => error.ConnectionTimedOut,
                else => |err| windows.unexpectedWSAError(err),
            };
        }
    } else {
        return os.getsockoptError(fd);
    }
}

pub fn SetFileCompletionNotificationModes(file_handle: windows.HANDLE, flags: windows.UCHAR) !void {
    const success = funcs.SetFileCompletionNotificationModes(file_handle, flags);

    if (success == windows.FALSE) {
        return switch (windows.kernel32.GetLastError()) {
            else => |err| windows.unexpectedError(err),
        };
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

pub fn CancelIoEx(handle: windows.HANDLE, overlapped: ?windows.LPOVERLAPPED) !void {
    const success = windows.kernel32.CancelIoEx(handle, @intToPtr(windows.LPOVERLAPPED, @ptrToInt(overlapped)));
    if (success == windows.FALSE) {
        return switch (windows.kernel32.GetLastError()) {
            .NOT_FOUND => error.RequestNotFound,
            else => |err| windows.unexpectedError(err),
        };
    }
}

pub fn ReadFile(fd: os.fd_t, buf: []u8, overlapped: *windows.OVERLAPPED) !void {
    const len = math.cast(windows.DWORD, buf.len) catch math.maxInt(windows.DWORD);

    const success = windows.kernel32.ReadFile(fd, buf.ptr, len, null, overlapped);
    if (success == windows.FALSE) {
        return switch (windows.kernel32.GetLastError()) {
            .IO_PENDING => error.WouldBlock,
            .OPERATION_ABORTED => error.OperationAborted,
            .BROKEN_PIPE => error.BrokenPipe,
            .HANDLE_EOF, .NETNAME_DELETED => {},
            else => |err| windows.unexpectedError(err),
        };
    }
}

pub fn WriteFile(fd: os.fd_t, buf: []const u8, overlapped: *windows.OVERLAPPED) !void {
    const len = math.cast(windows.DWORD, buf.len) catch math.maxInt(windows.DWORD);

    const success = windows.kernel32.WriteFile(fd, buf.ptr, len, null, overlapped);
    if (success == windows.FALSE) {
        return switch (windows.kernel32.GetLastError()) {
            .INVALID_USER_BUFFER => error.SystemResources,
            .NOT_ENOUGH_MEMORY => error.SystemResources,
            .OPERATION_ABORTED => error.OperationAborted,
            .NOT_ENOUGH_QUOTA => error.SystemResources,
            .IO_PENDING => error.WouldBlock,
            .BROKEN_PIPE => error.BrokenPipe,
            .INVALID_HANDLE => error.NotOpenForWriting,
            .HANDLE_EOF, .NETNAME_DELETED => {},
            else => |err| windows.unexpectedError(err),
        };
    }
}

pub fn connect(fd: os.fd_t, addr: *const os.sockaddr, addr_len: os.socklen_t) !void {
    if (builtin.os.tag == .windows) {
        while (true) {
            const rc = ws2_32.connect(@ptrCast(ws2_32.SOCKET, fd), addr, addr_len);
            if (rc == ws2_32.SOCKET_ERROR) {
                return switch (ws2_32.WSAGetLastError()) {
                    .WSAEACCES => error.PermissionDenied,
                    .WSAEADDRINUSE => error.AddressInUse,
                    .WSAEINPROGRESS => error.WouldBlock,
                    .WSAEALREADY => unreachable,
                    .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
                    .WSAECONNREFUSED => error.ConnectionRefused,
                    .WSAEFAULT => unreachable,
                    .WSAEINTR => continue,
                    .WSAEISCONN => error.AlreadyConnected,
                    .WSAENETUNREACH => error.NetworkUnreachable,
                    .WSAEHOSTUNREACH => error.NetworkUnreachable,
                    .WSAENOTSOCK => unreachable,
                    .WSAETIMEDOUT => error.ConnectionTimedOut,
                    .WSAEWOULDBLOCK => error.WouldBlock,
                    else => |err| return windows.unexpectedWSAError(err),
                };
            }

            return;
        }
    } else {
        return os.connect(fd, address);
    }
}

pub fn setsockopt(sock: os.fd_t, level: u32, optname: u32, opt: []const u8) os.SetSockOptError!void {
    if (builtin.os.tag == .windows) {
        const rc = funcs.setsockopt(@ptrCast(ws2_32.SOCKET, sock), @intCast(c_int, level), @intCast(c_int, optname), opt.ptr, @intCast(os.socklen_t, opt.len));
        if (rc == ws2_32.SOCKET_ERROR) {
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
        if (rc == ws2_32.SOCKET_ERROR) {
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
    AddressInUse,
    FileDescriptorNotASocket,
    OperationNotSupported,
} || os.UnexpectedError;

pub fn listen(sock: os.fd_t, backlog: u32) ListenError!void {
    if (builtin.os.tag == .windows) {
        const rc = funcs.listen(@ptrCast(ws2_32.SOCKET, sock), @intCast(c_int, backlog));
        if (rc == ws2_32.SOCKET_ERROR) {
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

    inline for (.{ SIO_BSP_HANDLE_SELECT, SIO_BSP_HANDLE_POLL, SIO_BSP_HANDLE }) |ioctl| {
        if (getUnderlyingSocket(socket, ioctl)) |base_socket| {
            if (base_socket != socket) return base_socket;
        } else |err| {}
    }

    return result;
}

pub fn createAFD() !os.fd_t {
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

pub fn refreshAFD(file: *pike.File, events: windows.ULONG) !void {
    comptime assert(builtin.os.tag == .windows);

    const base_handle = try getBaseSocket(@ptrCast(ws2_32.SOCKET, file.handle));

    var poll_info = AFD_POLL_INFO{
        .Timeout = math.maxInt(windows.LARGE_INTEGER),
        .HandleCount = 1,
        .Exclusive = 0,
        .Handles = [1]AFD_HANDLE{.{
            .Handle = base_handle,
            .Status = .SUCCESS,
            .Events = events,
        }},
    };

    const poll_info_ptr = @ptrCast(*c_void, mem.asBytes(&poll_info));
    const poll_info_len = @intCast(windows.DWORD, @sizeOf(AFD_POLL_INFO));

    const success = windows.kernel32.DeviceIoControl(
        file.driver.afd,
        IOCTL_AFD_POLL,
        poll_info_ptr,
        poll_info_len,
        poll_info_ptr,
        poll_info_len,
        null,
        &file.waker.data.request,
    );

    if (success == windows.FALSE) {
        switch (windows.kernel32.GetLastError()) {
            .IO_PENDING => {},
            else => |err| return windows.unexpectedError(err),
        }
    }
}

pub fn write(fd: os.fd_t, bytes: []const u8) os.WriteError!usize {
    const max_count = switch (builtin.os.tag) {
        .linux => 0x7ffff000,
        .macosx, .ios, .watchos, .tvos => math.maxInt(i32),
        else => math.maxInt(isize),
    };

    const adjusted_len = math.min(max_count, bytes.len);

    while (true) {
        const rc = os.system.write(fd, bytes.ptr, adjusted_len);
        switch (os.errno(rc)) {
            0 => return @intCast(usize, rc),
            os.ECONNRESET => return 0,
            os.EINTR => continue,
            os.EINVAL => unreachable,
            os.EFAULT => unreachable,
            os.EAGAIN => return error.WouldBlock,
            os.EBADF => return error.NotOpenForWriting, // can be a race condition.
            os.EDESTADDRREQ => unreachable, // `connect` was never called.
            os.EDQUOT => return error.DiskQuota,
            os.EFBIG => return error.FileTooBig,
            os.EIO => return error.InputOutput,
            os.ENOSPC => return error.NoSpaceLeft,
            os.EPERM => return error.AccessDenied,
            os.EPIPE => return error.BrokenPipe,
            else => |err| return os.unexpectedErrno(err),
        }
    }
}

test "os.createAFD()" {
    if (builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }

    const afd = try createAFD();
    defer os.close(afd);
}
