const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const mem = std.mem;
const net = std.net;
const log = std.log;
const heap = std.heap;

pub const Client = struct {
    conn: pike.Connection,
    frame: @Frame(run),

    pub fn run(self: *Client) !void {
        defer log.info("Peer {} has disconnected.", .{self.conn.address});

        _ = try self.conn.socket.write("Hello from the server!\n");

        var buf: [1024]u8 = undefined;
        while (true) {
            const num_bytes = try self.conn.socket.read(&buf);
            if (num_bytes == 0) return;

            const message = mem.trim(u8, buf[0..num_bytes], " \t\r\n");
            log.info("Peer {} said: {}", .{ self.conn.address, message });
        }
    }
};

pub fn runServer(notifier: *const pike.Notifier, server: *pike.Socket) !void {
    defer log.debug("TCP server has shut down.", .{});

    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = &gpa.allocator;

    var clients = try std.ArrayListUnmanaged(Client).initCapacity(allocator, 128);
    defer clients.deinit(allocator);

    defer {
        for (clients.items) |*client| {
            _ = client.conn.socket.write("Server is closing! Good bye...\n") catch {};

            client.conn.socket.deinit();

            await client.frame catch |err| {
                log.err("Peer {} reported an error: {}", .{ client.conn.address, @errorName(err) });
            };
        }
    }

    while (true) {
        var conn = server.accept() catch |err| switch (err) {
            error.SocketNotListening => return,
            else => return err,
        };
        errdefer conn.socket.deinit();

        const client = try clients.addOne(allocator);
        errdefer clients.items.len -= 1;

        client.conn = conn;
        client.frame = async client.run();
        errdefer await client.frame catch |err| {
            log.err("Peer {} reported an error: {}", .{ client.conn.address, @errorName(err) });
        };

        try client.conn.socket.registerTo(notifier);

        log.info("New peer {} connected.", .{client.conn.address});
    }
}

pub fn run(notifier: *const pike.Notifier, stopped: *bool) !void {
    defer stopped.* = true;

    const address = try net.Address.parseIp("0.0.0.0", 9000);

    // Setup signal handler.

    var signal = try pike.Signal.init(.{ .interrupt = true });
    defer signal.deinit();

    try signal.registerTo(notifier);

    // Setup TCP server.

    var server = try pike.Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);

    {
        errdefer server.deinit();
        try server.registerTo(notifier);
        try server.set(.reuse_address, true);
        try server.bind(address);
        try server.listen(128);
    }

    var server_frame = async runServer(notifier, &server);
    log.info("Listening for peers on: {}", .{address});

    // Listen for interrupt signal.

    {
        errdefer server.deinit();
        try signal.wait();
    }

    // Shutdown.

    log.debug("Shutting down...", .{});

    {
        server.deinit();
        try await server_frame;
    }
}

pub fn main() !void {
    try pike.init();
    defer pike.deinit();

    const notifier = try pike.Notifier.init();
    defer notifier.deinit();

    var stopped = false;

    var frame = async run(&notifier, &stopped);

    while (!stopped) {
        try notifier.poll(1_000_000);
    }

    try nosuspend await frame;

    log.debug("Successfully shut down.", .{});
}
