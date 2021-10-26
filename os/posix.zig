const std = @import("std");
const builtin = @import("builtin");

const os = std.os;
const math = std.math;

pub usingnamespace if (!@hasDecl(std.os, "SHUT_RD") and !@hasDecl(std.os, "SHUT_WR") and !@hasDecl(std.os, "SHUT_RDWR"))
    struct {
        pub const SHUT_RD = 0;
        pub const SHUT_WR = 1;
        pub const SHUT_RDWR = 2;
    }
else
    struct {};

pub const LINGER = extern struct {
    l_onoff: c_int, // Whether or not a socket should remain open to send queued dataa after closesocket() is called.
    l_linger: c_int, // Number of seconds on how long a socket should remain open after closesocket() is called.
};

const funcs = struct {
    pub extern "c" fn shutdown(sock: os.socket_t, how: c_int) c_int;
};

pub fn shutdown_(sock: os.socket_t, how: c_int) !void {
    const rc = if (builtin.link_libc) funcs.shutdown(sock, how) else os.system.shutdown(sock, @intCast(i32, how));
    return switch (os.errno(rc)) {
        .SUCCESS => {},
        .BADF => error.BadFileDescriptor,
        .INVAL => error.BadArgument,
        .NOTCONN => error.SocketNotConnected,
        .NOTSOCK => error.NotASocket,
        else => |err| os.unexpectedErrno(err),
    };
}

pub fn sendto_(
    /// The file descriptor of the sending socket.
    sockfd: os.socket_t,
    /// Message to send.
    buf: []const u8,
    flags: u32,
    dest_addr: ?*const os.sockaddr,
    addrlen: os.socklen_t,
) !usize {
    while (true) {
        const rc = os.system.sendto(sockfd, buf.ptr, buf.len, flags, dest_addr, addrlen);
        switch (os.errno(rc)) {
            .SUCCESS => return @intCast(usize, rc),
            .ACCES => return error.AccessDenied,
            .AGAIN, .PROTOTYPE => return error.WouldBlock,
            .ALREADY => return error.FastOpenAlreadyInProgress,
            .BADF => unreachable, // always a race condition
            .CONNRESET => return error.ConnectionResetByPeer,
            .DESTADDRREQ => unreachable, // The socket is not connection-mode, and no peer address is set.
            .FAULT => unreachable, // An invalid user space address was specified for an argument.
            .INTR => continue,
            .INVAL => unreachable, // Invalid argument passed.
            .ISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
            .MSGSIZE => return error.MessageTooBig,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTCONN => unreachable, // The socket is not connected, and no target has been given.
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .OPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
            .PIPE => return error.BrokenPipe,
            else => |err| return os.unexpectedErrno(err),
        }
    }
}

pub fn read_(fd: os.fd_t, buf: []u8) !usize {
    const max_count = switch (builtin.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos => math.maxInt(i32),
        else => math.maxInt(isize),
    };
    const adjusted_len = math.min(max_count, buf.len);

    while (true) {
        const rc = os.system.read(fd, buf.ptr, adjusted_len);
        switch (os.errno(rc)) {
            .SUCCESS => return @intCast(usize, rc),
            .INTR => continue,
            .INVAL => unreachable,
            .FAULT => unreachable,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForReading, // Can be a race condition.
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketNotConnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            else => |err| return os.unexpectedErrno(err),
        }
    }
    return os.index;
}

pub fn connect_(sock: os.socket_t, sock_addr: *const os.sockaddr, len: os.socklen_t) !void {
    while (true) {
        return switch (os.errno(os.system.connect(sock, sock_addr, len))) {
            .SUCCESS => {},
            .ACCES => error.PermissionDenied,
            .PERM => error.PermissionDenied,
            .ADDRINUSE => error.AddressInUse,
            .ADDRNOTAVAIL => error.AddressNotAvailable,
            .AFNOSUPPORT => error.AddressFamilyNotSupported,
            .AGAIN, .INPROGRESS => error.WouldBlock,
            .ALREADY => unreachable, // The socket is nonblocking and a previous connection attempt has not yet been completed.
            .BADF => unreachable, // sockfd is not a valid open file descriptor.
            .CONNREFUSED => error.ConnectionRefused,
            .FAULT => unreachable, // The socket structure address is outside the user's address space.
            .INTR => continue,
            .ISCONN => error.AlreadyConnected, // The socket is already connected.
            .NETUNREACH => error.NetworkUnreachable,
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .PROTOTYPE => unreachable, // The socket type does not support the requested communications protocol.
            .TIMEDOUT => error.ConnectionTimedOut,
            .NOENT => error.FileNotFound, // Returned when socket is AF_UNIX and the given path does not exist.
            else => |err| os.unexpectedErrno(err),
        };
    }
}

