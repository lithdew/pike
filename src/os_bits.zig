const std = @import("std");

const builtin = std.builtin;

const os = std.os;
const windows = os.windows;
const ws2_32 = windows.ws2_32;

pub const IOCTL_AFD_POLL: windows.ULONG = 0x00012024;

const IOC_VOID = 0x80000000;
const IOC_OUT = 0x40000000;
const IOC_IN = 0x80000000;
const IOC_WS2 = 0x08000000;

pub const SIO_BSP_HANDLE = IOC_OUT | IOC_WS2 | 27;
pub const SIO_BSP_HANDLE_SELECT = IOC_OUT | IOC_WS2 | 28;
pub const SIO_BSP_HANDLE_POLL = IOC_OUT | IOC_WS2 | 29;

pub const FILE_SKIP_COMPLETION_PORT_ON_SUCCESS: windows.UCHAR = 0x1;
pub const FILE_SKIP_SET_EVENT_ON_HANDLE: windows.UCHAR = 0x2;

pub const AFD_POLL_RECEIVE: windows.ULONG = 1 << 0;
pub const AFD_POLL_RECEIVE_EXPEDITED: windows.ULONG = 1 << 1;
pub const AFD_POLL_SEND: windows.ULONG = 1 << 2;
pub const AFD_POLL_DISCONNECT: windows.ULONG = 1 << 3;
pub const AFD_POLL_ABORT: windows.ULONG = 1 << 4;
pub const AFD_POLL_LOCAL_CLOSE: windows.ULONG = 1 << 5;
pub const AFD_POLL_CONNECT: windows.ULONG = 1 << 6;
pub const AFD_POLL_ACCEPT: windows.ULONG = 1 << 7;
pub const AFD_POLL_CONNECT_FAIL: windows.ULONG = 1 << 8;

pub const SOL_SOCKET = if (builtin.os.tag == .windows) 0xffff else os.SOL_SOCKET;
pub const SO_REUSEADDR = if (builtin.os.tag == .windows) 0x0004 else os.SO_REUSEADDR;
pub const SO_ERROR = if (builtin.os.tag == .windows) 0x1007 else os.SO_ERROR;

pub const OVERLAPPED_ENTRY = extern struct {
    lpCompletionKey: windows.ULONG_PTR,
    lpOverlapped: windows.LPOVERLAPPED,
    Internal: windows.ULONG_PTR,
    dwNumberOfBytesTransferred: windows.DWORD,
};

pub const AFD_HANDLE = extern struct {
    Handle: windows.HANDLE,
    Events: windows.ULONG,
    Status: windows.NTSTATUS,
};

pub const AFD_POLL_INFO = extern struct {
    Timeout: windows.LARGE_INTEGER,
    HandleCount: windows.ULONG = 1,
    Exclusive: windows.ULONG,
    Handles: [1]AFD_HANDLE,
};
