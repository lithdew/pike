const std = @import("std");
const pike = @import("pike");

fn wait(driver: *pike.Driver, stopped: *bool) !void {
    defer stopped.* = true;

    var signal = try pike.Signal.init(driver, .{ .interrupt = true });
    defer signal.deinit();

    try driver.register(&signal.file, .{ .read = true });

    std.debug.print("Waiting for interrupt signal.\n", .{});

    try signal.wait();

    std.debug.print("Got interrupt signal! Shutting down...\n", .{});
}

pub fn main() !void {
    var driver = try pike.Driver.init(.{});
    defer driver.deinit();

    var stopped = false;
    var frame = async wait(&driver, &stopped);

    while (!stopped) {
        try driver.poll(10000);
    }

    try nosuspend await frame;
}
