const std = @import("std");
const posix = @import("os/posix.zig");

const os = std.os;
const net = std.net;
const mem = std.mem;

usingnamespace @import("waker.zig");
usingnamespace @import("socket.zig");

pub const RegisterOptions = packed struct {
    read: bool = false,
    write: bool = false,
};

pub const Handle = struct {
    const Self = @This();

    inner: os.fd_t,

    lock: std.Mutex = .{},
    readers: Waker = .{},
    writers: Waker = .{},

    pub fn init(inner: os.fd_t) Self {
        return Self{ .inner = inner };
    }

    pub fn deinit(self: *const Self) void {
        os.close(self.inner);
    }
};

pub const Epoll = struct {
    const Self = @This();

    handle: i32,

    pub fn init() !Self {
        const handle = try os.epoll_create1(os.EPOLL_CLOEXEC);
        errdefer os.close(handle);

        return Self{ .handle = handle };
    }

    pub fn deinit(self: *const Self) void {
        os.close(self.handle);
    }

    pub fn register(self: *const Self, handle: *const Handle, comptime opts: RegisterOptions) !void {
        var events = os.EPOLLET;
        if (opts.read) events |= os.EPOLLIN;
        if (opts.write) events |= os.EPOLLOUT;

        try os.epoll_ctl(self.handle, os.EPOLL_CTL_ADD, handle.inner, &os.epoll_event{
            .events = events,
            .data = .{ .ptr = @ptrToInt(handle) },
        });
    }

    pub fn poll(self: *const Self, timeout: i32) !void {
        var events: [128]os.epoll_event = undefined;

        const num_events = os.epoll_wait(self.handle, &events, timeout);
        for (events[0..num_events]) |e| {
            const handle = @intToPtr(*Handle, e.data.ptr);

            const read_ready = (e.events & os.EPOLLERR != 0 or e.events & os.EPOLLHUP != 0) or e.events & os.EPOLLIN != 0;
            const write_ready = (e.events & os.EPOLLERR != 0 or e.events & os.EPOLLHUP != 0) or e.events & os.EPOLLOUT != 0;

            if (read_ready) if (handle.readers.wake(&handle.lock)) |frame| resume frame;
            if (write_ready) if (handle.writers.wake(&handle.lock)) |frame| resume frame;
        }
    }
};

