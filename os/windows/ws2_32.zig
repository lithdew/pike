const std = @import("std");

const windows = @import("../windows.zig");
const ws2_32 = windows.ws2_32;

pub usingnamespace ws2_32;

const IOC_VOID = 0x80000000;
const IOC_OUT = 0x40000000;
const IOC_IN = 0x80000000;
const IOC_WS2 = 0x08000000;

pub const SIO_BSP_HANDLE = IOC_OUT | IOC_WS2 | 27;
pub const SIO_BSP_HANDLE_SELECT = IOC_OUT | IOC_WS2 | 28;
pub const SIO_BSP_HANDLE_POLL = IOC_OUT | IOC_WS2 | 29;

pub const SIO_GET_EXTENSION_FUNCTION_POINTER = IOC_OUT | IOC_IN | IOC_WS2 | 6;

pub const SO_UPDATE_CONNECT_CONTEXT = 0x7010;
pub const SO_UPDATE_ACCEPT_CONTEXT = 0x700B;

pub const SD_RECEIVE = 0;
pub const SD_SEND = 1;
pub const SD_BOTH = 2;

pub const LINGER = extern struct {
    l_onoff: windows.USHORT, // Whether or not a socket should remain open to send queued dataa after closesocket() is called.
    l_linger: windows.USHORT, // Number of seconds on how long a socket should remain open after closesocket() is called.
};

pub const WSAID_CONNECTEX = windows.GUID{
    .Data1 = 0x25a207b9,
    .Data2 = 0xddf3,
    .Data3 = 0x4660,
    .Data4 = [8]u8{ 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e },
};

pub const WSAID_ACCEPTEX = windows.GUID{
    .Data1 = 0xb5367df1,
    .Data2 = 0xcbac,
    .Data3 = 0x11cf,
    .Data4 = [8]u8{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
};

pub const WSAID_GETACCEPTEXSOCKADDRS = windows.GUID{
    .Data1 = 0xb5367df2,
    .Data2 = 0xcbac,
    .Data3 = 0x11cf,
    .Data4 = [8]u8{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
};

pub const sockaddr_storage = extern struct {
    family: ws2_32.ADDRESS_FAMILY,
    __ss_padding: [128 - @sizeOf(windows.ULONGLONG) - @sizeOf(ws2_32.ADDRESS_FAMILY)]u8,
    __ss_align: windows.ULONGLONG,
};

pub extern "ws2_32" fn getsockopt(
    s: ws2_32.SOCKET,
    level: c_int,
    optname: c_int,
    optval: [*]u8,
    optlen: *c_int,
) callconv(.Stdcall) c_int;

pub extern "ws2_32" fn shutdown(
    s: ws2_32.SOCKET,
    how: c_int,
) callconv(.Stdcall) c_int;

pub extern "ws2_32" fn recv(
    s: ws2_32.SOCKET,
    buf: [*]u8,
    len: c_int,
    flags: c_int,
) callconv(.Stdcall) c_int;

pub const ConnectEx = fn (
    s: ws2_32.SOCKET,
    name: *const ws2_32.sockaddr,
    namelen: c_int,
    lpSendBuffer: ?*c_void,
    dwSendDataLength: windows.DWORD,
    lpdwBytesSent: ?*windows.DWORD,
    lpOverlapped: *windows.OVERLAPPED,
) callconv(.Stdcall) windows.BOOL;

pub const AcceptEx = fn (
    sListenSocket: ws2_32.SOCKET,
    sAcceptSocket: ws2_32.SOCKET,
    lpOutputBuffer: [*]u8,
    dwReceiveDataLength: windows.DWORD,
    dwLocalAddressLength: ws2_32.socklen_t,
    dwRemoteAddressLength: ws2_32.socklen_t,
    lpdwBytesReceived: ?*windows.DWORD,
    lpOverlapped: *windows.OVERLAPPED,
) callconv(.Stdcall) windows.BOOL;

pub const GetAcceptExSockaddrs = fn (
    lpOutputBuffer: [*]const u8,
    dwReceiveDataLength: windows.DWORD,
    dwLocalAddressLength: ws2_32.socklen_t,
    dwRemoteAddressLength: ws2_32.socklen_t,
    LocalSockaddr: **ws2_32.sockaddr,
    LocalSockaddrLength: *windows.INT,
    RemoteSockaddr: **ws2_32.sockaddr,
    RemoteSockaddrLength: *windows.INT,
) callconv(.Stdcall) void;
