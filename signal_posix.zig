const std = @import("std");
const pike = @import("pike.zig");
const posix = @import("os/posix.zig");
const PackedWaker = @import("waker.zig").PackedWaker;
const os = std.os;
const system = os.system;

const mem = std.mem;
const meta = std.meta;
const builtin = @import("builtin");

pub const SignalType = packed struct {
    terminate: bool = false,
    interrupt: bool = false,
    quit: bool = false,
    hup: bool = false,

    fn toSet(self: SignalType) os.sigset_t {
        const sigaddset = if (comptime builtin.target.isDarwin()) system.sigaddset else os.linux.sigaddset;

        var set = mem.zeroes(os.sigset_t);
        if (self.terminate) sigaddset(&set, os.SIG.TERM);
        if (self.interrupt) sigaddset(&set, os.SIG.INT);
        if (self.quit) sigaddset(&set, os.SIG.QUIT);
        if (self.hup) sigaddset(&set, os.SIG.HUP);

        return set;
    }
};

pub const Signal = struct {
    const EMPTY_SIGACTION = os.Sigaction{
        .handler = .{ .handler = null },
        .mask = mem.zeroes(os.sigset_t),
        .flags = 0,
    };

    const MaskInt = meta.Int(.unsigned, @bitSizeOf(SignalType));
    const Self = @This();

    var lock: std.Thread.Mutex = .{};
    var mask: SignalType = .{};
    var waker: PackedWaker(pike.Task, SignalType) = .{};

    current: SignalType,
    previous: [@bitSizeOf(SignalType)]os.Sigaction,

    fn handler(signal: c_int) callconv(.C) void {
        const current_held = lock.lock();
        _=current_held;
        const current_mask = mask;
        lock.unlock();
        //current_held.release();

        switch (signal) {
            os.SIG.TERM => {
                if (!current_mask.terminate) return;

                const held = lock.lock();
                _=held;
                const next_node = waker.wake(.{ .terminate = true });
                lock.unlock();
                //held.release();

                if (next_node) |node| pike.dispatch(&node.data, .{});
            },
            os.SIG.INT => {
                if (!current_mask.interrupt) return;

                const held = lock.lock();
                              _=held;
                const next_node = waker.wake(.{ .interrupt = true });
                lock.unlock();
                //held.release();

                if (next_node) |node| pike.dispatch(&node.data, .{});
            },
            os.SIG.QUIT => {
                if (!current_mask.quit) return;

                const held = lock.lock();
                _=held;
                const next_node = waker.wake(.{ .quit = true });
                lock.unlock();
                //held.release();

                if (next_node) |node| pike.dispatch(&node.data, .{});
            },
            os.SIG.HUP => {
                if (!current_mask.hup) return;

                const held = lock.lock();
                _=held;
                const next_node = waker.wake(.{ .hup = true });
                lock.unlock();
                //held.release();

                if (next_node) |node| pike.dispatch(&node.data, .{});
            },
            else => {},
        }
    }

    pub fn init(current: SignalType) !Self {
        const held = lock.lock();
        _=held;
        defer lock.unlock();

        const new_mask = @bitCast(SignalType, @bitCast(MaskInt, current) | @bitCast(MaskInt, mask));

        const sigaction = os.Sigaction{
            .handler = .{ .handler = handler },
            .mask = new_mask.toSet(),
            .flags = 0,
        };

        var previous = [_]os.Sigaction{EMPTY_SIGACTION} ** @bitSizeOf(SignalType);

        os.sigaction(os.SIG.TERM, &sigaction, &previous[std.meta.fieldIndex(SignalType, "terminate").?]);
        os.sigaction(os.SIG.INT, &sigaction, &previous[std.meta.fieldIndex(SignalType, "interrupt").?]);
        os.sigaction(os.SIG.QUIT, &sigaction, &previous[std.meta.fieldIndex(SignalType, "quit").?]);
        os.sigaction(os.SIG.HUP, &sigaction, &previous[std.meta.fieldIndex(SignalType, "hup").?]);

        mask = new_mask;

        return Self{
            .current = current,
            .previous = previous,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.previous, 0..) |sigaction, i| {
            os.sigaction(
                switch (i) {
                    0 => os.SIG.TERM,
                    1 => os.SIG.INT,
                    2 => os.SIG.QUIT,
                    3 => os.SIG.HUP,
                    else => unreachable,
                },
                &sigaction,
                null,
            );
        }
    }

    pub fn wait(self: *Self) callconv(.Async) !void {
        const held = lock.lock();
        _=held;
        if (waker.wait(self.current)) {
            lock.unlock();
            //held.release();
        } else {
            suspend {
                var node = @TypeOf(waker).FrameNode{ .data = pike.Task.init(@frame()) };
                @TypeOf(waker).FrameList.append(&waker.heads, self.current, &node);
                lock.unlock();
                //held.release();
            }

            const next_held = lock.lock();
                          _=next_held;
            const next_node = waker.next(self.current);
            lock.unlock();
            //next_held.release();

            if (next_node) |node| {
                pike.dispatch(&node.data, .{});
            }
        }
    }
};
