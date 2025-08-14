const std = @import("std");
const fs = std.fs;
const json = std.json;
const process = std.process;
const config = @import("config.zig");
const shared = @import("lift_shared");

const CompilationData = struct {
    sources: [][]u8 = &.{},
    compilationClasspath: [][]u8 = &.{},

    fn mergeWith(self: *CompilationData, allocator: std.mem.Allocator, other: *const CompilationData) !void {
        var sources = try std.ArrayList([]u8).initCapacity(
            allocator,
            self.sources.len + other.sources.len,
        );
        defer sources.deinit();
        var classpath = try std.ArrayList([]u8).initCapacity(
            allocator,
            self.compilationClasspath.len + other.compilationClasspath.len,
        );
        defer classpath.deinit();

        sources.appendSliceAssumeCapacity(self.sources);
        sources.appendSliceAssumeCapacity(other.sources);
        classpath.appendSliceAssumeCapacity(self.compilationClasspath);
        classpath.appendSliceAssumeCapacity(other.compilationClasspath);

        const finalSources = try sources.toOwnedSlice();
        const finalClasspath = try classpath.toOwnedSlice();

        self.sources = finalSources;
        self.compilationClasspath = finalClasspath;
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

    // TODO: Take output dir from data
    const outputDir = try allocator.dupe(u8, stepConfig.buildPath);

    fs.makeDirAbsolute(outputDir) catch |err| {
        switch (err) {
            std.fs.Dir.MakeError.PathAlreadyExists => {
                std.log.debug("Path already exists", .{});
            },
            else => return err,
        }
    };

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

    for (compilationData.compilationClasspath, 0..) |cp, ix| {
        if (ix != 0) try classpath.append(':');
        try classpath.appendSlice(cp);
    }

    const cp: []u8 = try classpath.toOwnedSlice();

    const javac = try allocator.dupe(u8, "javac");
    const _d = try allocator.dupe(u8, "-d");

    var argv = std.ArrayList([]u8).init(allocator);
    try argv.append(javac);
    try argv.append(_d);
    try argv.append(outputDir);

    if (stepConfig.data.sourceVersion > 0) {
        try argv.append(try allocator.dupe(u8, "--source"));
        try argv.append(try std.fmt.allocPrint(allocator, "{d}", .{stepConfig.data.sourceVersion}));
    }

    if (stepConfig.data.targetVersion > 0) {
        try argv.append(try allocator.dupe(u8, "--target"));
        try argv.append(try std.fmt.allocPrint(allocator, "{d}", .{stepConfig.data.targetVersion}));
    }

    if (cp.len > 0) {
        const _cp = try allocator.dupe(u8, "-cp");

        try argv.append(_cp);
        try argv.append(cp);
    }

    for (compilationData.sources) |src| {
        try argv.append(src);
    }

    const javac_argv = try argv.toOwnedSlice();

    std.log.debug("Invoking javac with args {s}", .{try std.mem.join(allocator, " ", javac_argv)});

    var proc = process.Child.init(javac_argv, allocator);

    const term = try proc.spawnAndWait();

    const exit_code = term.Exited;

    const outputFile = try std.fs.openFileAbsolute(stepConfig.outputPath, .{ .mode = .read_write });
    defer outputFile.close();

    var target = json.writeStream(outputFile.writer(), .{ .whitespace = .minified });
    try target.beginObject();
    try target.objectField("runtimeClasspath");
    try target.beginArray();
    try target.write(outputDir);
    try target.endArray();
    try target.endObject();

    process.exit(exit_code);
}
