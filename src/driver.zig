const builtin = @import("builtin");
const pike = @import("pike.zig");

pub const Driver = switch (builtin.os.tag) {
    .linux => @import("driver_epoll.zig"),
    .macosx, .ios, .watchos, .tvos, .freebsd, .netbsd, .dragonfly => @import("driver_kqueue.zig"),
    .windows => @import("driver_iocp.zig"),
    else => @compileError("Unsupported OS"),
};

pub const DriverOptions = struct {
    executor: Executor = defaultExecutor,
};

pub const Event = packed struct {
    read: bool = false,
    write: bool = false,
};

pub const Executor = fn (*pike.File, frame: anyframe) void;

pub fn defaultExecutor(file: *pike.File, frame: anyframe) void {
    resume frame;
}
