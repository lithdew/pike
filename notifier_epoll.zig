const std = @import("std");
const pike = @import("pike.zig");
const posix = @import("os/posix.zig");

const os = std.os;
const net = std.net;
const mem = std.mem;

usingnamespace @import("waker.zig");

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

pub const Notifier = struct {
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

    pub fn register(self: *const Self, handle: *const Handle, comptime opts: pike.PollOptions) !void {
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

fn run(notifier: *const Notifier, stopped: *bool) !void {
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

fn runBenchmarkServer(notifier: *const Notifier, stopped: *bool) !void {
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

fn runBenchmarkClient(notifier: *const Notifier, stopped: *bool) !void {
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
    const notifier = try Notifier.init();
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
