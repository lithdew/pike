const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const net = std.net;

pub fn Stream(comptime Self: type) type {
    const Connection = pike.Connection(Self);

    return struct {
        pub fn listen(self: *Self, backlog: u32) !void {
            try pike.os.listen(self.file.handle, backlog);
        }

        pub fn accept(self: *Self) callconv(.Async) !Connection {
            var address: net.Address = undefined;
            var address_len: os.socklen_t = @sizeOf(net.Address);

            while (true) {
                const handle = pike.os.accept(self.file.handle, &address.any, &address_len, os.SOCK_NONBLOCK | os.SOCK_CLOEXEC) catch |err| switch (err) {
                    error.WouldBlock => {
                        self.file.waker.wait(.{ .read = true });
                        continue;
                    },
                    else => return err,
                };

                self.file.schedule(.{ .read = true });

                return Connection{ .address = address, .stream = Self{ .file = pike.Handle{ .handle = handle, .driver = self.file.driver } } };
            }
        }

        pub fn read(self: *Self, buf: []u8) callconv(.Async) !usize {
            while (true) {
                const n = pike.os.read(self.file.handle, buf) catch |err| switch (err) {
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
                const n = pike.os.write(self.file.handle, buf) catch |err| switch (err) {
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
