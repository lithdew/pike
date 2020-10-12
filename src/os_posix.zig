const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const builtin = std.builtin;
const math = std.math;

pub usingnamespace @import("bits_posix.zig");

pub fn getsockoptError(fd: os.fd_t) !void {
    return os.getsockoptError(fd);
}

pub fn connect(fd: os.fd_t, addr: *const os.sockaddr, addr_len: os.socklen_t) !void {
    return os.connect(fd, addr, addr_len);
}

pub fn setsockopt(sock: os.fd_t, level: u32, optname: u32, opt: []const u8) os.SetSockOptError!void {
    return os.setsockopt(sock, level, optname, opt);
}

pub fn bind(sock: os.fd_t, addr: *const os.sockaddr, len: os.socklen_t) os.BindError!void {
    return os.bind(sock, addr, len);
}

pub const ListenError = error{
    AddressInUse,
    FileDescriptorNotASocket,
    OperationNotSupported,
} || os.UnexpectedError;

pub fn listen(sock: os.fd_t, backlog: u32) ListenError!void {
    os.listen(sock, backlog) catch |err| return @errSetCast(ListenError, err);
}

pub fn accept(sock: os.fd_t, addr: *os.sockaddr, addr_size: *os.socklen_t, flags: u32) os.AcceptError!os.fd_t {
    return os.accept(sock, addr, addr_size, flags);
}

pub fn read(fd: os.fd_t, bytes: []u8) os.ReadError!usize {
    return os.read(fd, bytes);
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
