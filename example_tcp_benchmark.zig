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

    var server_frame = async runBenchmarkServer(&notifier, &stopped);
    var client_frame = async runBenchmarkClient(&notifier, &stopped);

    while (!stopped) {
        try notifier.poll(10_000);
    }

    try nosuspend await server_frame;
    try nosuspend await client_frame;
}

fn runBenchmarkServer(notifier: *const pike.Notifier, stopped: *bool) !void {
    defer stopped.* = true;

    const address = try net.Address.parseIp("127.0.0.1", 9000);

    var socket = try pike.Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
    defer socket.deinit();

    try socket.registerTo(notifier);

    try socket.set(.reuse_address, true);
    try socket.bind(address);
    try socket.listen(128);

    var client = try socket.accept();
    defer client.deinit();

    try client.registerTo(notifier);

    var buf: [65536]u8 = undefined;
    while (true) {
        _ = try client.send(&buf, 0);
    }
}

fn runBenchmarkClient(notifier: *const pike.Notifier, stopped: *bool) !void {
    defer stopped.* = true;

    const address = try net.Address.parseIp("127.0.0.1", 9000);

    var socket = try pike.Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
    defer socket.deinit();

    try socket.registerTo(notifier);

    try socket.connect(address);

    var buf: [65536]u8 = undefined;
    while (true) {
        _ = try socket.recv(&buf, 0);
    }
}
