const std = @import("std");
const process = std.process;
const shared = @import("lift_shared");
const config = @import("config.zig");
const worker = @import("worker.zig");
const Pool = worker.WorkerPool;
const spec = @import("spec.zig");
const DownloadManager = @import("http/curl.zig");
const json = std.json;
const PomHive = @import("pom/memory.zig").PomHive;
const LocaLRepo = @import("local_repo.zig").LocalRepo;

// HACK: Conflict resolution is "first seen wins" - needs configuration
// TODO: Transitive dependency exclusions

const DependencyArrayMap = std.StringArrayHashMap(spec.Asset);

const Output = struct {
    compilationClasspath: [][]u8,
    runtimeClasspath: [][]u8,
};

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

    var pomHive: PomHive = undefined;
    try pomHive.init(gpa.allocator());

    var dependencies = DependencyArrayMap.init(allocator);
    defer dependencies.deinit();

    // NOTE: Dependency conflict resolution might cause changes the dependency list

    for (stepConfig.data) |directive| {
        const dep = try spec.Asset.parse(allocator, directive);
        errdefer dep.deinit();
        const identifier = try dep.identifier(allocator);

        const value = try dependencies.getOrPut(identifier);

        if (value.found_existing) {
            // TODO: Resolve possible version conflict
            std.log.info("Duplicated dependency declaration: {s}. Skipping", .{identifier});
            continue;
        }
        std.log.debug("Inserting {s} in the dependency list", .{identifier});

        value.value_ptr.* = dep;
    }

    var ix: usize = 0;
    while (true) {
        const values = dependencies.values();
        if (values.len <= ix) break;
        const dep = values[ix];

        std.log.debug("Requesting {s}:{s}", .{ dep.group, dep.artifact });
        var iter = try pomHive.dependenciesForAsset(&dep);

        while (iter.next()) |asset| {
            switch (asset.scope) {
                .system, .test_scope => {
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
                std.log.debug("{s} is already in the dependency list", .{identifier});
                if (!std.mem.eql(u8, next.value_ptr.version, asset.version)) {
                    std.log.warn("Asset {s} already included at a different version {s} != {s}", .{
                        identifier,
                        next.value_ptr.version,
                        asset.version,
                    });
                }
                continue;
            } else {
                std.log.debug("[{s}:{s}:{s}] Inserting {s}", .{ dep.group, dep.artifact, dep.version, identifier });
                next.value_ptr.* = asset;
            }
        }
        ix += 1;
    }

    // HACK: Maybe we don't need to duplicate the dependency size in the array list, but at least this avoids resizing
    var compilation = try std.ArrayList([]u8).initCapacity(allocator, dependencies.count());
    var runtime = try std.ArrayList([]u8).initCapacity(allocator, dependencies.count());

    for (dependencies.values()) |dep| {
        const path = try localrepo.absolutePath(allocator, dep, .jar);
        switch (dep.scope) {
            .import, .system, .test_scope => unreachable,
            .runtime => runtime.appendAssumeCapacity(path),
            .compile, .provided => compilation.appendAssumeCapacity(path),
        }

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
    }

    const outputFile = try std.fs.openFileAbsolute(stepConfig.outputPath, .{ .mode = .read_write });
    defer outputFile.close();

    const out: Output = .{
        .compilationClasspath = try compilation.toOwnedSlice(),
        .runtimeClasspath = try runtime.toOwnedSlice(),
    };
    try json.stringify(
        out,
        .{ .whitespace = .minified },
        outputFile.writer(),
    );
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
