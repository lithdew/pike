const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const windows = os.windows;
const ws2_32 = windows.ws2_32;

const net = std.net;
const mem = std.mem;
const builtin = std.builtin;

const Self = @This();

handle: pike.Handle,

pub usingnamespace pike.Stream(Self);

pub fn init(driver: *pike.Driver) Self {
    return Self{ .handle = .{ .inner = windows.INVALID_HANDLE_VALUE, .driver = driver } };
}

pub fn deinit(self: *Self) void {
    self.handle.close();
}

pub fn bind(self: *Self, address: net.Address) !void {
    self.handle.inner = try os.socket(address.any.family, os.SOCK_STREAM, os.IPPROTO_TCP);
    errdefer os.close(self.handle.inner);

    var flag: c_ulong = 1;
    if (ws2_32.ioctlsocket(@ptrCast(ws2_32.SOCKET, self.handle.inner), ws2_32.FIONBIO, &flag) != 0) {
        return windows.unexpectedWSAError(ws2_32.WSAGetLastError());
    }

    try self.handle.driver.register(&self.handle, .{ .read = true, .write = true });

    // TODO(kenta): do not set SO_REUSEADDR by default
    try pike.os.setsockopt(self.handle.inner, pike.os.SOL_SOCKET, pike.os.SO_REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try pike.os.bind(self.handle.inner, &address.any, address.getOsSockLen());
}

pub fn shutdown(self: *Self, how: i32) !void {
    const rc = os.system.shutdown(self.handle.inner, how);
    switch (os.errno(rc)) {
        0 => return,
        os.EBADF => unreachable,
        os.EINVAL => return error.UnknownShutdownMethod,
        os.ENOTCONN => return error.SocketNotConnected,
        os.ENOTSOCK => return error.FileDescriptorNotSocket,
        else => unreachable,
    }
}

pub fn connect(self: *Self, address: net.Address) callconv(.Async) !void {
    self.handle.inner = try os.socket(address.any.family, os.SOCK_STREAM, os.IPPROTO_TCP);
    errdefer os.close(self.handle.inner);

    var flag: c_ulong = 1;
    if (ws2_32.ioctlsocket(@ptrCast(ws2_32.SOCKET, self.handle.inner), ws2_32.FIONBIO, &flag) != 0) {
        return windows.unexpectedWSAError(ws2_32.WSAGetLastError());
    }

    try self.handle.driver.register(&self.handle, .{ .read = true, .write = true });

    pike.os.connect(@ptrCast(os.socket_t, self.handle.inner), &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {},
        else => return err,
    };

    self.handle.waker.wait(.{ .write = true });

    try pike.os.getsockoptError(self.handle.inner);

    self.handle.schedule(.{ .write = true });
}
