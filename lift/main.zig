const std = @import("std");
const fs = std.fs;
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

    const cwd = fs.cwd();

    const file = try cwd.openFile("build.toml", .{});
    const proj = try lib.project.parseFile(allocator, file);
    defer proj.deinit();

    var run = try proj.prepareRunForTarget("build");

    try run.run();
}
