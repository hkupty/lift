const std = @import("std");
const fs = std.fs;
const json = std.json;
const process = std.process;
const config = @import("config.zig");
const shared = @import("lift_shared");

const CompilationData = struct {
    sources: [][]u8 = &.{},
    compilationClasspath: [][]u8 = &.{},
    runtimeClasspath: [][]u8 = &.{},

    fn mergeWith(self: *CompilationData, allocator: std.mem.Allocator, other: *const CompilationData) !void {
        var sources = try std.ArrayList([]u8).initCapacity(
            allocator,
            self.sources.len + other.sources.len,
        );
        defer sources.deinit();
        var compilationCp = try std.ArrayList([]u8).initCapacity(
            allocator,
            self.compilationClasspath.len + other.compilationClasspath.len,
        );
        defer compilationCp.deinit();
        var runtimeCp = try std.ArrayList([]u8).initCapacity(
            allocator,
            self.runtimeClasspath.len + other.runtimeClasspath.len,
        );
        defer runtimeCp.deinit();

        sources.appendSliceAssumeCapacity(self.sources);
        sources.appendSliceAssumeCapacity(other.sources);
        compilationCp.appendSliceAssumeCapacity(self.compilationClasspath);
        compilationCp.appendSliceAssumeCapacity(other.compilationClasspath);
        runtimeCp.appendSliceAssumeCapacity(self.runtimeClasspath);
        runtimeCp.appendSliceAssumeCapacity(other.runtimeClasspath);

        const finalSources = try sources.toOwnedSlice();
        const finalClasspath = try compilationCp.toOwnedSlice();
        const finalRuntime = try runtimeCp.toOwnedSlice();

        self.sources = finalSources;
        self.compilationClasspath = finalClasspath;
        self.runtimeClasspath = finalRuntime;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

    const dataPath = args.next() orelse {
        std.log.err("Missing default data file", .{});
        std.process.exit(1);
    };
    const parsed = try shared.readConfig(config.BuildStepConfig, allocator, dataPath);
    defer parsed.deinit();

    const stepConfig = parsed.value;

    var compilationData: CompilationData = .{};

    // We expect at least a file, but it could be more.
    // Files could contain `sources`, `classpath` or both in their json document.
    // We need to aggregate them
    while (args.next()) |path| {
        const jsonFile = try fs.openFileAbsolute(path, .{});
        defer jsonFile.close();
        var reader = json.reader(allocator, jsonFile.reader());
        defer reader.deinit();
        const innerParsed = json.parseFromTokenSource(CompilationData, allocator, &reader, .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed, .duplicate_field_behavior = .use_first }) catch |err| {
            std.log.err("Skipping file {s} due to error {any}", .{ path, err });
            continue;
        };
        defer innerParsed.deinit();

        try compilationData.mergeWith(allocator, &innerParsed.value);
    }

    var classpath = std.ArrayList(u8).init(allocator);

    const compCp = try std.mem.join(allocator, ":", compilationData.compilationClasspath);
    const runCp = try std.mem.join(allocator, ":", compilationData.runtimeClasspath);
    try classpath.appendSlice(compCp);
    if (compCp.len > 0 and runCp.len > 0) {
        try classpath.appendSlice(":");
    }
    try classpath.appendSlice(runCp);

    const cp: []u8 = try classpath.toOwnedSlice();

    const java = try allocator.dupe(u8, "java");

    var argv = std.ArrayList([]u8).init(allocator);
    try argv.append(java);

    if (cp.len > 0) {
        const _cp = try allocator.dupe(u8, "-cp");

        try argv.append(_cp);
        try argv.append(cp);
    }

    try argv.append(stepConfig.data.mainClass);

    const java_argv = try argv.toOwnedSlice();

    std.log.debug("Invoking javac with args {s}", .{try std.mem.join(allocator, " ", java_argv)});

    var proc = process.Child.init(java_argv, allocator);

    const term = try proc.spawnAndWait();

    const exit_code = term.Exited;

    process.exit(exit_code);
}
