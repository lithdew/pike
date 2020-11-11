const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const net = std.net;

pub fn main() !void {
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

    var socket = try pike.Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
    defer socket.deinit();

    try notifier.register(&socket.handle, .{ .read = true, .write = true });

    try socket.set(.reuse_address, true);
    try socket.bind(try net.Address.parseIp("127.0.0.1", 9000));
    try socket.listen(128);

    var client = try socket.accept();
    defer client.deinit();

    try notifier.register(&client.handle, .{ .read = true, .write = true });

    var buf: [65536]u8 = undefined;
    while (true) {
        _ = try client.send(&buf, 0);
    }
}

fn runBenchmarkClient(notifier: *const pike.Notifier, stopped: *bool) !void {
    defer stopped.* = true;

    var socket = try pike.Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
    defer socket.deinit();

    try notifier.register(&socket.handle, .{ .read = true, .write = true });

    try socket.connect(try net.Address.parseIp("127.0.0.1", 9000));

    var buf: [65536]u8 = undefined;
    while (true) {
        _ = try socket.recv(&buf, 0);
    }
}
