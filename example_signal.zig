const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const log = std.log;

pub fn main() !void {
    try pike.init();
    defer pike.deinit();

    const notifier = try pike.Notifier.init();
    defer notifier.deinit();

    var stopped = false;

    var frame = async run(&notifier, &stopped);

    while (!stopped) {
        try notifier.poll(10_000);
    }

    try nosuspend await frame;
}

fn run(notifier: *const pike.Notifier, stopped: *bool) !void {
    var event = try pike.Event.init();
    defer event.deinit();

    try event.registerTo(notifier);

    var signal = try pike.Signal.init(.{ .interrupt = true });
    defer signal.deinit();

    defer {
        stopped.* = true;
        event.post() catch unreachable;
    }

    log.info("Press Ctrl+C.", .{});

    try signal.wait();

    log.info("Do it again!", .{});

    try signal.wait();

    log.info("I promise; one more time.", .{});

    try signal.wait();
}
