const std = @import("std");
const pike = @import("pike.zig");
const windows = @import("os/windows.zig");

const math = std.math;
const meta = std.meta;

usingnamespace @import("waker.zig");

pub const SignalType = packed struct {
    terminate: bool = false,
    interrupt: bool = false,
    quit: bool = false,
    hup: bool = false,
};

pub const Signal = struct {
    const MaskInt = meta.Int(.unsigned, @bitSizeOf(SignalType));

    const Data = struct {
        port: windows.HANDLE,
        overlapped: pike.Overlapped,
    };

    const Self = @This();

    var refs: u64 = 0;
    var mask: u64 = 0;

    var lock: std.Mutex = .{};
    var waker: PackedWaker(*Data, SignalType) = .{};

    port: windows.HANDLE,
    current_signal: SignalType,
    previous_signal: u64,

    fn handler(signal: windows.DWORD) callconv(.C) windows.BOOL {
        const current = @bitCast(SignalType, @truncate(MaskInt, @atomicLoad(u64, &mask, .SeqCst)));

        return blk: {
            switch (signal) {
                windows.CTRL_C_EVENT, windows.CTRL_BREAK_EVENT => {
                    if (!current.interrupt and !current.terminate) break :blk windows.FALSE;
                    if (waker.wake(&lock, .{ .interrupt = true, .terminate = true })) |data| {
                        windows.PostQueuedCompletionStatus(data.port, 0, 0, &data.overlapped.inner) catch unreachable;
                    }
                    break :blk windows.TRUE;
                },
                windows.CTRL_CLOSE_EVENT => {
                    if (!current.hup) break :blk windows.FALSE;
                    if (waker.wake(&lock, .{ .hup = true })) |data| {
                        windows.PostQueuedCompletionStatus(data.port, 0, 0, &data.overlapped.inner) catch unreachable;
                    }
                    break :blk windows.TRUE;
                },
                windows.CTRL_LOGOFF_EVENT, windows.CTRL_SHUTDOWN_EVENT => {
                    if (!current.quit) break :blk windows.FALSE;
                    if (waker.wake(&lock, .{ .quit = true })) |data| {
                        windows.PostQueuedCompletionStatus(data.port, 0, 0, &data.overlapped.inner) catch unreachable;
                    }
                    break :blk windows.TRUE;
                },
                else => break :blk windows.FALSE,
            }
        };
    }

    pub fn init(current_signal: SignalType) !Self {
        errdefer _ = @atomicRmw(u64, &refs, .Sub, 1, .SeqCst);

        if (@atomicRmw(u64, &refs, .Add, 1, .SeqCst) == 0) {
            try windows.SetConsoleCtrlHandler(handler, true);
        }

        const previous_signal = @atomicRmw(u64, &mask, .Or, @intCast(u64, @bitCast(MaskInt, current_signal)), .SeqCst);

        return Self{
            .port = windows.INVALID_HANDLE_VALUE,
            .current_signal = current_signal,
            .previous_signal = previous_signal,
        };
    }

    pub fn deinit(self: *const Self) void {
        @atomicStore(u64, &mask, self.previous_signal, .SeqCst);
        if (@atomicRmw(u64, &refs, .Sub, 1, .SeqCst) == 1) {
            windows.SetConsoleCtrlHandler(handler, false) catch unreachable;
            while (waker.wake(&lock, @bitCast(SignalType, @as(MaskInt, math.maxInt(MaskInt))))) |data| {
                pike.dispatch(pike.scope, data.overlapped.frame);
            }
        }
    }

    pub fn registerTo(self: *Self, notifier: *const pike.Notifier) !void {
        self.port = notifier.handle;
    }

    pub fn wait(self: *const Self) callconv(.Async) !void {
        if (self.port == windows.INVALID_HANDLE_VALUE) return error.NotRegistered;

        defer if (waker.next(&lock, self.current_signal)) |data| pike.dispatch(pike.scope, data.overlapped.frame);

        var data = Data{
            .port = self.port,
            .overlapped = pike.Overlapped.init(undefined),
        };

        waker.wait(&lock, self.current_signal, &data, &data.overlapped.frame);
    }
};
