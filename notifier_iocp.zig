const std = @import("std");
const pike = @import("pike.zig");
const windows = @import("os/windows.zig");
const ws2_32 = @import("os/windows/ws2_32.zig");

const os = std.os;
const net = std.net;
const math = std.math;

pub const Handle = struct {
    const Self = @This();

    inner: windows.HANDLE,

    pub fn init(handle: windows.HANDLE) Self {
        return Self{ .inner = handle };
    }

    pub fn deinit(self: *const Self) void {
        windows.closesocket(@ptrCast(ws2_32.SOCKET, self.inner)) catch {};
    }
};

const Overlapped = struct {
    const Self = @This();

    inner: windows.OVERLAPPED,
    frame: anyframe,

    pub fn init(frame: anyframe) Self {
        return .{
            .inner = .{
                .Internal = 0,
                .InternalHigh = 0,
                .Offset = 0,
                .OffsetHigh = 0,
                .hEvent = null,
            },
            .frame = frame,
        };
    }
};

pub const Notifier = struct {
    const Self = @This();

    handle: windows.HANDLE,

    pub fn init() !Self {
        const handle = try windows.CreateIoCompletionPort(
            windows.INVALID_HANDLE_VALUE,
            null,
            undefined,
            math.maxInt(windows.DWORD),
        );
        errdefer windows.CloseHandle(handle);

        return Self{ .handle = handle };
    }

    pub fn deinit(self: *const Self) void {
        windows.CloseHandle(self.handle);
    }

    pub fn register(self: *const Self, handle: *const Handle, comptime opts: pike.PollOptions) !void {
        const port = try windows.CreateIoCompletionPort(handle.inner, self.handle, 0, 0);

        try windows.SetFileCompletionNotificationModes(
            handle.inner,
            windows.FILE_SKIP_SET_EVENT_ON_HANDLE | windows.FILE_SKIP_COMPLETION_PORT_ON_SUCCESS,
        );
    }

    pub fn poll(self: *const Self, timeout: i32) !void {
        var events: [1024]windows.OVERLAPPED_ENTRY = undefined;

        const num_events = try windows.GetQueuedCompletionStatusEx(self.handle, &events, @intCast(windows.DWORD, timeout), false);

        for (events[0..num_events]) |event| {
            resume @fieldParentPtr(Overlapped, "inner", event.lpOverlapped).frame;
        }
    }

    pub fn call(handle: *Handle, comptime function: anytype, raw_args: anytype, comptime opts: pike.CallOptions) callconv(.Async) !Overlapped {
        var overlapped = Overlapped.init(@frame());
        var args = raw_args;

        comptime var i = 0;
        inline while (i < args.len) : (i += 1) {
            if (comptime @TypeOf(args[i]) == *windows.OVERLAPPED) {
                args[i] = &overlapped.inner;
            }
        }

        @call(.{ .modifier = .always_inline }, function, args) catch |err| switch (err) {
            error.WouldBlock => {
                suspend;
            },
            else => return err,
        };

        return overlapped;
    }
};

fn run(notifier: *const Notifier, stopped: *bool) !void {
    defer stopped.* = true;

    var socket = try Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
    defer socket.deinit();

    try notifier.register(&socket.handle, .{ .read = true, .write = true });

    try socket.connect(try net.Address.parseIp("127.0.0.1", 9000));

    var buf: [65536]u8 = undefined;
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

    var buf: [1024]u8 = undefined;
    while (true) {
        _ = try socket.recv(&buf, 0);
    }
}

pub fn main() !void {
    _ = try windows.WSAStartup(2, 2);
    defer windows.WSACleanup() catch {};

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
