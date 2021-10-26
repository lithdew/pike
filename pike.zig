const std = @import("std");
const root = @import("root");

const os = std.os;
const builtin = @import("builtin");

pub const PollOptions = packed struct {
    read: bool = false,
    write: bool = false,
};

pub const CallOptions = packed struct {
    read: bool = false,
    write: bool = false,
};

pub const WakeOptions = packed struct {
    notify: bool = false,
    shutdown: bool = false,
    read_ready: bool = false,
    write_ready: bool = false,
};

const has_epoll = @hasDecl(os.linux, "epoll_create1") and @hasDecl(os.linux, "epoll_ctl") and @hasDecl(os.linux, "epoll_event");
const has_kqueue = @hasDecl(os.system, "kqueue") and @hasDecl(os.system, "kevent") and @hasDecl(os, "Kevent");

// Export asynchronous frame dispatcher and user scope (Task).

pub const Task = if (@hasDecl(root, "pike_task"))
    root.pike_task
else
    struct {
        next: ?*Task = null,
        frame: anyframe,

        pub inline fn init(frame: anyframe) Task {
            return .{ .frame = frame };
        }
    };

pub const Batch = if (@hasDecl(root, "pike_batch"))
    root.pike_batch
else
    struct {
        head: ?*Task = null,
        tail: *Task = undefined,

        pub fn from(batchable: anytype) Batch {
            if (@TypeOf(batchable) == Batch)
                return batchable;

            if (@TypeOf(batchable) == *Task) {
                batchable.next = null;
                return Batch{
                    .head = batchable,
                    .tail = batchable,
                };
            }

            if (@TypeOf(batchable) == ?*Task) {
                const task: *Task = batchable orelse return Batch{};
                return Batch.from(task);
            }

            @compileError(@typeName(@TypeOf(batchable)) ++ " cannot be converted into a " ++ @typeName(Batch));
        }

        pub fn push(self: *Batch, entity: anytype) void {
            const other = Batch.from(entity);
            if (self.head == null) {
                self.* = other;
            } else {
                self.tail.next = other.head;
                self.tail = other.tail;
            }
        }

        pub fn pop(self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            return task;
        }
    };

pub const dispatch: fn (anytype, anytype) void = if (@hasDecl(root, "pike_dispatch"))
    root.pike_dispatch
else
    struct {
        fn default(batchable: anytype, args: anytype) void {
            var batch = Batch.from(batchable);
            _ = args;
            while (batch.pop()) |task| {
                resume task.frame;
            }
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

pub usingnamespace if (has_epoll or has_kqueue)
    @import("signal_posix.zig")
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

// Export 'Waker' and 'PackedWaker'.

pub usingnamespace @import("waker.zig");
