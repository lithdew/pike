const os = @import("std").os;
const pike = @import("pike.zig");

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
};

pub fn Handle(comptime Self: type) type {
    return struct {
        pub fn close(self: *Self) void {
            os.close(self.file.handle);
        }
    };
}
