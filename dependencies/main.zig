const std = @import("std");
const process = std.process;
const shared = @import("lift_shared");
const config = @import("config.zig");
const worker = @import("worker.zig");
const Pool = worker.WorkerPool;
const spec = @import("spec.zig");

const LocaLRepo = @import("local_repo.zig").LocalRepo;

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
    var localrepo = try LocaLRepo.init(stepConfig.cachePath);
    defer localrepo.deinit();

    var pool = try Pool.init(allocator, localrepo);
    defer pool.deinit();

    var depsset = std.BufSet.init(allocator);
    defer depsset.deinit();

    // TODO: Avoid processing the same dependency twice
    // TODO: Fetch POM for dependency
    // TODO: Enqueue dependencies declared in POM
    // TODO: Acquire a jar.DownloadManager for local use here as well
    // TODO: Have a global flag for failures

    for (stepConfig.data) |directive| {
        defer allocator.free(directive);
        const dep = try spec.Asset.parse(allocator, directive);
        errdefer dep.deinit();
        const identifier = dep.identifier(allocator) catch |err| {
            std.log.err("Failed to format dependency identifier: {any}", .{err});
            continue;
        };
        defer allocator.free(identifier);
        if (!depsset.contains(identifier)) {
            const exists = localrepo.exists(allocator, dep, .jar) catch |err| {
                std.log.err("Failed to verify if jar exists, skipping: {any}", .{err});
                continue;
            };
            if (!exists) {
                depsset.insert(identifier) catch |err| {
                    std.log.warn(
                        "Unable to insert dependency identifier into cache, might collide: {any}",
                        .{err},
                    );
                };
                const item = try allocator.create(worker.WorkItem);
                item.* = worker.WorkItem.Dep(dep);
                pool.enqueue(item) catch |err| {
                    std.log.err("Unable to enqueue: {any}", .{err});
                };
            } else {
                std.log.debug("Dependency {s} already present", .{identifier});
                depsset.insert(identifier) catch |err| {
                    std.log.warn(
                        "Unable to insert dependency identifier into cache, might collide: {any}",
                        .{err},
                    );
                };
            }
        } else {
            std.log.debug("Dependency {s} already processed", .{identifier});
        }
    }
}
