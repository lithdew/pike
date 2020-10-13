const builtin = @import("builtin");
const pike = @import("pike.zig");

pub const driver_type = switch (builtin.os.tag) {
    .linux => .epoll,
    .macos, .ios, .watchos, .tvos, .freebsd, .netbsd, .dragonfly => .kqueue,
    .windows => .iocp,
    else => @compileError("Unsupported OS"),
};

pub const Driver = switch (driver_type) {
    .epoll => @import("driver_epoll.zig"),
    .kqueue => @import("driver_kqueue.zig"),
    .iocp => @import("driver_iocp.zig"),
    else => @compileError("Unsupported Driver"),
};

pub const DriverOptions = struct {
    executor: Executor = defaultExecutor,
};

pub const Event = packed struct {
    read: bool = false,
    write: bool = false,
};

pub const Executor = fn (*pike.Handle, frame: anyframe) void;

pub fn defaultExecutor(file: *pike.Handle, frame: anyframe) void {
    resume frame;
}
