const std = @import("std");

const pkg = std.build.Pkg{
    .name = "pike",
    .path = "pike.zig",
};

pub fn build(b: *std.build.Builder) !void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const tests = .{
        "waker",
        "signal_windows",
    };

    const test_step = b.step("test", "Runs the tests");

    inline for (tests) |name| {
        const test_cmd = b.addTest("src/" ++ name ++ ".zig");
        test_step.dependOn(&test_cmd.step);
    }

    const examples = .{
        "example_tcp_client",
        "example_tcp_server",
        "example_tcp_benchmark",
        "example_signal",
    };

    const examples_step = b.step("examples", "Builds the examples");

    inline for (examples) |name| {
        const example = b.addExecutable(name, "examples/" ++ name ++ ".zig");
        example.setBuildMode(mode);
        example.setTarget(target);
        example.addPackage(pkg);
        example.install();

        examples_step.dependOn(b.getInstallStep());

        const run_cmd = example.run();
        run_cmd.step.dependOn(b.getInstallStep());

        const run_step = b.step(name, "Run " ++ name);
        run_step.dependOn(&run_cmd.step);
    }
}
