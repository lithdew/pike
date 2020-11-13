const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const mem = std.mem;
const net = std.net;
const log = std.log;
const heap = std.heap;

pub const ClientQueue = std.TailQueue(*Client);

pub const Client = struct {
    address: net.Address,
    socket: pike.Socket,
    dead: bool = false,

    fn read(self: *Client, buf: []u8) !usize {
        return self.socket.read(buf);
    }

    pub fn writeAll(self: *Client, buf: []const u8) !void {
        var index: usize = 0;
        while (index < buf.len) {
            index += try self.socket.write(buf);
        }
    }
};

pub const Server = struct {
    frame: @Frame(Server.run),
    allocator: *mem.Allocator,

    socket: pike.Socket,
    clients: ClientQueue,

    pub fn init(allocator: *mem.Allocator) !Server {
        var socket = try pike.Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
        errdefer socket.deinit();

        try socket.set(.reuse_address, true);

        return Server{
            .frame = undefined,
            .allocator = allocator,

            .socket = socket,
            .clients = .{},
        };
    }

    pub fn deinit(self: *Server) void {
        self.socket.deinit();

        while (self.clients.pop()) |node| {
            node.data.dead = true;

            node.data.writeAll("Server is shutting down! Good bye...\n") catch {};
            node.data.socket.deinit();
        }
    }

    pub fn start(self: *Server, notifier: *const pike.Notifier, address: net.Address) !void {
        try self.socket.bind(address);
        try self.socket.listen(128);
        try self.socket.registerTo(notifier);

        self.frame = async self.run(notifier);

        log.info("Listening for peers on: {}", .{address});
    }

    fn run(self: *Server, notifier: *const pike.Notifier) callconv(.Async) void {
        defer log.debug("TCP server has shut down.", .{});

        while (true) {
            var conn = self.socket.accept() catch |err| switch (err) {
                error.SocketNotListening => return,
                else => {
                    log.err("Server - socket.accept(): {}", .{@errorName(err)});
                    continue;
                },
            };

            const frame = self.allocator.create(@Frame(Server.runClient)) catch |err| {
                log.err("Server - allocator.create(Client): {}", .{@errorName(err)});
                conn.socket.deinit();
                continue;
            };

            frame.* = async self.runClient(notifier, conn);
        }
    }

    fn runClient(self: *Server, notifier: *const pike.Notifier, conn: pike.Connection) !void {
        defer {
            suspend self.allocator.destroy(@frame());
        }

        var client = Client{ .address = conn.address, .socket = conn.socket };
        defer if (!client.dead) client.socket.deinit();

        try client.socket.registerTo(notifier);

        var node = ClientQueue.Node{ .data = &client };
        self.clients.append(&node);
        defer if (!client.dead) self.clients.remove(&node);

        log.info("New peer {} has connected.", .{client.address});
        defer log.info("Peer {} has disconnected.", .{client.address});

        try client.writeAll("Hello from the server!\n");

        var buf: [1024]u8 = undefined;
        while (true) {
            const num_bytes = try client.read(&buf);
            if (num_bytes == 0) return;

            const message = mem.trim(u8, buf[0..num_bytes], " \t\r\n");
            log.info("Peer {} said: {}", .{ client.address, message });
        }
    }
};

pub fn run(notifier: *const pike.Notifier, stopped: *bool) !void {
    defer stopped.* = true;

    // Setup allocator.

    var gpa: heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    // Setup signal handler.

    var signal = try pike.Signal.init(.{ .interrupt = true });
    defer signal.deinit();

    try signal.registerTo(notifier);

    // Setup TCP server.

    var server = try Server.init(&gpa.allocator);
    defer server.deinit();

    // Start the server, and await for an interrupt signal to gracefully shutdown
    // the server.

    try server.start(notifier, try net.Address.parseIp("0.0.0.0", 9000));
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
