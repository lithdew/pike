const std = @import("std");
const os = std.os;
const net = std.net;

const pike = @import("pike.zig");

pub fn Connection(comptime Self: type) type {
    return struct {
        address: net.Address,
        stream: Self,
    };
}

pub fn Stream(comptime Self: type) type {
    return struct {
        pub fn listen(self: *Self, backlog: u32) !void {
            try os.listen(self.file.handle, backlog);
        }

        pub fn accept(self: *Self) callconv(.Async) !Connection(Self) {
            var address: net.Address = undefined;
            var address_len: os.socklen_t = @sizeOf(net.Address);

            while (true) {
                const handle = os.accept(self.file.handle, &address.any, &address_len, os.SOCK_NONBLOCK | os.SOCK_CLOEXEC) catch |err| switch (err) {
                    error.WouldBlock => {
                        self.file.waker.wait(.{ .read = true });
                        continue;
                    },
                    else => return err,
                };

                self.file.schedule(.{ .read = true });

                return Connection(Self){ .address = address, .stream = Self{ .file = pike.File{ .handle = handle, .driver = self.file.driver } } };
            }
        }

        pub fn read(self: *Self, buf: []u8) callconv(.Async) !usize {
            while (true) {
                const n = os.read(self.file.handle, buf) catch |err| switch (err) {
                    error.WouldBlock => {
                        self.file.waker.wait(.{ .read = true });
                        continue;
                    },
                    else => return err,
                };

                self.file.schedule(.{ .read = true });

                return n;
            }
        }

        pub fn write(self: *Self, buf: []const u8) callconv(.Async) !usize {
            while (true) {
                const n = os.write(self.file.handle, buf) catch |err| switch (err) {
                    error.WouldBlock => {
                        self.file.waker.wait(.{ .write = true });
                        continue;
                    },
                    else => return err,
                };

                self.file.schedule(.{ .write = true });

                return n;
            }
        }

        pub fn send(self: *Self, buf: []const u8) callconv(.Async) !usize {
            while (true) {
                const n = os.send(self.file.handle, buf, 0) catch |err| switch (err) {
                    error.WouldBlock => {
                        self.file.waker.wait(.{ .write = true });
                        continue;
                    },
                    else => return err,
                };

                self.file.schedule(.{ .write = true });

                return n;
            }
        }
    };
}
