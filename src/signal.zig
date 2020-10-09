const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const mem = std.mem;
const builtin = std.builtin;

pub const Signal = switch (pike.driver_type) {
    .epoll => @import("signal_unix.zig"),
    .darwin => @import("signal_darwin.zig"),
    else => @compileError("Unsupported OS"),
};
