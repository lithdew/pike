const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const net = std.net;

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

    const address = try net.Address.parseIp("127.0.0.1", 9000);

    var socket = try pike.Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
    defer socket.deinit();

    try socket.registerTo(notifier);
    try socket.connect(address);

    std.debug.print("Connected to: {}\n", .{address});

    var buf: [1024]u8 = undefined;
    var n: usize = undefined;

    n = try socket.read(&buf);
    if (n == 0) return;
    std.debug.print("Got: {}", .{buf[0..n]});

    n = try socket.read(&buf);
    if (n == 0) return;
    std.debug.print("Got: {}", .{buf[0..n]});

    _ = try socket.write("Hello world!\n");
    _ = try socket.send("Hello world!\n", 0);
}
