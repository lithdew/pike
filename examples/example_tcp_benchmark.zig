const std = @import("std");
const pike = @import("pike");

fn clientLoop(driver: *pike.Driver) !void {
    var client = pike.TCP.init(driver);

    try client.connect(try std.net.Address.parseIp("127.0.0.1", 9000));
    defer client.close();

    var buf: [65536]u8 = undefined;

    while (true) {
        const n = try client.write(&buf);
    }
}

fn serverLoop(driver: *pike.Driver) !void {
    var server = pike.TCP.init(driver);

    try server.bind(try std.net.Address.parseIp("127.0.0.1", 9000));
    defer server.close();

    try server.listen(128);

    var client = try server.accept();
    try driver.register(&client.stream.file, .{ .read = true, .write = true });

    var buf: [65536]u8 = undefined;
    while (true) {
        const n = try client.stream.read(&buf);
        if (n == 0) return;
    }
}

pub fn main() !void {
    var driver = try pike.Driver.init(.{});
    defer driver.deinit();

    var server_frame = async serverLoop(&driver);
    var client_frame = async clientLoop(&driver);

    while (true) {
        try driver.poll(10000);
    }

    try nosuspend await server_frame;
    try nosuspend await client_frame;
}
