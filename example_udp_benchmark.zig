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

    var socket = try pike.Socket.init(os.AF.INET, os.SOCK.DGRAM, 0, 0);
    defer socket.deinit();

    try socket.registerTo(notifier);

    try socket.set(.reuse_address, true);
    try socket.bind(address);

    var buf: [1400]u8 = undefined;
    while (true) {
        _ = try socket.recvFrom(&buf, 0, null);
    }
}

fn runBenchmarkClient(notifier: *const pike.Notifier, stopped: *bool) !void {
    defer stopped.* = true;

    const address = try net.Address.parseIp("127.0.0.1", 9000);

    var socket = try pike.Socket.init(os.AF.INET, os.SOCK.DGRAM, 0, 0);
    defer socket.deinit();

    try socket.registerTo(notifier);

    var buf: [1400]u8 = undefined;
    while (true) {
        _ = try socket.sendTo(&buf, 0, address);
    }
}
