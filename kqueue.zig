const std = @import("std");
const pike = @import("pike.zig");
const posix = @import("os/posix.zig");

const os = std.os;
const net = std.net;
const mem = std.mem;
const time = std.time;

usingnamespace @import("waker.zig");
usingnamespace @import("socket.zig");

const Handle = struct {
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

const Kqueue = struct {
    const Self = @This();

    handle: os.fd_t,

    pub fn init() !Self {
        const handle = try os.kqueue();
        errdefer os.close(handle);

        return Self{ .handle = handle };
    }

    pub fn deinit(self: *const Self) void {
        os.close(self.handle);
    }

    pub fn register(self: *const Self, handle: *const Handle, comptime opts: pike.PollOptions) !void {
        var changelist = [_]os.Kevent{
            .{
                .ident = undefined,
                .filter = undefined,
                .flags = os.EV_ADD | os.EV_CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = undefined,
            },
        } ** 2;

        comptime var changelist_len = 0;

        comptime {
            if (opts.read) {
                changelist[changelist_len].filter = os.EVFILT_READ;
                changelist_len += 1;
            }

            if (opts.write) {
                changelist[changelist_len].filter = os.EVFILT_WRITE;
                changelist_len += 1;
            }
        }

        for (changelist[0..changelist_len]) |*event| {
            event.ident = @intCast(usize, handle.inner);
            event.udata = @ptrToInt(handle);
        }

        const num_events = try os.kevent(self.handle, changelist[0..changelist_len], &[0]os.Kevent{}, null);
    }

    pub fn poll(self: *const Self, timeout: i32) !void {
        var events: [1024]os.Kevent = undefined;

        const timeout_spec = os.timespec{
            .tv_sec = @divTrunc(timeout, time.ms_per_s),
            .tv_nsec = @rem(timeout, time.ms_per_s) * time.ns_per_ms,
        };

        const num_events = try os.kevent(self.handle, &[0]os.Kevent{}, events[0..], &timeout_spec);

        for (events[0..num_events]) |e| {
            const err = e.flags & os.EV_ERROR != 0;
            const eof = e.flags & os.EV_EOF != 0;

            const readable = (err or eof) or e.filter == os.EVFILT_READ;
            const writable = (err or eof) or e.filter == os.EVFILT_WRITE;

            const read_ready = (err or eof) or readable;
            const write_ready = (err or eof) or writable;

            const handle = @intToPtr(*Handle, e.udata);

            if (read_ready) if (handle.readers.wake(&handle.lock)) |frame| resume frame;
            if (write_ready) if (handle.writers.wake(&handle.lock)) |frame| resume frame;
        }
    }

    pub fn call(handle: *Handle, comptime function: anytype, args: anytype, comptime opts: pike.CallOptions) callconv(.Async) @typeInfo(@TypeOf(function)).Fn.return_type.? {
        defer if (comptime opts.read) if (handle.readers.next(&handle.lock)) |frame| resume frame;
        defer if (comptime opts.write) if (handle.writers.next(&handle.lock)) |frame| resume frame;

        while (true) {
            const result = @call(.{ .modifier = .always_inline }, function, args) catch |err| switch (err) {
                error.WouldBlock => {
                    if (comptime opts.read) handle.readers.wait(&handle.lock);
                    if (comptime opts.write) handle.writers.wait(&handle.lock);
                    continue;
                },
                else => return err,
            };

            return result;
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
        const val = switch (@TypeOf(value)) {
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
        var addr: os.sockaddr = undefined;
        var addr_len: os.socklen_t = @sizeOf(@TypeOf(addr));

        const handle = try Kqueue.call(&self.handle, os.accept, .{ self.handle.inner, &addr, &addr_len, os.SOCK_NONBLOCK | os.SOCK_CLOEXEC }, .{ .read = true });

        return Socket{ .handle = .{ .inner = handle } };
    }

    pub fn connect(self: *Self, address: net.Address) callconv(.Async) !void {
        return Kqueue.call(&self.handle, os.connect, .{ self.handle.inner, &address.any, address.getOsSockLen() }, .{ .write = true });
    }

    pub fn read(self: *Self, buf: []u8) callconv(.Async) !usize {
        return Kqueue.call(&self.handle, os.read, .{ self.handle.inner, buf }, .{ .read = true });
    }

    pub fn recv(self: *Self, buf: []u8, flags: u32) callconv(.Async) !usize {
        return self.recvFrom(buf, flags, null);
    }

    pub fn recvFrom(self: *Self, buf: []u8, flags: u32, address: ?*net.Address) callconv(.Async) !usize {
        var src_addr: os.sockaddr = undefined;
        var src_addr_len: os.socklen_t = undefined;

        const num_bytes = Kqueue.call(&self.handle, os.recvfrom, .{
            self.handle.inner,
            buf,
            flags,
            @as(?*os.sockaddr, if (address != null) &src_addr else null),
            @as(?*os.socklen_t, if (address != null) &src_addr_len else null),
        }, .{ .read = true });

        if (address) |a| {
            a.* = net.Address{ .any = src_addr };
        }

        return num_bytes;
    }

    pub fn write(self: *Self, buf: []const u8) callconv(.Async) !usize {
        return Kqueue.call(&self.handle, os.write, .{ self.handle.inner, buf }, .{ .write = true });
    }

    pub fn send(self: *Self, buf: []const u8, flags: u32) callconv(.Async) !usize {
        return self.sendTo(buf, flags, null);
    }

    pub fn sendTo(self: *Self, buf: []const u8, flags: u32, address: ?net.Address) callconv(.Async) !usize {
        return Kqueue.call(&self.handle, os.sendto, .{
            self.handle.inner,
            buf,
            flags,
            @as(?*const os.sockaddr, if (address) |a| &a.any else null),
            if (address) |a| a.getOsSockLen() else 0,
        }, .{ .write = true });
    }
};

fn run(notifier: *const Kqueue, stopped: *bool) !void {
    defer stopped.* = true;

    var socket = try Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
    defer socket.deinit();

    try notifier.register(&socket.handle, .{ .read = true, .write = true });
    try socket.connect(try net.Address.parseIp("127.0.0.1", 9000));

    var buf: [1024]u8 = undefined;
    std.debug.print("Got: {}", .{buf[0..try socket.read(&buf)]});
    std.debug.print("Got: {}", .{buf[0..try socket.recv(&buf, 0)]});

    _ = try socket.write("Hello world!\n");
    _ = try socket.send("Hello world!\n", 0);
}

fn runBenchmarkServer(notifier: *const Kqueue, stopped: *bool) !void {
    defer stopped.* = true;

    var socket = try Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
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

fn runBenchmarkClient(notifier: *const Kqueue, stopped: *bool) !void {
    defer stopped.* = true;

    var socket = try Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
    defer socket.deinit();

    try notifier.register(&socket.handle, .{ .read = true, .write = true });

    try socket.connect(try net.Address.parseIp("127.0.0.1", 9000));

    var buf: [65536]u8 = undefined;
    while (true) {
        _ = try socket.recv(&buf, 0);
    }
}

pub fn main() !void {
    const notifier = try Kqueue.init();
    defer notifier.deinit();

    var stopped = false;

    // var frame = async run(&notifier, &stopped);
    var server_frame = async runBenchmarkServer(&notifier, &stopped);
    var client_frame = async runBenchmarkClient(&notifier, &stopped);

    while (!stopped) {
        try notifier.poll(10000);
    }

    // try nosuspend await frame;
    try nosuspend await server_frame;
    try nosuspend await client_frame;
}
