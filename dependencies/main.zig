const std = @import("std");
const process = std.process;
const shared = @import("lift_shared");
const config = @import("config.zig");
const worker = @import("worker.zig");
const Pool = worker.WorkerPool;
const spec = @import("spec.zig");
const http = @import("http.zig");
const json = std.json;
const pomParser = @import("pom.zig");
const LocaLRepo = @import("local_repo.zig").LocalRepo;

// TODO: Enqueue new dependencies based on POM results recursively;
// TODO: Handle more sources than jar;

// HACK: Conflict resolution is "first seen wins" - needs configuration
// TODO: Transitive dependency exclusions

const DependencyArrayMap = std.StringArrayHashMap(spec.Asset);

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

    var downloadManager = try http.init(allocator);
    defer downloadManager.deinit();

    var dependencies = DependencyArrayMap.init(allocator);
    defer dependencies.deinit();

    // NOTE: Dependency conflict resolution might cause changes the dependency list

    // TODO: Enqueue dependencies declared in POM
    for (stepConfig.data) |directive| {
        const dep = try spec.Asset.parse(allocator, directive);
        errdefer dep.deinit();
        allocator.free(directive);
        const identifier = try dep.identifier(allocator);
        defer allocator.free(identifier);

        const value = try dependencies.getOrPut(identifier);

        if (value.found_existing) {
            std.log.info("Duplicated dependency declaration: {s}. Skipping", .{identifier});
            continue;
        }

        value.value_ptr.* = dep;
    }

    var ix: usize = 0;
    while (true) {
        const values = dependencies.values();
        if (values.len <= ix) break;
        const dep = values[ix];

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

        const url = try std.mem.joinZ(allocator, "/", &parts);

        const reader = try downloadManager.download(url);
        defer reader.deinit();

        var xml = std.ArrayList(u8).init(allocator);
        defer xml.deinit();
        try xml.appendSlice(reader.asSlice());
        var buffered = std.io.fixedBufferStream(xml.items);
        const bufferedReader = buffered.reader();
        var xmlReader = try pomParser.parseDeps(allocator, bufferedReader);

        while (xmlReader.next(allocator)) |asset| {
            switch (asset.scope) {
                .import, .system, .test_scope => {
                    continue;
                },
                else => {},
            }

            const identifier = try asset.identifier(allocator);

            if (asset.optional) {
                std.log.debug("Asset {s} is optional. Skipping. Add dependency to the list explicitly if necessary.", .{identifier});
                continue;
            }

            const next = try dependencies.getOrPut(identifier);

            if (next.found_existing) {
                if (!std.mem.eql(u8, next.value_ptr.version, asset.version)) {
                    std.log.warn("Asset {s} already included at a different version {s} != {s}", .{
                        identifier,
                        next.value_ptr.version,
                        asset.version,
                    });
                }
                continue;
            } else {
                std.log.debug("Inserting {s} in the dependency list", .{identifier});
                next.value_ptr.* = asset;
            }
        }
        ix += 1;
    }

    for (dependencies.values()) |dep| {
        const exists = localrepo.exists(allocator, dep, .jar) catch |err| {
            std.log.err("Failed to verify if jar exists, skipping: {any}", .{err});
            failure = true;
            continue;
        };
        if (!exists) {
            const item = try allocator.create(worker.WorkItem);
            item.* = worker.WorkItem.Dep(dep);
            pool.enqueue(item) catch |err| {
                std.log.err("Unable to enqueue: {any}", .{err});
                failure = true;
            };
        }

        // var target = json.writeStream(std.io.getStdOut().writer(), .{ .whitespace = .minified });
        // try target.beginObject();
        // try target.objectField("dependencies");
        // try target.beginArray();
    }
}
