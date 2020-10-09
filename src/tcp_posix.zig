const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const net = std.net;
const mem = std.mem;
const builtin = std.builtin;

const Self = @This();

file: pike.File,

pub usingnamespace pike.Stream(Self);

pub fn init(driver: *pike.Driver) Self {
    return Self{ .file = .{ .handle = -1, .driver = driver } };
}

pub fn deinit(self: *Self) void {
    self.file.close();
}

pub fn bind(self: *Self, address: net.Address) !void {
    self.file.handle = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC | os.SOCK_NONBLOCK, os.IPPROTO_TCP);
    errdefer os.close(self.file.handle);

    try self.file.driver.register(&self.file, .{ .read = true, .write = true });

    // TODO(kenta): do not set SO_REUSEADDR by default
    try pike.os.setsockopt(self.file.handle, pike.os.SOL_SOCKET, pike.os.SO_REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try pike.os.bind(self.file.handle, &address.any, address.getOsSockLen());
}

pub fn shutdown(self: *Self, how: i32) !void {
    const rc = os.system.shutdown(self.file.handle, how);
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
    self.file.handle = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC | os.SOCK_NONBLOCK, os.IPPROTO_TCP);
    errdefer os.close(self.file.handle);

    try self.file.driver.register(&self.file, .{ .read = true, .write = true });

    os.connect(@ptrCast(os.socket_t, self.file.handle), &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {},
        else => return err,
    };

    self.file.waker.wait(.{ .write = true });

    try pike.os.getsockoptError(self.file.handle);

    self.file.schedule(.{ .write = true });
}
