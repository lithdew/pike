const std = @import("std");
const pike = @import("pike.zig");

const net = std.net;

pub fn Connection(comptime Self: type) type {
    return struct {
        address: net.Address,
        stream: Self,
    };
}

pub usingnamespace switch (pike.driver_type) {
    .epoll, .kqueue => @import("stream_posix.zig"),
    .iocp => @import("stream_windows.zig"),
    else => @compileError("Unsupported OS"),
};
