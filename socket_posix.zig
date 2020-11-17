const std = @import("std");
const pike = @import("pike.zig");
const posix = @import("os/posix.zig");

const io = std.io;
const os = std.os;
const net = std.net;
const mem = std.mem;
const meta = std.meta;

usingnamespace @import("waker.zig");

fn UnionValueType(comptime Union: type, comptime Tag: anytype) type {
    return meta.fieldInfo(Union, @tagName(Tag)).field_type;
}

pub const SocketOptionType = enum(u32) {
    debug = os.SO_DEBUG,
    listen = os.SO_ACCEPTCONN,
    reuse_address = os.SO_REUSEADDR,
    keep_alive = os.SO_KEEPALIVE,
    dont_route = os.SO_DONTROUTE,
    broadcast = os.SO_BROADCAST,
    linger = os.SO_LINGER,
    oob_inline = os.SO_OOBINLINE,

    send_buffer_max_size = os.SO_SNDBUF,
    recv_buffer_max_size = os.SO_RCVBUF,

    send_buffer_min_size = os.SO_SNDLOWAT,
    recv_buffer_min_size = os.SO_RCVLOWAT,

    send_timeout = os.SO_SNDTIMEO,
    recv_timeout = os.SO_RCVTIMEO,

    socket_error = os.SO_ERROR,
    socket_type = os.SO_TYPE,
};

pub const SocketOption = union(SocketOptionType) {
    debug: bool,
    listen: bool,
    reuse_address: bool,
    keep_alive: bool,
    dont_route: bool,
    broadcast: bool,
    linger: posix.LINGER,
    oob_inline: bool,

    send_buffer_max_size: u32,
    recv_buffer_max_size: u32,

    send_buffer_min_size: u32,
    recv_buffer_min_size: u32,

    send_timeout: u32, // Timeout specified in milliseconds.
    recv_timeout: u32, // Timeout specified in milliseconds.

    socket_error: anyerror!void, // TODO
    socket_type: u32,
};

pub const Connection = struct {
    socket: Socket,
    address: net.Address,
};

pub const Socket = struct {
    pub const Reader = io.Reader(*Self, anyerror, read);
    pub const Writer = io.Writer(*Self, anyerror, write);

    const Self = @This();

    handle: pike.Handle,
    readers: Waker = .{},
    writers: Waker = .{},

    pub fn init(domain: u32, socket_type: u32, protocol: u32, flags: u32) !Self {
        return Self{
            .handle = .{
                .inner = try os.socket(
                    domain,
                    socket_type | flags | os.SOCK_CLOEXEC | os.SOCK_NONBLOCK,
                    protocol,
                ),
                .wake_fn = wake,
            },
        };
    }

    pub fn deinit(self: *Self) void {
        self.shutdown(posix.SHUT_RDWR) catch {};

        os.close(self.handle.inner);

        if (self.writers.shutdown()) |task| pike.dispatch(task, .{});
        while (true) self.writers.wait() catch break;

        if (self.readers.shutdown()) |task| pike.dispatch(task, .{});
        while (true) self.readers.wait() catch break;
    }

    pub fn registerTo(self: *const Self, notifier: *const pike.Notifier) !void {
        try notifier.register(&self.handle, .{ .read = true, .write = true });
    }

    inline fn wake(handle: *pike.Handle, opts: pike.WakeOptions) void {
        const self = @fieldParentPtr(Self, "handle", handle);

        if (opts.write_ready) if (self.writers.notify()) |task| pike.dispatch(task, .{});
        if (opts.read_ready) if (self.readers.notify()) |task| pike.dispatch(task, .{});
        if (opts.shutdown) {
            if (self.writers.shutdown()) |task| pike.dispatch(task, .{});
            if (self.readers.shutdown()) |task| pike.dispatch(task, .{});
        }
    }

    fn ErrorUnionOf(comptime func: anytype) std.builtin.TypeInfo.ErrorUnion {
        return @typeInfo(@typeInfo(@TypeOf(func)).Fn.return_type.?).ErrorUnion;
    }

    inline fn call(self: *Self, comptime function: anytype, args: anytype, comptime opts: pike.CallOptions) !ErrorUnionOf(function).payload {
        while (true) {
            const result = @call(.{ .modifier = .always_inline }, function, args) catch |err| switch (err) {
                error.WouldBlock => {
                    if (comptime opts.write) {
                        try self.writers.wait();
                    } else if (comptime opts.read) {
                        try self.readers.wait();
                    }
                    continue;
                },
                else => return err,
            };

            return result;
        }
    }

    pub fn shutdown(self: *const Self, how: c_int) !void {
        try posix.shutdown(self.handle.inner, how);
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

    pub fn accept(self: *Self) callconv(.Async) !Connection {
        var addr: os.sockaddr = undefined;
        var addr_len: os.socklen_t = @sizeOf(@TypeOf(addr));

        const handle = try self.call(posix.accept_, .{
            self.handle.inner,
            &addr,
            &addr_len,
            os.SOCK_NONBLOCK | os.SOCK_CLOEXEC,
        }, .{ .read = true });

        return Connection{
            .socket = Socket{ .handle = .{ .inner = handle, .wake_fn = wake } },
            .address = net.Address.initPosix(@alignCast(4, &addr)),
        };
    }

    pub fn connect(self: *Self, address: net.Address) callconv(.Async) !void {
        self.call(
            posix.connect_,
            .{ self.handle.inner, &address.any, address.getOsSockLen() },
            .{ .write = true },
        ) catch |err| switch (err) {
            error.AlreadyConnected => {},
            else => return err,
        };
    }

    pub inline fn reader(self: *Self) Reader {
        return Reader{ .context = self };
    }

    pub inline fn writer(self: *Self) Writer {
        return Writer{ .context = self };
    }

    pub fn read(self: *Self, buf: []u8) !usize {
        const num_bytes = self.call(posix.read_, .{ self.handle.inner, buf }, .{ .read = true }) catch |err| switch (err) {
            error.NotOpenForReading,
            error.ConnectionResetByPeer,
            error.OperationCancelled,
            => return 0,
            else => return err,
        };

        return num_bytes;
    }

    pub fn recv(self: *Self, buf: []u8, flags: u32) callconv(.Async) !usize {
        return self.recvFrom(buf, flags, null);
    }

    pub fn recvFrom(self: *Self, buf: []u8, flags: u32, address: ?*net.Address) callconv(.Async) !usize {
        var src_addr: os.sockaddr = undefined;
        var src_addr_len: os.socklen_t = undefined;

        const num_bytes = try self.call(os.recvfrom, .{
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

    pub fn write(self: *Self, buf: []const u8) !usize {
        return self.call(os.write, .{ self.handle.inner, buf }, .{ .write = true });
    }

    pub fn send(self: *Self, buf: []const u8, flags: u32) callconv(.Async) !usize {
        return self.sendTo(buf, flags, null);
    }

    pub fn sendTo(self: *Self, buf: []const u8, flags: u32, address: ?net.Address) callconv(.Async) !usize {
        return self.call(posix.sendto_, .{
            self.handle.inner,
            buf,
            flags,
            @as(?*const os.sockaddr, if (address) |a| &a.any else null),
            if (address) |a| a.getOsSockLen() else 0,
        }, .{ .write = true });
    }
};
