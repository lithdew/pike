const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const mem = std.mem;
const log = std.log;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    try pike.init();
    defer pike.deinit();

    const notifier = try pike.Notifier.init();
    defer notifier.deinit();

    var watchers = std.ArrayList(i32).init(&gpa.allocator);
    defer watchers.deinit();

    var watch = try pike.Inotify.init();
    defer watch.deinit(&watchers);

    try watchers.append(try watch.add("src", .{ .create = true, .modify = true, .delete = true, .access = true }));
    try watchers.append(try watch.add("build.zig", .{ .create = true, .modify = true, .delete = true, .access = true }));

    try watch.registerTo(&notifier);
    var note = async inotify_handler(&watch);

    var stopped = false;

    var frame = async run(&notifier, &stopped);
    while(!stopped) {
        try notifier.poll(10_000);
    }

    log.info("Exited gracefully.", .{});

    try nosuspend await frame;
    try nosuspend await note;
}

fn run(notifier: *const pike.Notifier, stopped: *bool) !void {
    var event = try pike.Event.init();
    defer event.deinit();

    try event.registerTo(notifier);

    var signal = try pike.Signal.init(.{ .interrupt = true });
    defer signal.deinit();

    defer {
        stopped.* = true;
        event.post() catch unreachable;
    }

    log.info("Press Ctrl+C.", .{});

    try signal.wait();
}

pub fn inotify_handler(inotify: *pike.Inotify) !void {
    var reader = inotify.reader();

    const event_size = @sizeOf(pike.InotifyEvent);
    var buf: [event_size + std.fs.MAX_PATH_BYTES + 1]u8 = undefined;
    while(true) {
        const num_bytes = try reader.read(&buf);
        if (num_bytes == 0) return;
        const event = std.mem.bytesToValue(pike.InotifyEvent, buf[0..event_size]);
        const file = mem.trim(u8, buf[0..num_bytes], " \t\r\n");
        const evtype = pike.InotifyEventTypes;

        if(event.mask & @enumToInt(evtype.access) != 0) {
            log.info("File: {s} Action: {}", .{file, evtype.access});
        } else if(event.mask & @enumToInt(evtype.modify) != 0) {
            log.info("File: {s} Action: {}", .{file, evtype.modify});
        } else if(event.mask & @enumToInt(evtype.delete) != 0) {
            log.info("File: {s} Action: {}", .{file, evtype.delete});
        } else if(event.mask & @enumToInt(evtype.create) != 0) {
            log.info("File: {s} Action: {}", .{file, evtype.create});            
        } else {
            log.info("File: {s} Action: {}", .{file, event.mask});
        }
    }
}