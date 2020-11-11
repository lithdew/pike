const std = @import("std");
const pike = @import("pike.zig");
const windows = @import("os/windows.zig");
const ws2_32 = @import("os/windows/ws2_32.zig");

const os = std.os;
const net = std.net;
const math = std.math;

usingnamespace @import("socket.zig");

var OVERLAPPED = windows.OVERLAPPED{ .Internal = 0, .InternalHigh = 0, .Offset = 0, .OffsetHigh = 0, .hEvent = null };
var OVERLAPPED_PARAM = &OVERLAPPED;

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

pub const IOCP = struct {
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

pub const Socket = struct {
    const Self = @This();

    handle: Handle,

    pub fn init(domain: i32, socket_type: i32, protocol: i32, flags: windows.DWORD) !Self {
        return Self{
            .handle = .{
                .inner = try windows.WSASocketW(
                    domain,
                    socket_type,
                    protocol,
                    null,
                    0,
                    flags | ws2_32.WSA_FLAG_OVERLAPPED | ws2_32.WSA_FLAG_NO_HANDLE_INHERIT,
                ),
            },
        };
    }

    pub fn deinit(self: *const Self) void {
        self.handle.deinit();
    }

    pub fn get(self: *const Self, comptime opt: SocketOptionType) !UnionValueType(SocketOption, opt) {
        return windows.getsockopt(
            UnionValueType(SocketOption, opt),
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            os.SOL_SOCKET,
            @enumToInt(opt),
        );
    }

    pub fn set(self: *const Self, comptime opt: SocketOptionType, val: UnionValueType(SocketOption, opt)) !void {
        try windows.setsockopt(
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            os.SOL_SOCKET,
            @enumToInt(opt),
            blk: {
                if (comptime @typeInfo(@TypeOf(val)) == .Optional) {
                    break :blk if (val) |v| @as([]const u8, std.mem.asBytes(&v)[0..@sizeOf(@TypeOf(val))]) else null;
                } else {
                    break :blk @as([]const u8, std.mem.asBytes(&val)[0..@sizeOf(@TypeOf(val))]);
                }
            },
        );
    }

    pub fn bind(self: *const Self, address: net.Address) !void {
        try windows.bind_(@ptrCast(ws2_32.SOCKET, self.handle.inner), &address.any, address.getOsSockLen());
    }

    pub fn listen(self: *const Self, backlog: usize) !void {
        try windows.listen_(@ptrCast(ws2_32.SOCKET, self.handle.inner), backlog);
    }

    pub fn accept(self: *Self) callconv(.Async) !Socket {
        const info = try self.get(.protocol_info_w);

        var incoming = try Self.init(
            info.iAddressFamily,
            info.iSocketType,
            info.iProtocol,
            0,
        );
        errdefer incoming.deinit();

        const overlapped = try IOCP.call(&self.handle, windows.AcceptEx, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            @ptrCast(ws2_32.SOCKET, incoming.handle.inner),
            OVERLAPPED_PARAM,
        }, .{});

        try incoming.set(.update_accept_context, @ptrCast(ws2_32.SOCKET, self.handle.inner));

        return incoming;
    }

    pub fn connect(self: *Self, address: net.Address) callconv(.Async) !void {
        try self.bind(net.Address.initIp4(.{ 0, 0, 0, 0 }, 0));

        const overlapped = try IOCP.call(&self.handle, windows.ConnectEx, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            &address.any,
            address.getOsSockLen(),
            OVERLAPPED_PARAM,
        }, .{});

        try windows.getsockoptError(@ptrCast(ws2_32.SOCKET, self.handle.inner));

        try self.set(.update_connect_context, null);
    }

    pub fn read(self: *Self, buf: []u8) callconv(.Async) !usize {
        const overlapped = try IOCP.call(&self.handle, windows.ReadFile_, .{
            self.handle.inner, buf, OVERLAPPED_PARAM,
        }, .{});

        return overlapped.inner.InternalHigh;
    }

    pub fn recv(self: *Self, buf: []u8, flags: u32) callconv(.Async) !usize {
        const overlapped = try IOCP.call(&self.handle, windows.WSARecv, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner), buf, flags, OVERLAPPED_PARAM
        }, .{});

        return overlapped.inner.InternalHigh;
    }

    pub fn recvFrom(self: *Self, buf: []u8, flags: u32, address: ?*net.Address) callconv(.Async) !usize {
        var src_addr: ws2_32.sockaddr = undefined;
        var src_addr_len: ws2_32.socklen_t = undefined;

        const overlapped = try IOCP.call(&self.handle, windows.WSARecvFrom, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            buf,
            flags,
            @as(?*ws2_32.sockaddr, if (address != null) &src_addr else null),
            @as(?*ws2_32.socklen_t, if (address != null) &src_addr_len else null),
            OVERLAPPED_PARAM,
        }, .{});

        if (address) |a| {
            a.* = net.Address{ .any = src_addr };
        }

        return overlapped.inner.InternalHigh;
    }

    pub fn write(self: *Self, buf: []const u8) callconv(.Async) !usize {
        const overlapped = try IOCP.call(&self.handle, windows.WriteFile_, .{
            self.handle.inner, buf, OVERLAPPED_PARAM,
        }, .{});

        return overlapped.inner.InternalHigh;
    }

    pub fn send(self: *Self, buf: []const u8, flags: u32) callconv(.Async) !usize {
        const overlapped = try IOCP.call(&self.handle, windows.WSASend, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner), buf, flags, OVERLAPPED_PARAM
        }, .{});

        return overlapped.inner.InternalHigh;
    }

    pub fn sendTo(self: *Self, buf: []const u8, flags: u32, address: ?net.Address) callconv(.Async) !usize {
        const overlapped = try IOCP.call(&self.handle, windows.WSASendTo, .{
             @ptrCast(ws2_32.SOCKET, self.handle.inner),
            buf,
            flags,
            @as(?*const ws2_32.sockaddr, if (address) |a| &a.any else null),
            if (address) |a| a.getOsSockLen() else 0,
            OVERLAPPED_PARAM,
        }, .{});

        return overlapped.inner.InternalHigh;
    }
};

fn run(notifier: *const IOCP, stopped: *bool) !void {
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

fn runBenchmarkServer(notifier: *const IOCP, stopped: *bool) !void {
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

fn runBenchmarkClient(notifier: *const IOCP, stopped: *bool) !void {
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

    const notifier = try IOCP.init();
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
