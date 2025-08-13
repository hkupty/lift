const std = @import("std");
const process = std.process;
const shared = @import("lift_shared");
const config = @import("config.zig");
const worker = @import("worker.zig");
const Pool = worker.WorkerPool;
const spec = @import("spec.zig");
const http = @import("http.zig");
const pomParser = @import("pom.zig");

const LocaLRepo = @import("local_repo.zig").LocalRepo;

// TODO: Enqueue new dependencies based on POM results recursively;
// TODO: Handle more sources than jar;

// HACK: Conflict resolution is "first seen wins" - needs configuration
// TODO: Transitive dependency exclusions

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

    var failure = false;

    var pool = try Pool.init(allocator, localrepo);
    defer {
        const workerFailure = pool.deinit();
        if (failure or workerFailure) {
            std.process.exit(2);
        }
    }

    var depsset = std.BufSet.init(allocator);
    defer depsset.deinit();

    var downloadManager = try http.init(allocator);
    defer downloadManager.deinit();

    // TODO: Enqueue dependencies declared in POM

    for (stepConfig.data) |directive| {
        const dep = try spec.Asset.parse(allocator, directive);
        errdefer dep.deinit();
        allocator.free(directive);

        const identifier = dep.identifier(allocator) catch |err| {
            std.log.err("Failed to format dependency identifier: {any}", .{err});
            continue;
        };

        defer allocator.free(identifier);
        if (!depsset.contains(identifier)) {
            const baseUrl = dep.uri(allocator, spec.defaultMaven) catch |err| {
                std.log.err("Failed to resolve url: {any}", .{err});
                failure = true;
                continue;
            };

            defer allocator.free(baseUrl);
            const pom = dep.remoteFilename(allocator, .pom) catch |err| {
                std.log.err("Failed to resolve remote filename: {any}", .{err});
                failure = true;
                continue;
            };

            const parts = [_][]const u8{ baseUrl, pom };

            const url = std.mem.joinZ(allocator, "/", &parts) catch |err| {
                std.log.err("Failed to resolve full url: {any}", .{err});
                failure = true;
                continue;
            };

            const reader = downloadManager.download(url) catch |err| {
                std.log.err("Unable to download pom: {any}", .{err});
                failure = true;
                continue;
            };
            defer reader.deinit();

            var xml = std.ArrayList(u8).init(allocator);
            defer xml.deinit();
            xml.appendSlice(reader.asSlice()) catch |err| {
                std.log.err("Unable to acquire pom: {any}", .{err});
                failure = true;
                continue;
            };

            var buffered = std.io.fixedBufferStream(xml.items);
            const bufferedReader = buffered.reader();
            var xmlReader = try pomParser.parseDeps(allocator, bufferedReader);

            while (xmlReader.next(allocator)) |asset| {
                std.log.debug("Has dependency: {s}:{s}:{s}", .{ asset.group, asset.artifact, asset.version });
                asset.deinit();
            }

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
                    failure = true;
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