pub const Socket = struct {
    const Self = @This();

    handle: Handle,

    pub fn init(domain: u32, socket_type: u32, protocol: u32, flags: u32) !Self {
        return Self{
            .handle = Handle.init(
                try os.socket(
                    domain,
                    socket_type | flags | os.SOCK_CLOEXEC | os.SOCK_NONBLOCK,
                    protocol,
                ),
            ),
        };
    }

    pub fn deinit(self: *const Self) void {
        self.handle.deinit();
    }

     pub fn get(self: *const Self, comptime opt: SocketOptionType) !UnionValueType(SocketOption, opt) {
        return posix.getsockopt(
            UnionValueType(SocketOption, opt),
            self.handle.inner,
            os.SOL_SOCKET,
            @enumToInt(opt),
        );
    }

    pub fn set(self: *const Self, comptime opt: SocketOptionType, value: UnionValueType(SocketOption, opt)) !void {
        const val = switch(@TypeOf(value)) {
            bool => @intCast(c_int, @boolToInt(value)),
            else => value,
        };
        
        try os.setsockopt(
            self.handle.inner,
            os.SOL_SOCKET,
            @enumToInt(opt),
            blk: {
                if (comptime @typeInfo(@TypeOf(val)) == .Optional) {
                    break :blk if (val) |v| @as([]const u8, std.mem.asBytes(&v)[0..@sizeOf(@TypeOf(val))]) else &[0]u8{};
                } else {
                    break :blk @as([]const u8, std.mem.asBytes(&val)[0..@sizeOf(@TypeOf(val))]);
                }
            },
        );
    }

    pub fn bind(self: *Self, address: net.Address) !void {
        try os.bind(self.handle.inner, &address.any, address.getOsSockLen());
    }

    pub fn listen(self: *Self, backlog: usize) !void {
        try os.listen(self.handle.inner, @truncate(u31, backlog));
    }

    pub fn accept(self: *Self) callconv(.Async) !Socket {
        defer if (self.handle.readers.next(&self.handle.lock)) |frame| resume frame;

        var addr: os.sockaddr = undefined;
        var addr_len: os.socklen_t = @sizeOf(@TypeOf(addr));

        while (true) {
            const handle = os.accept(self.handle.inner, &addr, &addr_len, os.SOCK_NONBLOCK | os.SOCK_CLOEXEC) catch |err| switch (err) {
                error.WouldBlock => {
                    self.handle.readers.wait(&self.handle.lock);
                    continue;
                },
                else => return err,
            };

            return Socket{ .handle = .{ .inner = handle } };
        }
    }

    pub fn connect(self: *Self, address: net.Address) callconv(.Async) !void {
        defer if (self.handle.writers.next(&self.handle.lock)) |frame| resume frame;

        os.connect(self.handle.inner, &address.any, address.getOsSockLen()) catch |err| switch (err) {
            error.WouldBlock => self.handle.writers.wait(&self.handle.lock),
            else => return err,
        };

        try os.getsockoptError(self.handle.inner);
    }

    pub fn read(self: *Self, buf: []u8) callconv(.Async) !usize {
        defer if (self.handle.readers.next(&self.handle.lock)) |frame| resume frame;

        while (true) {
            const num_bytes = os.read(self.handle.inner, buf) catch |err| switch (err) {
                error.WouldBlock => {
                    self.handle.readers.wait(&self.handle.lock);
                    continue;
                },
                else => return err,
            };

            return num_bytes;
        }
    }

    pub fn recv(self: *Self, buf: []u8, flags: u32) callconv(.Async) !usize {
        return self.recvFrom(buf, flags, null);
    }

    pub fn recvFrom(self: *Self, buf: []u8, flags: u32, address: ?*net.Address) callconv(.Async) !usize {
        defer if (self.handle.readers.next(&self.handle.lock)) |frame| resume frame;

        while (true) {
            var src_addr: os.sockaddr = undefined;
            var src_addr_len: os.socklen_t = undefined;

            const num_bytes = os.recvfrom(
                self.handle.inner,
                buf,
                flags,
                if (address != null) &src_addr else null,
                if (address != null) &src_addr_len else null,
            ) catch |err| switch (err) {
                error.WouldBlock => {
                    self.handle.readers.wait(&self.handle.lock);
                    continue;
                },
                else => return err,
            };

            if (address) |a| {
                a.* = net.Address{ .any = src_addr };
            }

            return num_bytes;
        }
    }

    pub fn write(self: *Self, buf: []const u8) callconv(.Async) !usize {
        defer if (self.handle.writers.next(&self.handle.lock)) |frame| resume frame;

        while (true) {
            const num_bytes = os.write(self.handle.inner, buf) catch |err| switch (err) {
                error.WouldBlock => {
                    self.handle.writers.wait(&self.handle.lock);
                    continue;
                },
                else => return err,
            };

            return num_bytes;
        }
    }

    pub fn send(self: *Self, buf: []const u8, flags: u32) callconv(.Async) !usize {
        return self.sendTo(buf, flags, null);
    }

    pub fn sendTo(self: *Self, buf: []const u8, flags: u32, address: ?net.Address) callconv(.Async) !usize {
        defer if (self.handle.writers.next(&self.handle.lock)) |frame| resume frame;

        while (true) {
            const num_bytes = os.sendto(
                self.handle.inner,
                buf,
                flags,
                if (address) |a| &a.any else null,
                if (address) |a| a.getOsSockLen() else 0,
            ) catch |err| switch (err) {
                error.WouldBlock => {
                    self.handle.writers.wait(&self.handle.lock);
                    continue;
                },
                else => return err,
            };

            return num_bytes;
        }
    }
};

fn run(poller: *const Epoll, stopped: *bool) !void {
    defer stopped.* = true;

    var socket = try Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
    defer socket.deinit();

    try poller.register(&socket.handle, .{ .read = true, .write = true });
    try socket.connect(try net.Address.parseIp("127.0.0.1", 9000));

    var buf: [1024]u8 = undefined;
    std.debug.print("Got: {}", .{buf[0..try socket.read(&buf)]});
    std.debug.print("Got: {}", .{buf[0..try socket.recv(&buf, 0)]});

    _ = try socket.write("Hello world!\n");
    _ = try socket.send("Hello world!\n", 0);
}

fn runBenchmarkServer(poller: *const Epoll, stopped: *bool) !void {
    defer stopped.* = true;

    var socket = try Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
    defer socket.deinit();

    try poller.register(&socket.handle, .{ .read = true, .write = true });

    try socket.set(.reuse_address, true);
    try socket.bind(try net.Address.parseIp("127.0.0.1", 9000));
    try socket.listen(128);

    var client = try socket.accept();
    defer client.deinit();

    try poller.register(&client.handle, .{ .read = true, .write = true });

    var buf: [65536]u8 = undefined;
    while (true) {
        _ = try client.send(&buf, 0);
    }
}

fn runBenchmarkClient(poller: *const Epoll, stopped: *bool) !void {
    defer stopped.* = true;

    var socket = try Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
    defer socket.deinit();

    try poller.register(&socket.handle, .{ .read = true, .write = true });

    try socket.connect(try net.Address.parseIp("127.0.0.1", 9000));

    var buf: [65536]u8 = undefined;
    while (true) {
        _ = try socket.recv(&buf, 0);
    }
}

pub fn main() !void {
    const poller = try Epoll.init();
    defer poller.deinit();

    var stopped = false;

    // var frame = async run(&poller, &stopped);
    var server_frame = async runBenchmarkServer(&poller, &stopped);
    var client_frame = async runBenchmarkClient(&poller, &stopped);

    while (!stopped) {
        try poller.poll(10000);
    }

    // try nosuspend await frame;
    try nosuspend await server_frame;
    try nosuspend await client_frame;
}
