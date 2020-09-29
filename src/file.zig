const os = @import("std").os;
const pike = @import("pike.zig");
const Waker = pike.Waker;

fn schedule(file: *File, frame: anyframe) void {
    resume frame;
}

pub const File = struct {
    const Self = @This();

    schedule: fn (*File, anyframe) void = schedule,
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
