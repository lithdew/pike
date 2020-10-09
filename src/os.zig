const pike = @import("pike.zig");

pub const os = switch (pike.driver_type) {
    .epoll, .kqueue => @import("os_posix.zig"),
    .iocp => @import("os_windows.zig"),
    else => @compileError("Unsupported OS"),
};
