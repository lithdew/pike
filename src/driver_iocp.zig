const std = @import("std");
const os = std.os.windows;

const pike = @import("pike.zig");

const Self = @This();

executor: pike.Executor = pike.defaultExecutor,
handle: os.HANDLE = os.INVALID_HANDLE_VALUE,

pub fn init() !Self {
    const handle = try os.CreateIoCompletionPort(os.INVALID_HANDLE_VALUE, null, undefined, std.math.maxInt(os.DWORD));
    errdefer os.CloseHandle(handle);

    return Self{ .handle = handle };
}

pub fn deinit(self: *Self) void {
    os.CloseHandle(self.handle);
}

pub fn register(self: *Self, file: *pike.File, comptime event: pike.Event) !void {
    // TODO(kenta): implement
}

pub fn poll(self: *Self, timeout: i32) !void {
    // TODO(kenta): implement
}
