const std = @import("std");
const os = std.os.windows;

const pike = @import("pike.zig");

const Self = @This();

handle: os.HANDLE = os.INVALID_HANDLE_VALUE,

pub fn init(self: *Self) !void {
    const handle = try os.CreateIoCompletionPort(os.INVALID_HANDLE_VALUE, null, undefined, std.math.maxInt(os.DWORD));
    errdefer os.CloseHandle(handle);

    self.* = .{ .handle = handle };
}

pub fn deinit(self: *Self) void {
    os.CloseHandle(self.handle);
}

pub fn register(self: *Self, file: *pike.File) !void {
    // TODO(kenta): implement
}

pub fn poll(self: *Self, timeout: i32) !void {
    // TODO(kenta): implement
}
