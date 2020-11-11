const std = @import("std");

const builtin = std.builtin;

usingnamespace std.os;

pub const LINGER = extern struct {
    l_onoff: c_int, // Whether or not a socket should remain open to send queued dataa after closesocket() is called.
    l_linger: c_int, // Number of seconds on how long a socket should remain open after closesocket() is called.
};

pub fn connect_(sock: socket_t, sock_addr: *const sockaddr, len: socklen_t) !void {
    while (true) {
        return switch (errno(system.connect(sock, sock_addr, len))) {
            0 => {},
            EACCES => error.PermissionDenied,
            EPERM => error.PermissionDenied,
            EADDRINUSE => error.AddressInUse,
            EADDRNOTAVAIL => error.AddressNotAvailable,
            EAFNOSUPPORT => error.AddressFamilyNotSupported,
            EAGAIN, EINPROGRESS => error.WouldBlock,
            EALREADY => unreachable, // The socket is nonblocking and a previous connection attempt has not yet been completed.
            EBADF => unreachable, // sockfd is not a valid open file descriptor.
            ECONNREFUSED => error.ConnectionRefused,
            EFAULT => unreachable, // The socket structure address is outside the user's address space.
            EINTR => continue,
            EISCONN => error.AlreadyConnected, // The socket is already connected.
            ENETUNREACH => error.NetworkUnreachable,
            ENOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            EPROTOTYPE => unreachable, // The socket type does not support the requested communications protocol.
            ETIMEDOUT => error.ConnectionTimedOut,
            ENOENT => error.FileNotFound, // Returned when socket is AF_UNIX and the given path does not exist.
            else => |err| unexpectedErrno(err),
        };
    }
}

pub fn getsockopt(comptime T: type, handle: socket_t, level: c_int, opt: c_int) !T {
    var val: T = undefined;
    var val_len: c_int = @sizeOf(T);

    const rc = system.getsockopt(handle, level, opt, @ptrCast([*]u8, val), &val_len);
    return switch (errno(rc)) {
        0 => val,
        EBADF => error.BadFileDescriptor, // The argument sockfd is not a valid file descriptor.
        EFAULT => error.InvalidParameter, // The address pointed to by optval or optlen is not in a valid part of the process address space.
        ENOPROTOOPT => error.UnsupportedOption, // The option is unknown at the level indicated.
        ENOTSOCK => error.NotASocket, // The file descriptor sockfd does not refer to a socket.
        else => |err| unexpectedErrno(err),
    };
}

pub fn sigprocmask(flags: anytype, noalias set: ?*const sigset_t, noalias oldset: ?*sigset_t) !void {
    const rc = system.sigprocmask(flags, set, oldset);
    return switch (errno(rc)) {
        0 => {},
        EFAULT => error.InvalidParameter,
        EINVAL => error.BadSignalSet,
        else => |err| unexpectedErrno(err),
    };
}
