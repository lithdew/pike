const std = @import("std");
const root = @import("root");

const os = std.os;
const builtin = std.builtin;

pub const PollOptions = packed struct {
    read: bool = false,
    write: bool = false,
};

pub const CallOptions = packed struct {
    read: bool = false,
    write: bool = false,
};

pub const WakeOptions = packed struct {
    read_ready: bool = false,
    write_ready: bool = false,
};

// Export 'Notifier' and 'Handle'.

pub usingnamespace if (@hasDecl(root, "notifier"))
    root.notifier
else if (@hasDecl(os.system, "epoll_create1") and @hasDecl(os.system, "epoll_ctl") and @hasDecl(os, "epoll_event"))
    @import("notifier_epoll.zig")
else if (@hasDecl(os.system, "kqueue") and @hasDecl(os.system, "kevent") and @hasDecl(os, "Kevent"))
    @import("notifier_kqueue.zig")
else if (builtin.os.tag == .windows)
    @import("notifier_iocp.zig")
else
    @compileError("pike: unable to figure out a 'Notifier'/'Handle' implementation to use for the build target");

// Export 'SocketOptionType', 'SocketOption', and 'Socket'.

pub usingnamespace if (builtin.os.tag == .windows)
    @import("socket_windows.zig")
else
    @import("socket_posix.zig");
