const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;

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
    defer stopped.* = true;

    var signal = try pike.Signal.init(.{ .interrupt = true });
    defer signal.deinit();

    try notifier.register(&signal.handle, .{ .read = true });

    std.debug.print("Press Ctrl+C.\n", .{});

    try signal.wait();

    std.debug.print("Do it again!\n", .{});

    try signal.wait();

    std.debug.print("I promise; one more time.\n", .{});

    try signal.wait();
}
