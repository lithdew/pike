pub usingnamespace @import("os.zig");

pub usingnamespace @import("driver.zig");

pub usingnamespace @import("handle.zig");
pub usingnamespace @import("stream.zig");

pub usingnamespace @import("tcp.zig");
pub usingnamespace @import("signal.zig");

const std = @import("std");

pub fn init() !void {
    if (std.builtin.os.tag == .windows) _ = try std.os.windows.WSAStartup(2, 2);
}

pub fn deinit() void {
    if (std.builtin.os.tag == .windows) std.os.windows.WSACleanup() catch {};
}
