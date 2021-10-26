const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const fmt = std.fmt;
const log = std.log;
const net = std.net;
const mem = std.mem;
const heap = std.heap;
const process = std.process;

fn exists(args: []const []const u8, flags: anytype) ?usize {
    inline for (flags) |flag| {
        for (args) |arg, index| {
            if (mem.eql(u8, arg, flag)) {
                return index;
            }
        }
    }
    return null;
}

pub fn main() !void {
    var gpa: heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    const allocator = &gpa.allocator;

    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    const run_server = args.len == 1 or (args.len > 1 and exists(args, .{ "server", "--server", "-server", "-s" }) != null);
    const run_client = args.len == 1 or (args.len > 1 and exists(args, .{ "client", "--client", "-client", "-c" }) != null);

    const address: net.Address = blk: {
        const default = try net.Address.parseIp("127.0.0.1", 9000);

        const index = exists(args, .{ "address", "--address", "-address", "-a" }) orelse {
            break :blk default;
        };

        if (args.len <= index + 1) break :blk default;

        var fields = mem.split(u8, args[index + 1], ":");

        const addr_host = fields.next().?;
        const addr_port = try fmt.parseInt(u16, fields.next().?, 10);

        break :blk try net.Address.parseIp(addr_host, addr_port);
    };

    try pike.init();
    defer pike.deinit();

    const notifier = try pike.Notifier.init();
    defer notifier.deinit();

    var stopped = false;
    var server_frame: @Frame(runBenchmarkServer) = undefined;
    var client_frame: @Frame(runBenchmarkClient) = undefined;

    if (run_server) server_frame = async runBenchmarkServer(&notifier, address, &stopped);
    if (run_client) client_frame = async runBenchmarkClient(&notifier, address, &stopped);

    defer if (run_server) nosuspend await server_frame catch |err| @panic(@errorName(err));
    defer if (run_client) nosuspend await client_frame catch |err| @panic(@errorName(err));

    while (!stopped) {
        try notifier.poll(10_000);
    }
}

fn runBenchmarkServer(notifier: *const pike.Notifier, address: net.Address, stopped: *bool) !void {
    defer stopped.* = true;

    var socket = try pike.Socket.init(os.AF.INET, os.SOCK.STREAM, os.IPPROTO.TCP, 0);
    defer socket.deinit();

    try socket.registerTo(notifier);

    try socket.set(.reuse_address, true);
    try socket.bind(address);
    try socket.listen(128);

    log.info("Listening for clients on: {}", .{try socket.getBindAddress()});

    var client = try socket.accept();
    defer client.socket.deinit();

    log.info("Accepted client: {}", .{client.address});

    try client.socket.registerTo(notifier);

    var buf: [1024]u8 = undefined;
    while (true) {
        _ = try client.socket.send(&buf, 0);
    }
}

fn runBenchmarkClient(notifier: *const pike.Notifier, address: net.Address, stopped: *bool) !void {
    defer stopped.* = true;

    var socket = try pike.Socket.init(os.AF.INET, os.SOCK.STREAM, os.IPPROTO.TCP, 0);
    defer socket.deinit();

    try socket.registerTo(notifier);
    try socket.connect(address);

    log.info("Connected to: {}", .{address});

    var buf: [1024]u8 = undefined;
    while (true) {
        const n = try socket.recv(&buf, 0);
        if (n == 0) return;
    }
}
