const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;

const pike = @import("pike");

pub fn loop(driver: *pike.Driver, stopped: *bool) callconv(.Async) !void {
    defer stopped.* = true;

    const address = try net.Address.parseIp("127.0.0.1", 9000);

    var listener = pike.TCP.init(driver);

    try listener.bind(address);
    defer listener.deinit();

    try listener.listen(128);

    std.debug.print("Listening for connections on: {}\n", .{address});

    var conn = try listener.accept();
    try driver.register(&conn.stream.handle, .{ .read = true, .write = true });

    std.debug.print("Client connected: {}\n", .{conn.address});

    var buf: [65536]u8 = undefined;
    while (true) {
        const n = try conn.stream.read(&buf);
        if (n == 0) return;
    }
}

pub fn main() !void {
    try pike.init();
    defer pike.deinit();

    var driver = try pike.Driver.init(.{});
    defer driver.deinit();

    var stopped = false;

    var frame = async loop(&driver, &stopped);

    while (!stopped) {
        try driver.poll(10000);
    }

    try nosuspend await frame;
}
