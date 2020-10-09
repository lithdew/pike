const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;

pub const File = struct {
    const Self = @This();

    handle: os.fd_t,
    driver: *pike.Driver,
    waker: pike.Waker = .{},

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

    pub fn close(self: *Self) void {
        os.close(self.handle);
    }
};
