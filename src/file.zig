const os = @import("std").os;
const pike = @import("pike.zig");
const Waker = pike.Waker;

pub const File = struct {
    handle: os.fd_t = undefined,
    waker: Waker = .{},
};

pub fn Handle(comptime Self: type) type {
    return struct {
        pub fn close(self: *Self) void {
            os.close(self.file.handle);
        }
    };
}
