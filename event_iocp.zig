const std = @import("std");
const pike = @import("pike.zig");
const windows = @import("os/windows.zig");

pub const Event = struct {
    const Self = @This();

    port: windows.HANDLE = windows.INVALID_HANDLE_VALUE,

    pub fn init() !Self {
        return Self{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn registerTo(self: *Self, notifier: *const pike.Notifier) !void {
        self.port = notifier.handle;
    }

    pub fn post(self: *const Self) callconv(.Async) !void {
        var overlapped = pike.Overlapped.init(pike.Task.init(@frame()));

        var err: ?windows.PostQueuedCompletionStatusError = null;

        suspend {
            windows.PostQueuedCompletionStatus(self.port, 0, 0, &overlapped.inner) catch |post_err| {
                err = post_err;
                pike.dispatch(&overlapped.task, .{ .use_lifo = true });
            };
        }

        if (err) |post_err| return post_err;
    }
};
