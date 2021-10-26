const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const net = std.net;
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
    defer stopped.* = true;

    const address = try net.Address.parseIp("127.0.0.1", 44123);

    var socket = try pike.Socket.init(os.AF.INET, os.SOCK.STREAM, os.IPPROTO.TCP, 0);
    defer socket.deinit();

    try socket.registerTo(notifier);
    try socket.connect(address);

    log.info("Connected to: {s}", .{address});

    var buf: [1024]u8 = undefined;
    var n: usize = undefined;

    n = try socket.read(&buf);
    if (n == 0) return;
    log.info("Got: {s}", .{buf[0..n]});

    n = try socket.read(&buf);
    if (n == 0) return;
    log.info("Got: {s}", .{buf[0..n]});

    _ = try socket.write("Hello world!\n");
    _ = try socket.send("Hello world!\n", 0);
}
