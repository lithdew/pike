const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const net = std.net;
const mem = std.mem;
const heap = std.heap;
const process = std.process;

pub fn main() !void {
    var gpa: heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    const allocator = &gpa.allocator;

    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    const run_server = args.len == 1 or (args.len > 1 and mem.eql(u8, args[1], "server"));
    const run_client = args.len == 1 or (args.len > 1 and mem.eql(u8, args[1], "client"));

    try pike.init();
    defer pike.deinit();

    const notifier = try pike.Notifier.init();
    defer notifier.deinit();

    var stopped = false;

    if (run_server) {
        var server_frame = async runBenchmarkServer(&notifier, &stopped);
        defer nosuspend await server_frame catch unreachable;
    }

    if (run_client) {
        var client_frame = async runBenchmarkClient(&notifier, &stopped);
        defer nosuspend await client_frame catch unreachable;
    }

    while (!stopped) {
        try notifier.poll(10_000);
    }
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

    std.debug.print("Listening for clients on: {}\n", .{address});

    var client = try socket.accept();
    defer client.socket.deinit();

    std.debug.print("Accepted client: {}\n", .{client.address});

    try client.socket.registerTo(notifier);

    var buf: [65536]u8 = undefined;
    while (true) {
        _ = try client.socket.send(&buf, 0);
    }
}

fn runBenchmarkClient(notifier: *const pike.Notifier, stopped: *bool) !void {
    defer stopped.* = true;

    const address = try net.Address.parseIp("127.0.0.1", 9000);

    var socket = try pike.Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
    defer socket.deinit();

    try socket.registerTo(notifier);
    try socket.connect(address);

    std.debug.print("Connected to: {}\n", .{address});

    var buf: [65536]u8 = undefined;
    while (true) {
        _ = try socket.recv(&buf, 0);
    }
}
