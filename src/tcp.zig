const std = @import("std");
const os = std.os;
const net = std.net;
const mem = std.mem;

const pike = @import("pike.zig");

const Self = @This();

file: pike.File = .{},

pub usingnamespace pike.Handle(Self);
pub usingnamespace pike.Stream(Self);

pub fn bind(self: *Self, poller: *pike.Driver, address: net.Address) !void {
    self.file.handle = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC | os.SOCK_NONBLOCK, os.IPPROTO_TCP);
    errdefer os.close(self.file.handle);

    try poller.register(&self.file, .{ .read = true, .write = true });

    // TODO(kenta): do not set SO_REUSEADDR by default
    try os.setsockopt(self.file.handle, os.SOL_SOCKET, os.SO_REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try os.bind(self.file.handle, &address.any, address.getOsSockLen());
}

pub fn connect(self: *Self, poller: *pike.Driver, address: net.Address) callconv(.Async) !void {
    self.file.handle = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC | os.SOCK_NONBLOCK, os.IPPROTO_TCP);
    errdefer os.close(self.file.handle);

    try poller.register(&self.file, .{ .read = true, .write = true });

    os.connect(self.file.handle, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {},
        else => return err,
    };

    self.file.waker.wait(.{ .write = true });

    try os.getsockoptError(self.file.handle);

    if (self.file.waker.next(.{ .write = true })) |node| {
        resume node.frame;
    }
}
