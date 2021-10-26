const std = @import("std");
const pike = @import("pike.zig");
const windows = @import("os/windows.zig");
const ws2_32 = @import("os/windows/ws2_32.zig");

const io = std.io;
const os = std.os;
const net = std.net;
const mem = std.mem;
const meta = std.meta;

var OVERLAPPED = windows.OVERLAPPED{ .Internal = 0, .InternalHigh = 0, .Offset = 0, .OffsetHigh = 0, .hEvent = null };
var OVERLAPPED_PARAM = &OVERLAPPED;

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

    protocol_info_a = ws2_32.SO_PROTOCOL_INFOA,
    protocol_info_w = ws2_32.SO_PROTOCOL_INFOW,

    update_connect_context = ws2_32.SO_UPDATE_CONNECT_CONTEXT,
    update_accept_context = ws2_32.SO_UPDATE_ACCEPT_CONTEXT,
};

pub const SocketOption = union(SocketOptionType) {
    debug: bool,
    listen: bool,
    reuse_address: bool,
    keep_alive: bool,
    dont_route: bool,
    broadcast: bool,
    linger: ws2_32.LINGER,
    oob_inline: bool,

    send_buffer_max_size: u32,
    recv_buffer_max_size: u32,

    send_buffer_min_size: u32,
    recv_buffer_min_size: u32,

    send_timeout: u32, // Timeout specified in milliseconds.
    recv_timeout: u32, // Timeout specified in milliseconds.

    socket_error: void,
    socket_type: u32,

    protocol_info_a: ws2_32.WSAPROTOCOL_INFOA,
    protocol_info_w: ws2_32.WSAPROTOCOL_INFOW,

    update_connect_context: ?ws2_32.SOCKET,
    update_accept_context: ?ws2_32.SOCKET,
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
        self.shutdown(ws2_32.SD_BOTH) catch {};
        windows.closesocket(@ptrCast(ws2_32.SOCKET, self.handle.inner)) catch {};
    }

    pub fn registerTo(self: *const Self, notifier: *const pike.Notifier) !void {
        try notifier.register(&self.handle, .{ .read = true, .write = true });
    }

    fn ErrorUnionOf(comptime func: anytype) std.builtin.TypeInfo.ErrorUnion {
        return @typeInfo(@typeInfo(@TypeOf(func)).Fn.return_type.?).ErrorUnion;
    }

    fn call(_: *Self, comptime function: anytype, raw_args: anytype, comptime _: pike.CallOptions) callconv(.Async) (ErrorUnionOf(function).error_set || error{OperationCancelled})!pike.Overlapped {
        var overlapped = pike.Overlapped.init(pike.Task.init(@frame()));
        var args = raw_args;

        comptime var i = 0;
        inline while (i < args.len) : (i += 1) {
            if (comptime @TypeOf(args[i]) == *windows.OVERLAPPED) {
                args[i] = &overlapped.inner;
            }
        }

        var err: ?ErrorUnionOf(function).error_set = null;

        suspend {
            var would_block = false;

            if (@call(.{ .modifier = .always_inline }, function, args)) |_| {} else |call_err| switch (call_err) {
                error.WouldBlock => would_block = true,
                else => err = call_err,
            }

            if (!would_block) pike.dispatch(&overlapped.task, .{ .use_lifo = true });
        }

        if (err) |call_err| return call_err;

        return overlapped;
    }

    pub fn shutdown(self: *const Self, how: c_int) !void {
        try windows.shutdown(@ptrCast(ws2_32.SOCKET, self.handle.inner), how);
    }

    pub fn get(self: *const Self, comptime opt: SocketOptionType) !meta.TagPayload(SocketOption, opt) {
        if (opt == .socket_error) {
            const errno = try windows.getsockopt(u32, @ptrCast(ws2_32.SOCKET, self.handle.inner), os.SOL.SOCKET, @enumToInt(opt));
            if (errno != 0) {
                return switch (@intToEnum(ws2_32.WinsockError, @truncate(u16, errno))) {
                    .WSAEACCES => error.PermissionDenied,
                    .WSAEADDRINUSE => error.AddressInUse,
                    .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
                    .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
                    .WSAEALREADY => error.AlreadyConnecting,
                    .WSAEBADF => error.BadFileDescriptor,
                    .WSAECONNREFUSED => error.ConnectionRefused,
                    .WSAEFAULT => error.InvalidParameter,
                    .WSAEISCONN => error.AlreadyConnected,
                    .WSAENETUNREACH => error.NetworkUnreachable,
                    .WSAENOTSOCK => error.NotASocket,
                    .WSAEPROTOTYPE => error.UnsupportedProtocol,
                    .WSAETIMEDOUT => error.ConnectionTimedOut,
                    .WSAESHUTDOWN => error.AlreadyShutdown,
                    else => |err| windows.unexpectedWSAError(err),
                };
            }
        } else {
            return windows.getsockopt(
                meta.TagPayload(SocketOption, opt),
                @ptrCast(ws2_32.SOCKET, self.handle.inner),
                os.SOL.SOCKET,
                @enumToInt(opt),
            );
        }
    }

    pub fn set(self: *const Self, comptime opt: SocketOptionType, val: meta.TagPayload(SocketOption, opt)) !void {
        try windows.setsockopt(
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            os.SOL.SOCKET,
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

    pub fn getBindAddress(self: *const Self) !net.Address {
        var addr: os.sockaddr = undefined;
        var addr_len: os.socklen_t = @sizeOf(@TypeOf(addr));
        try os.getsockname(@ptrCast(ws2_32.SOCKET, self.handle.inner), &addr, &addr_len);
        return net.Address.initPosix(@alignCast(4, &addr));
    }

    pub fn bind(self: *const Self, address: net.Address) !void {
        try windows.bind_(@ptrCast(ws2_32.SOCKET, self.handle.inner), &address.any, address.getOsSockLen());
    }

    pub fn listen(self: *const Self, backlog: usize) !void {
        try windows.listen_(@ptrCast(ws2_32.SOCKET, self.handle.inner), backlog);
    }

    pub fn accept(self: *Self) callconv(.Async) !Connection {
        const info = try self.get(.protocol_info_w);

        var incoming = try Self.init(
            info.iAddressFamily,
            info.iSocketType,
            info.iProtocol,
            0,
        );
        errdefer incoming.deinit();

        var buf: [2 * @sizeOf(ws2_32.sockaddr_storage) + 32]u8 = undefined;
        var num_bytes: windows.DWORD = undefined;

        _ = try self.call(windows.AcceptEx, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            @ptrCast(ws2_32.SOCKET, incoming.handle.inner),
            &buf,
            @sizeOf(ws2_32.sockaddr_storage),
            @sizeOf(ws2_32.sockaddr_storage),
            &num_bytes,
            OVERLAPPED_PARAM,
        }, .{});

        var local_addr: *ws2_32.sockaddr = undefined;
        var remote_addr: *ws2_32.sockaddr = undefined;

        windows.GetAcceptExSockaddrs(
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            &buf,
            @as(c_int, @sizeOf(ws2_32.sockaddr_storage)),
            @as(c_int, @sizeOf(ws2_32.sockaddr_storage)),
            &local_addr,
            &remote_addr,
        ) catch |err| switch (err) {
            error.FileDescriptorNotASocket => return error.SocketNotListening,
            else => return err,
        };

        try incoming.set(.update_accept_context, @ptrCast(ws2_32.SOCKET, self.handle.inner));

        return Connection{
            .socket = incoming,
            .address = net.Address.initPosix(@alignCast(4, remote_addr)),
        };
    }

    pub fn connect(self: *Self, address: net.Address) callconv(.Async) !void {
        try self.bind(net.Address.initIp4(.{ 0, 0, 0, 0 }, 0));

        _ = try self.call(windows.ConnectEx, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            &address.any,
            address.getOsSockLen(),
            OVERLAPPED_PARAM,
        }, .{});

        try self.get(.socket_error);
        try self.set(.update_connect_context, null);
    }

    pub inline fn reader(self: *Self) Reader {
        return Reader{ .context = self };
    }

    pub inline fn writer(self: *Self) Writer {
        return Writer{ .context = self };
    }

    pub fn read(self: *Self, buf: []u8) !usize {
        const overlapped = self.call(windows.ReadFile_, .{
            self.handle.inner, buf, OVERLAPPED_PARAM,
        }, .{}) catch |err| switch (err) {
            error.EndOfFile => return 0,
            else => return err,
        };

        return overlapped.inner.InternalHigh;
    }

    pub fn recv(self: *Self, buf: []u8, flags: u32) callconv(.Async) !usize {
        const overlapped = self.call(windows.WSARecv, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner), buf, flags, OVERLAPPED_PARAM,
        }, .{}) catch |err| switch (err) {
            error.ConnectionAborted,
            error.ConnectionResetByPeer,
            error.ConnectionClosedByPeer,
            error.NetworkSubsystemFailed,
            error.NetworkReset,
            => return 0,
            else => return err,
        };

        return overlapped.inner.InternalHigh;
    }

    pub fn recvFrom(self: *Self, buf: []u8, flags: u32, address: ?*net.Address) callconv(.Async) !usize {
        var src_addr: ws2_32.sockaddr = undefined;
        var src_addr_len: ws2_32.socklen_t = undefined;

        const overlapped = self.call(windows.WSARecvFrom, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            buf,
            flags,
            @as(?*ws2_32.sockaddr, if (address != null) &src_addr else null),
            @as(?*ws2_32.socklen_t, if (address != null) &src_addr_len else null),
            OVERLAPPED_PARAM,
        }, .{}) catch |err| switch (err) {
            error.ConnectionAborted,
            error.ConnectionResetByPeer,
            error.ConnectionClosedByPeer,
            error.NetworkSubsystemFailed,
            error.NetworkReset,
            => return 0,
            else => return err,
        };

        if (address) |a| {
            a.* = net.Address{ .any = src_addr };
        }

        return overlapped.inner.InternalHigh;
    }

    pub fn write(self: *Self, buf: []const u8) !usize {
        const overlapped = self.call(windows.WriteFile_, .{
            self.handle.inner, buf, OVERLAPPED_PARAM,
        }, .{}) catch |err| switch (err) {
            error.EndOfFile => return 0,
            else => return err,
        };

        return overlapped.inner.InternalHigh;
    }

    pub fn send(self: *Self, buf: []const u8, flags: u32) callconv(.Async) !usize {
        const overlapped = self.call(windows.WSASend, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner), buf, flags, OVERLAPPED_PARAM,
        }, .{}) catch |err| switch (err) {
            error.ConnectionAborted,
            error.ConnectionResetByPeer,
            error.NetworkSubsystemFailed,
            error.NetworkReset,
            => return 0,
            else => return err,
        };

        return overlapped.inner.InternalHigh;
    }

    pub fn sendTo(self: *Self, buf: []const u8, flags: u32, address: ?net.Address) callconv(.Async) !usize {
        const overlapped = self.call(windows.WSASendTo, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            buf,
            flags,
            @as(?*const ws2_32.sockaddr, if (address) |a| &a.any else null),
            if (address) |a| a.getOsSockLen() else 0,
            OVERLAPPED_PARAM,
        }, .{}) catch |err| switch (err) {
            error.ConnectionAborted,
            error.ConnectionResetByPeer,
            error.ConnectionClosedByPeer,
            error.NetworkSubsystemFailed,
            error.NetworkReset,
            => return 0,
            else => return err,
        };

        return overlapped.inner.InternalHigh;
    }
};
