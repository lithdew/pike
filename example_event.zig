const std = @import("std");
const pike = @import("pike.zig");

const log = std.log;

pub fn main() !void {
    try pike.init();
    defer pike.deinit();

    const notifier = try pike.Notifier.init();
    defer notifier.deinit();

    var event = try pike.Event.init();
    defer nosuspend event.deinit();

    try event.registerTo(&notifier);

    var frame: @Frame(pike.Event.post) = undefined;

    frame = async event.post();
    try notifier.poll(10_000);
    try nosuspend await frame;

    log.info("Drove the poller once.", .{});

    frame = async event.post();
    try notifier.poll(10_000);
    try nosuspend await frame;

    log.info("Drove the poller twice!", .{});

    frame = async event.post();
    try notifier.poll(10_000);
    try nosuspend await frame;

    log.info("Drove the poller thrice!", .{});

    try notifier.poll(100);

    log.info("This time the poller wasn't driven - it timed out after 100ms.", .{});
}
