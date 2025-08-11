const std = @import("std");
const process = std.process;
const shared = @import("lift_shared");
const config = @import("config.zig");
const worker = @import("worker.zig");
const Pool = worker.WorkerPool;
const spec = @import("spec.zig");

// TODO: Request pom files for each dependency;
// TODO: Enqueue new dependencies based on POM results recursively;
// TODO: Handle more sources than jar;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) unreachable;
    }
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = process.args();
    defer args.deinit();
    _ = args.skip();

    const stepConfigFile = args.next() orelse {
        std.log.err("Missing default data file", .{});
        process.exit(1);
    };

    const parsed = try shared.readConfig(config.BuildStepConfig, allocator, stepConfigFile);
    defer parsed.deinit();

    const stepConfig = parsed.value;

    var pool = try Pool.init(allocator);
    defer pool.deinit();

    // TODO: Enqueue configured dependencies
    // TODO: Avoid processing the same dependency twice
    // TODO: Fetch POM for dependency
    // TODO: Enqueue dependencies declared in POM

    for (stepConfig.data) |directive| {
        defer allocator.free(directive);
        const dependencyCoords = try spec.DependencyCoords.parse(directive);
        const item = try allocator.create(worker.WorkItem);
        const jar = dependencyCoords.jar(allocator) catch |err| {
            std.log.err("Failed to get jar for dependency {s}: {any}", .{ directive, err });
            continue;
        };
        item.* = worker.WorkItem.Dep(jar);
        pool.enqueue(item) catch |err| {
            std.log.err("Unable to enqueue: {any}", .{err});
        };
    }
}
