const std = @import("std");

usingnamespace std.os;

pub const LINGER = extern struct {
    l_onoff: c_int, // Whether or not a socket should remain open to send queued dataa after closesocket() is called.
    l_linger: c_int, // Number of seconds on how long a socket should remain open after closesocket() is called.
};

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

pub fn sigprocmask(flags: u32, noalias set: ?*const sigset_t, noalias oldset: ?*sigset_t) !void {
    const rc = system.sigprocmask(flags, set, oldset);
    return switch (errno(rc)) {
        0 => {},
        EFAULT => error.InvalidParameter,
        EINVAL => error.BadSignalSet,
        else => |err| unexpectedErrno(err),
    };
}
