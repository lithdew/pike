const std = @import("std");
const pike = @import("pike.zig");
const posix = @import("os/posix.zig");
const Waker = @import("waker.zig").Waker;
const os = std.os;
const io = std.io;
const system = os.system;
const log = std.log.scoped(.inotify);

const mem = std.mem;
const meta = std.meta;
const builtin = @import("builtin");

pub const InotifyMask = struct {
    access: bool = false,
    modify: bool = false,
    attrib: bool = false,
    close_write: bool = false,
    close_nowrite: bool = false,
    open: bool = false,
    moved_from: bool = false,
    moved_to: bool = false,
    create: bool = false,
    delete: bool = false,
    delete_self: bool = false,
    move_self: bool = false,

    fn toInt(self: InotifyMask) u32 {
        var mask: u32 = 0;
        if(self.access) mask |= @enumToInt(InotifyEventTypes.access);
        if(self.modify) mask |= @enumToInt(InotifyEventTypes.modify);
        if(self.attrib) mask |= @enumToInt(InotifyEventTypes.attrib);
        if(self.close_write) mask |= @enumToInt(InotifyEventTypes.close_write);
        if(self.close_nowrite) mask |= @enumToInt(InotifyEventTypes.close_nowrite);
        if(self.open) mask |= @enumToInt(InotifyEventTypes.open);
        if(self.moved_from) mask |= @enumToInt(InotifyEventTypes.moved_from);
        if(self.moved_to) mask |= @enumToInt(InotifyEventTypes.moved_to);
        if(self.create) mask |= @enumToInt(InotifyEventTypes.create);
        if(self.delete) mask |= @enumToInt(InotifyEventTypes.delete);
        if(self.delete_self) mask |= @enumToInt(InotifyEventTypes.delete_self);
        if(self.move_self) mask |= @enumToInt(InotifyEventTypes.move_self); 
        return mask;
    }
};

pub const InotifyEventTypes = enum(u32) {
    access = 1 << 0,
    modify = 1 << 1,
    attrib = 1 << 2,
    close_write = 1 << 3,
    close_nowrite = 1 << 4,
    open = 1 << 5,
    moved_from = 1 << 6,
    moved_to = 1 << 7,
    create = 1 << 8,
    delete = 1 << 9,
    delete_self = 1 << 10,
    move_self = 1 << 11,
    base_events = 0x00000fff,
    umount = 0x0002000,
    overflow = 0x0004000,
    ignored = 0x0008000,
    only_dir = 0x01000000,
    dont_follow = 0x02000000,
    add_mask = 0x20000000,
    directory = 0x40000000,
    one_shot = 0x80000000,
};

pub const InotifyEvent = extern struct {
    wd: os.fd_t,
    mask: u32,
    cookie: u32,
    len: u32,
};

pub const Inotify = struct {
    
    pub const Reader = io.Reader(*Self, anyerror, read);
    
    handle: pike.Handle,
    mask: InotifyMask = .{},
    readers: Waker = .{},

    const Self = @This();
    var lock: std.Thread.Mutex = .{};
    var waker: Waker(pike.Task, InotifyMask) = .{};
    
    pub fn init() !Self {
        return Self{
            .handle = .{
                .inner = try os.inotify_init1(os.linux.IN.NONBLOCK | os.linux.IN.CLOEXEC),
                .wake_fn = wake,
            },
        };
    }

    fn wake(handle: *pike.Handle, batch: *pike.Batch, opts: pike.WakeOptions) void {
        const self = @fieldParentPtr(Self, "handle", handle);

        if (opts.read_ready) {
            if (self.readers.notify()) |task| {
                batch.push(task);
            }
        }
        if (opts.shutdown) {
            if (self.readers.shutdown()) |task| batch.push(task);
        }
    }

    fn ErrorUnionOf(comptime func: anytype) std.builtin.TypeInfo.ErrorUnion {
        return @typeInfo(@typeInfo(@TypeOf(func)).Fn.return_type.?).ErrorUnion;
    }

    fn call(self: *Self, comptime function: anytype, args: anytype, comptime opts: pike.CallOptions) !ErrorUnionOf(function).payload {
        while (true) {
            const result = @call(.{ .modifier = .always_inline }, function, args) catch |err| switch (err) {
                error.WouldBlock => {
                    if (comptime opts.write) {
                        try self.writers.wait(.{ .use_lifo = true });
                    } else if (comptime opts.read) {
                        try self.readers.wait(.{});
                    }
                    continue;
                },
                else => return err,
            };

            return result;
        }
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

    pub inline fn reader(self: *Self) Reader {
        return Reader{ .context = self };
    }

    pub fn deinit(self: *Self, watchers: *std.ArrayList(i32)) void {
        if (self.readers.shutdown()) |task| pike.dispatch(task, .{});

        for (watchers.items) |watcher| os.inotify_rm_watch(self.handle.inner, watcher);
        os.close(self.handle.inner);
    }

    pub fn add(self: *const Self, path: []const u8, mask: InotifyMask) std.os.INotifyAddWatchError!i32 {
        var watcher = try os.inotify_add_watch(self.handle.inner, path, mask.toInt());
        return watcher;
    }

    pub fn remove(self: *const Self, watch: os.fd_t) void {
        os.inotify_rm_watch(self.handle.inner, watch);
    }

    pub fn registerTo(self: *const Self, notifier: *const pike.Notifier) !void {
        try notifier.register(&self.handle, .{ .read = true, .write = true });
    }
};