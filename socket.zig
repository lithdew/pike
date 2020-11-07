const std = @import("std");
const builtin = @import("builtin");
const ws2_32 = @import("os/windows/ws2_32.zig");

const os = std.os;
const mem = std.mem;
const meta = std.meta;

pub usingnamespace @import("utils.zig");

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

    socket_error: anyerror!void, // TODO
    socket_type: u32,

    protocol_info_a: ws2_32.WSAPROTOCOL_INFOA,
    protocol_info_w: ws2_32.WSAPROTOCOL_INFOW,

    update_connect_context: ?ws2_32.SOCKET,
    update_accept_context: ?ws2_32.SOCKET,
};
