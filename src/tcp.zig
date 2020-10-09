const pike = @import("pike.zig");

pub const TCP = switch (pike.driver_type) {
    .epoll, .kqueue => @import("tcp_posix.zig"),
    .iocp => @import("tcp_windows.zig"),
    else => @compileError("Unsupported OS"),
};
