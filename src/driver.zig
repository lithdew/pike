const builtin = @import("builtin");

pub const Driver = switch (builtin.os.tag) {
    .linux => @import("driver_epoll.zig"),
    .macosx, .ios, .watchos, .tvos, .freebsd, .netbsd, .dragonfly => @import("driver_kqueue.zig"),
    .windows => @import("driver_iocp.zig"),
    else => @compileError("Unsupported OS"),
};
