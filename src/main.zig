const std = @import("std");
const lib = @import("lift_lib");

// TODO: perhaps daemonize in a liftd binary + lift to communicate w/ daemon?
// TODO: (daemon) create a collection/mapping of projects based on names - perhaps from lift.toml + path-based
// TODO: (daemon) Invalidate and re-process project based on file changes
// TODO: (frontend) handle `[project:]target` argument structure
// TODO: (frontend) handle `[./path/to/project:]target` argument structure
// TODO: (frontend) handle multiple arguments
// TODO: (frontend) handle verbosity

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) unreachable;
    }
    const allocator = gpa.allocator();
    const toml =
        \\defaults = ["./base.toml", "./extra.toml"]
        \\[dependencies]
        \\runner = "cat"
        \\data = [
        \\  "org.slf4j:slf4j-api:jar:2.0.17"
        \\]
        \\
        \\[sources]
        \\runner = "cat"
        \\data = [
        \\  "./src/main/java/"
        \\]
        \\
        \\[compile]
        \\runner = "cat"
        \\dependsOn = ["dependencies", "sources"]
        \\
        \\[compile.data]
        \\targetVersion = "21"
        \\sourceVersion = "21"
        \\
        \\[build]
        \\runner = "echo"
        \\dependsOn = ["dependencies", "sources", "compile"]
    ;

    const proj = try lib.project.parseString(allocator, toml);
    defer proj.deinit();

    var run = try proj.prepareRunForTarget("build");

    try run.run();
}
