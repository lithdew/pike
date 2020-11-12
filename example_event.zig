const std = @import("std");
const pike = @import("pike.zig");

pub fn main() !void {
    try pike.init();
    defer pike.deinit();

    const notifier = try pike.Notifier.init();
    defer notifier.deinit();

    var event = try pike.Event.init();
    defer event.deinit();

    try event.registerTo(&notifier);

    var frame: @Frame(pike.Event.post) = undefined;

    frame = async event.post();
    try notifier.poll(10_000);
    try nosuspend await frame;

    std.debug.print("Drove the poller once.\n", .{});

    frame = async event.post();
    try notifier.poll(10_000);
    try nosuspend await frame;

    std.debug.print("Drove the poller twice!\n", .{});

    frame = async event.post();
    try notifier.poll(10_000);
    try nosuspend await frame;

    std.debug.print("Drove the poller thrice!\n", .{});

    try notifier.poll(100);

    std.debug.print("This time the poller wasn't driven - it timed out after 100ms.\n", .{});
}
