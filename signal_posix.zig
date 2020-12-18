const std = @import("std");
const pike = @import("pike.zig");
const posix = @import("os/posix.zig");

const os = std.os;
const system = os.system;

const mem = std.mem;
const meta = std.meta;
const builtin = std.builtin;

usingnamespace @import("waker.zig");

pub const SignalType = packed struct {
    terminate: bool = false,
    interrupt: bool = false,
    quit: bool = false,
    hup: bool = false,

    fn toSet(self: SignalType) os.sigset_t {
        const sigaddset = if (comptime std.Target.current.isDarwin()) system.sigaddset else os.linux.sigaddset;

        var set = mem.zeroes(os.sigset_t);
        if (self.terminate) sigaddset(&set, os.SIGTERM);
        if (self.interrupt) sigaddset(&set, os.SIGINT);
        if (self.quit) sigaddset(&set, os.SIGQUIT);
        if (self.hup) sigaddset(&set, os.SIGHUP);

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

    var lock: std.Mutex = .{};
    var mask: SignalType = .{};
    var waker: PackedWaker(pike.Task, SignalType) = .{};

    current: SignalType,
    previous: [@bitSizeOf(SignalType)]os.Sigaction,

    fn handler(signal: c_int) callconv(.C) void {
        const current_held = lock.acquire();
        const current_mask = mask;
        current_held.release();

        switch (signal) {
            os.SIGTERM => {
                if (!current_mask.terminate) return;

                const held = lock.acquire();
                const next_node = waker.wake(.{ .terminate = true });
                held.release();

                if (next_node) |node| pike.dispatch(&node.data, .{});
            },
            os.SIGINT => {
                if (!current_mask.interrupt) return;

                const held = lock.acquire();
                const next_node = waker.wake(.{ .interrupt = true });
                held.release();

                if (next_node) |node| pike.dispatch(&node.data, .{});
            },
            os.SIGQUIT => {
                if (!current_mask.quit) return;

                const held = lock.acquire();
                const next_node = waker.wake(.{ .quit = true });
                held.release();

                if (next_node) |node| pike.dispatch(&node.data, .{});
            },
            os.SIGHUP => {
                if (!current_mask.hup) return;

                const held = lock.acquire();
                const next_node = waker.wake(.{ .hup = true });
                held.release();

                if (next_node) |node| pike.dispatch(&node.data, .{});
            },
            else => {},
        }
    }

    pub fn init(current: SignalType) !Self {
        const held = lock.acquire();
        defer held.release();

        const new_mask = @bitCast(SignalType, @bitCast(MaskInt, current) | @bitCast(MaskInt, mask));

        const sigaction = os.Sigaction{
            .handler = .{ .handler = handler },
            .mask = new_mask.toSet(),
            .flags = 0,
        };

        var previous = [_]os.Sigaction{EMPTY_SIGACTION} ** @bitSizeOf(SignalType);

        os.sigaction(os.SIGTERM, &sigaction, &previous[std.meta.fieldIndex(SignalType, "terminate").?]);
        os.sigaction(os.SIGINT, &sigaction, &previous[std.meta.fieldIndex(SignalType, "interrupt").?]);
        os.sigaction(os.SIGQUIT, &sigaction, &previous[std.meta.fieldIndex(SignalType, "quit").?]);
        os.sigaction(os.SIGHUP, &sigaction, &previous[std.meta.fieldIndex(SignalType, "hup").?]);

        mask = new_mask;

        return Self{
            .current = current,
            .previous = previous,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.previous) |sigaction, i| {
            os.sigaction(
                switch (i) {
                    0 => os.SIGTERM,
                    1 => os.SIGINT,
                    2 => os.SIGQUIT,
                    3 => os.SIGHUP,
                    else => unreachable,
                },
                &sigaction,
                null,
            );
        }
    }

    pub fn wait(self: *Self) callconv(.Async) !void {
        const held = lock.acquire();
        if (waker.wait(self.current)) {
            held.release();
        } else {
            suspend {
                var node = @TypeOf(waker).FrameNode{ .data = pike.Task.init(@frame()) };
                @TypeOf(waker).FrameList.append(&waker.heads, self.current, &node);
                held.release();
            }

            const next_held = lock.acquire();
            const next_node = waker.next(self.current);
            next_held.release();

            if (next_node) |node| {
                pike.dispatch(&node.data, .{});
            }
        }
    }
};
