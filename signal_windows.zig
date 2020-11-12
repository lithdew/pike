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
    const Self = @This();

    var refs: u64 = 0;
    var mask: u64 = 0;

    var lock: std.Mutex = .{};
    var waker: PackedWaker(SignalType) = .{};

    signal: SignalType,
    prev: u64 = 0,

    fn handler(signal: windows.DWORD) callconv(.C) windows.BOOL {
        const current = @bitCast(SignalType, @truncate(MaskInt, @atomicLoad(u64, &mask, .SeqCst)));

        return blk: {
            switch (signal) {
                windows.CTRL_C_EVENT, windows.CTRL_BREAK_EVENT => {
                    if (!current.interrupt and !current.terminate) break :blk windows.FALSE;
                    if (waker.wake(&lock, .{ .interrupt = true, .terminate = true })) |frame| resume frame;
                    break :blk windows.TRUE;
                },
                windows.CTRL_CLOSE_EVENT => {
                    if (!current.hup) break :blk windows.FALSE;
                    if (waker.wake(&lock, .{ .hup = true })) |frame| resume frame;
                    break :blk windows.TRUE;
                },
                windows.CTRL_LOGOFF_EVENT, windows.CTRL_SHUTDOWN_EVENT => {
                    if (!current.quit) break :blk windows.FALSE;
                    if (waker.wake(&lock, .{ .quit = true })) |frame| resume frame;
                    break :blk windows.TRUE;
                },
                else => break :blk windows.FALSE,
            }
        };
    }

    pub fn init(signal: SignalType) !Self {
        errdefer _ = @atomicRmw(u64, &refs, .Sub, 1, .SeqCst);

        if (@atomicRmw(u64, &refs, .Add, 1, .SeqCst) == 0) {
            try windows.SetConsoleCtrlHandler(handler, true);
        }

        const prev = @atomicRmw(u64, &mask, .Or, @intCast(u64, @bitCast(MaskInt, signal)), .SeqCst);

        return Self{
            .signal = signal,
            .prev = prev,
        };
    }

    pub fn deinit(self: *const Self) void {
        @atomicStore(u64, &mask, self.prev, .SeqCst);
        if (@atomicRmw(u64, &refs, .Sub, 1, .SeqCst) == 1) {
            windows.SetConsoleCtrlHandler(handler, false) catch unreachable;
            while (self.waker.next(&lock, @bitCast(SignalSet, math.maxInt(MaskInt)))) |frame| {
                resume frame;
            }
        }
    }

    pub fn registerTo(self: *const Self, notifier: *const pike.Notifier) !void {}

    pub fn wait(self: *const Self) callconv(.Async) !void {
        defer if (waker.next(&lock, self.signal)) |frame| resume frame;
        waker.wait(&lock, self.signal);
    }
};
