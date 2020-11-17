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
    shutdown: bool = false,
    read_ready: bool = false,
    write_ready: bool = false,
};

const has_epoll = @hasDecl(os.system, "epoll_create1") and @hasDecl(os.system, "epoll_ctl") and @hasDecl(os, "epoll_event");
const has_kqueue = @hasDecl(os.system, "kqueue") and @hasDecl(os.system, "kevent") and @hasDecl(os, "Kevent");

// Export asynchronous frame dispatcher and user scope (Task).

pub const Task = if (@hasDecl(root, "pike_task"))
    root.pike_task
else
    struct {
        frame: anyframe,

        pub inline fn init(frame: anyframe) Task {
            return .{ .frame = frame };
        }
    };

pub const dispatch: fn (*Task, anytype) void = if (@hasDecl(root, "pike_dispatch"))
    root.pike_dispatch
else
    struct {
        inline fn default(task: *Task, args: anytype) void {
            resume task.frame;
        }
    }.default;

// Export 'Notifier' and 'Handle'.

pub usingnamespace if (@hasDecl(root, "notifier"))
    root.notifier
else if (has_epoll)
    @import("notifier_epoll.zig")
else if (has_kqueue)
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

// Export 'SignalType', and 'Signal'.

pub usingnamespace if (builtin.os.tag == .linux)
    @import("signal_linux.zig")
else if (has_kqueue)
    @import("signal_darwin.zig")
else if (builtin.os.tag == .windows)
    @import("signal_windows.zig")
else
    @compileError("pike: unable to figure out a 'Signal' implementation to use for the build target");

// Export 'Event'.

pub usingnamespace if (has_epoll)
    @import("event_epoll.zig")
else if (has_kqueue)
    @import("event_kqueue.zig")
else if (builtin.os.tag == .windows)
    @import("event_iocp.zig")
else
    @compileError("pike: unable to figure out a 'Event' implementation to use for the build target");
