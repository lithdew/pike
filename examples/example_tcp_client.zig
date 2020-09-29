const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;

const pike = @import("pike");

pub fn loop(driver: *pike.Driver, stopped: *bool) callconv(.Async) !void {
    defer stopped.* = true;

    var socket = pike.TCP.init(driver);

    try socket.connect(try net.Address.parseIp("127.0.0.1", 9000));
    defer socket.close();

    std.debug.print("Connected!\n", .{});

    var buf: [65536]u8 = undefined;
    while (true) {
        const n = try socket.write(&buf);
    }
}

pub fn main() !void {
    var driver = try pike.Driver.init();
    defer driver.deinit();

    var stopped = false;

    var frame = async loop(&driver, &stopped);

    while (!stopped) {
        try driver.poll(10000);
    }

    try nosuspend await frame;
}
