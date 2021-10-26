const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const mem = std.mem;
const net = std.net;
const log = std.log;
const heap = std.heap;
const atomic = std.atomic;

pub const ClientQueue = atomic.Queue(*Client);

pub const Client = struct {
    socket: pike.Socket,
    address: net.Address,
    frame: @Frame(Client.run),

    fn run(self: *Client, server: *Server, notifier: *const pike.Notifier) !void {
        var node = ClientQueue.Node{ .data = self };

        server.clients.put(&node);

        defer if (server.clients.remove(&node)) {
            suspend {
                self.socket.deinit();
                server.allocator.destroy(self);
            }
        };

        try self.socket.registerTo(notifier);

        log.info("New peer {} has connected.", .{self.address});
        defer log.info("Peer {} has disconnected.", .{self.address});

        var reader = self.socket.reader();
        var writer = self.socket.writer();

        try writer.writeAll("Hello from the server!\n");

        var buf: [1024]u8 = undefined;
        while (true) {
            const num_bytes = try reader.read(&buf);
            if (num_bytes == 0) return;

            const message = mem.trim(u8, buf[0..num_bytes], " \t\r\n");
            log.info("Peer {} said: {s}", .{ self.address, message });
        }
    }
};

pub const Server = struct {
    socket: pike.Socket,
    clients: ClientQueue,

    allocator: *mem.Allocator,
    frame: @Frame(Server.run),

    pub fn init(allocator: *mem.Allocator) !Server {
        var socket = try pike.Socket.init(os.AF.INET, os.SOCK.STREAM, os.IPPROTO.TCP, 0);
        errdefer socket.deinit();

        try socket.set(.reuse_address, true);

        return Server{
            .socket = socket,
            .clients = ClientQueue.init(),

            .frame = undefined,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Server) void {
        self.socket.deinit();

        await self.frame;

        while (self.clients.get()) |node| {
            node.data.socket.writer().writeAll("Server is shutting down! Good bye...\n") catch {};
            node.data.socket.deinit();

            await node.data.frame catch {};
            self.allocator.destroy(node.data);
        }
    }

    pub fn start(self: *Server, notifier: *const pike.Notifier, address: net.Address) !void {
        try self.socket.bind(address);
        try self.socket.listen(128);
        try self.socket.registerTo(notifier);

        self.frame = async self.run(notifier);

        log.info("Listening for peers on: {}", .{try self.socket.getBindAddress()});
    }

    fn run(self: *Server, notifier: *const pike.Notifier) callconv(.Async) void {
        defer log.debug("TCP server has shut down.", .{});

        while (true) {
            var conn = self.socket.accept() catch |err| switch (err) {
                error.SocketNotListening,
                error.OperationCancelled,
                => return,
                else => {
                    log.err("Server - socket.accept(): {s}", .{@errorName(err)});
                    continue;
                },
            };

            const client = self.allocator.create(Client) catch |err| {
                log.err("Server - allocator.create(Client): {s}", .{@errorName(err)});
                conn.socket.deinit();
                continue;
            };

            client.socket = conn.socket;
            client.address = conn.address;
            client.frame = async client.run(self, notifier);
        }
    }
};

pub fn run(notifier: *const pike.Notifier, stopped: *bool) !void {
    // Setup allocator.
    var gpa: heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    // Setup signal handler.

    var event = try pike.Event.init();
    defer event.deinit();

    try event.registerTo(notifier);

    var signal = try pike.Signal.init(.{ .interrupt = true });
    defer signal.deinit();

    defer {
        stopped.* = true;
        event.post() catch unreachable;
    }

    // Setup TCP server.

    var server = try Server.init(&gpa.allocator);
    defer server.deinit();

    // Start the server, and await for an interrupt signal to gracefully shutdown
    // the server.

    try server.start(notifier, net.Address.initIp4(.{ 0, 0, 0, 0 }, 0));
    try signal.wait();
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
