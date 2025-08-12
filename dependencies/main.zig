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

    var pool = try Pool.init(allocator, stepConfig.cachePath);
    defer pool.deinit();

    // TODO: Enqueue configured dependencies
    // TODO: Avoid processing the same dependency twice
    // TODO: Fetch POM for dependency
    // TODO: Enqueue dependencies declared in POM
    // TODO: Acquire a jar.DownloadManager for local use here as well

    for (stepConfig.data) |directive| {
        defer allocator.free(directive);
        const dep = try spec.Asset.parse(allocator, directive);
        const item = try allocator.create(worker.WorkItem);
        item.* = worker.WorkItem.Dep(dep);
        pool.enqueue(item) catch |err| {
            std.log.err("Unable to enqueue: {any}", .{err});
        };
    }
}
