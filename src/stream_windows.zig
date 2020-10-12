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
            try pike.os.listen(self.handle.inner, backlog);
        }

        pub fn accept(self: *Self) callconv(.Async) !Connection {
            var address: net.Address = undefined;
            var address_len: os.socklen_t = @sizeOf(net.Address);

            while (true) {
                const handle = pike.os.accept(self.handle.inner, &address.any, &address_len, os.SOCK_NONBLOCK | os.SOCK_CLOEXEC) catch |err| switch (err) {
                    error.WouldBlock => {
                        self.handle.waker.wait(.{ .read = true });
                        continue;
                    },
                    else => return err,
                };

                self.handle.schedule(.{ .read = true });

                // The non-blocking state of `listener` is inherited. See
                // https://docs.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-accept#remarks.

                return Connection{ .address = address, .stream = Self{ .handle = pike.Handle{ .inner = handle, .driver = self.handle.driver } } };
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

            pike.os.ReadFile(self.handle.inner, buf, &overlapped) catch |err| switch (err) {
                error.WouldBlock => self.handle.waker.wait(.{ .read = true }),
                else => return err,
            };

            self.handle.schedule(.{ .read = true });

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

            pike.os.WriteFile(self.handle.inner, buf, &overlapped) catch |err| switch (err) {
                error.WouldBlock => self.handle.waker.wait(.{ .write = true }),
                else => return err,
            };

            self.handle.schedule(.{ .write = true });

            return overlapped.InternalHigh;
        }
    };
}