pub fn accept_(sock: os.socket_t, addr: ?*os.sockaddr, addr_size: ?*os.socklen_t, flags: u32) !os.socket_t {
    const have_accept4 = comptime !(builtin.target.isDarwin() or builtin.os.tag == .windows);

    const accepted_sock = while (true) {
        const rc = if (have_accept4)
            os.system.accept4(sock, addr, addr_size, flags)
        else if (builtin.os.tag == .windows)
            os.windows.accept(sock, addr, addr_size)
        else
            os.system.accept(sock, addr, addr_size);

        if (builtin.os.tag == .windows) {
            if (rc == os.windows.ws2_32.INVALID_SOCKET) {
                switch (os.windows.ws2_32.WSAGetLastError()) {
                    .WSANOTINITIALISED => unreachable, // not initialized WSA
                    .WSAECONNRESET => return error.ConnectionResetByPeer,
                    .WSAEFAULT => unreachable,
                    .WSAEINVAL => return error.SocketNotListening,
                    .WSAEMFILE => return error.ProcessFdQuotaExceeded,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSAENOBUFS => return error.FileDescriptorNotASocket,
                    .WSAEOPNOTSUPP => return error.OperationNotSupported,
                    .WSAEWOULDBLOCK => return error.WouldBlock,
                    else => |err| return os.windows.unexpectedWSAError(err),
                }
            } else {
                break rc;
            }
        } else {
            switch (os.errno(rc)) {
                .SUCCESS => {
                    break @intCast(os.socket_t, rc);
                },
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .CONNABORTED => return error.ConnectionAborted,
                .FAULT => unreachable,
                .INVAL, .BADF => return error.SocketNotListening,
                .NOTSOCK => return error.NotASocket,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .OPNOTSUPP => unreachable,
                .PROTO => return error.ProtocolFailure,
                .PERM => return error.BlockedByFirewall,
                else => |err| return os.unexpectedErrno(err),
            }
        }
    } else unreachable;

    if (!have_accept4) {
        try setSockFlags(accepted_sock, flags);
    }
    return accepted_sock;
}

fn setSockFlags(sock: os.socket_t, flags: u32) !void {
    if ((flags & os.SOCK.CLOEXEC) != 0) {
        if (builtin.os.tag == .windows) {
            // TODO: Find out if this is supported for sockets
        } else {
            var fd_flags = os.fcntl(sock, os.F_GETFD, 0) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                else => |e| return e,
            };
            fd_flags |= os.FD_CLOEXEC;
            _ = os.fcntl(sock, os.F_SETFD, fd_flags) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                else => |e| return e,
            };
        }
    }
    if ((flags & os.SOCK.NONBLOCK) != 0) {
        if (builtin.os.tag == .windows) {
            var mode: c_ulong = 1;
            if (os.windows.ws2_32.ioctlsocket(sock, os.windows.ws2_32.FIONBIO, &mode) == os.windows.ws2_32.SOCKET_ERROR) {
                switch (os.windows.ws2_32.WSAGetLastError()) {
                    .WSANOTINITIALISED => unreachable,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                    // TODO: handle more errors
                    else => |err| return os.windows.unexpectedWSAError(err),
                }
            }
        } else {
            var fl_flags = os.fcntl(sock, os.F_GETFL, 0) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                else => |e| return e,
            };
            fl_flags |= os.O_NONBLOCK;
            _ = os.fcntl(sock, os.F_SETFL, fl_flags) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                else => |e| return e,
            };
        }
    }
}

pub fn getsockopt(comptime T: type, handle: os.socket_t, level: u32, opt: u32) !T {
    var val: T = undefined;
    var val_len: u32 = @sizeOf(T);

    const rc = os.system.getsockopt(handle, level, opt, @ptrCast([*]u8, &val), &val_len);
    return switch (std.os.linux.getErrno(rc)) {
        .SUCCESS => val,
        .BADF => error.BadFileDescriptor, // The argument sockfd is not a valid file descriptor.
        .FAULT => error.InvalidParameter, // The address pointed to by optval or optlen is not in a valid part of the process address space.
        .NOPROTOOPT => error.UnsupportedOption, // The option is unknown at the level indicated.
        .NOTSOCK => error.NotASocket, // The file descriptor sockfd does not refer to a socket.
        else => |err| os.unexpectedErrno(err),
    };
}

pub fn sigprocmask(flags: anytype, noalias set: ?*const os.sigset_t, noalias oldset: ?*os.sigset_t) !void {
    const rc = os.system.sigprocmask(flags, set, oldset);
    return switch (os.errno(rc)) {
        .SUCCESS => {},
        .FAULT => error.InvalidParameter,
        .INVAL => error.BadSignalSet,
        else => |err| os.unexpectedErrno(err),
    };
}
