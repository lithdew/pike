const std = @import("std");
const os = std.os;
const builtin = std.builtin;
const pike = @import("pike.zig");

pub const File = struct {
    const Overlapped = if (builtin.os.tag == .windows) os.windows.OVERLAPPED else void;

    const Self = @This();

    handle: os.fd_t,
    driver: *pike.Driver,
    waker: pike.Waker = .{},

    overlapped: Overlapped = blk: {
        if (builtin.os.tag == .windows) {
            break :blk .{
                .Internal = 0,
                .InternalHigh = 0,
                .Offset = 0,
                .OffsetHigh = 0,
                .hEvent = null,
            };
        } else {
            break :blk {};
        }
    },

    pub fn trigger(self: *Self, comptime event: pike.Event) void {
        if (self.waker.set(event)) |node| {
            self.driver.executor(self, node.frame);
        }
    }

    pub fn schedule(self: *Self, comptime event: pike.Event) void {
        if (self.waker.next(event)) |node| {
            self.driver.executor(self, node.frame);
        }
    }
};

pub fn Handle(comptime Self: type) type {
    return struct {
        pub fn close(self: *Self) void {
            os.close(self.file.handle);
        }
    };
}
