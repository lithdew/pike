const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const windows = os.windows;
const ws2_32 = windows.ws2_32;

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

                var flag: c_ulong = 1;
                if (ws2_32.ioctlsocket(@ptrCast(ws2_32.SOCKET, handle), ws2_32.FIONBIO, &flag) != 0) {
                    return windows.unexpectedWSAError(ws2_32.WSAGetLastError());
                }

                return Connection{ .address = address, .stream = Self{ .file = pike.File{ .handle = handle, .driver = self.file.driver } } };
            }
        }

        pub fn read(self: *Self, buf: []u8) callconv(.Async) !usize {
            var overlapped = windows.OVERLAPPED{
                .Internal = 0,
                .InternalHigh = 0,
                .Offset = 0,
                .OffsetHigh = 0,
                .hEvent = null,
            };

            pike.os.ReadFile(self.file.handle, buf, &overlapped) catch |err| switch (err) {
                error.WouldBlock => self.file.waker.wait(.{ .read = true }),
                else => return err,
            };

            self.file.schedule(.{ .read = true });

            return overlapped.InternalHigh;
        }

        pub fn write(self: *Self, buf: []const u8) callconv(.Async) !usize {
            var overlapped = windows.OVERLAPPED{
                .Internal = 0,
                .InternalHigh = 0,
                .Offset = 0,
                .OffsetHigh = 0,
                .hEvent = null,
            };

            pike.os.WriteFile(self.file.handle, buf, &overlapped) catch |err| switch (err) {
                error.WouldBlock => self.file.waker.wait(.{ .write = true }),
                else => return err,
            };

            self.file.schedule(.{ .write = true });

            return overlapped.InternalHigh;
        }
    };
}
