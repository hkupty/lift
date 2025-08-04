const std = @import("std");
const fs = std.fs;
const json = std.json;
const process = std.process;

const CompilationData = struct {
    sources: [][]u8 = &.{},
    classpath: [][]u8 = &.{},

    fn mergeWith(self: *CompilationData, allocator: std.mem.Allocator, other: *const CompilationData) !void {
        var sources = std.ArrayList([]u8).init(allocator);
        defer sources.deinit();
        var classpath = std.ArrayList([]u8).init(allocator);
        defer classpath.deinit();

        var sourcesToAdd = try sources.addManyAsSlice(self.sources.len + other.sources.len);

        for (self.sources, 0..) |source, ix| {
            sourcesToAdd[ix] = source;
        }

        for (other.sources, self.sources.len..) |source, ix| {
            sourcesToAdd[ix] = source;
        }

        var classpathsToAdd = try classpath.addManyAsSlice(self.classpath.len + other.classpath.len);

        for (self.classpath, 0..) |source, ix| {
            classpathsToAdd[ix] = source;
        }

        for (other.classpath, self.classpath.len..) |source, ix| {
            classpathsToAdd[ix] = source;
        }

        const finalSources = try sources.toOwnedSlice();
        const finalClasspath = try classpath.toOwnedSlice();

        self.sources = finalSources;
        self.classpath = finalClasspath;
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

    // TODO: Take output dir from data
    const outputDir = try allocator.dupe(u8, "/tmp/lift/build-dummy/compile/");

    fs.makeDirAbsolute(outputDir) catch |err| {
        switch (err) {
            std.fs.Dir.MakeError.PathAlreadyExists => {
                std.log.debug("Path already exists", .{});
            },
            else => return err,
        }
    };

    var compilationData: CompilationData = .{};

    // TODO: Parse first argument (data)
    _ = args.skip();

    // We expect at least a file, but it could be more.
    // Files could contain `sources`, `classpath` or both in their json document.
    // We need to aggregate them
    while (args.next()) |path| {
        const jsonFile = try fs.openFileAbsolute(path, .{});
        defer jsonFile.close();
        var reader = json.reader(allocator, jsonFile.reader());
        defer reader.deinit();
        const parsed = try json.parseFromTokenSource(CompilationData, allocator, &reader, .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed, .duplicate_field_behavior = .use_first });
        defer parsed.deinit();

        try compilationData.mergeWith(allocator, &parsed.value);
    }

    var classpath = std.ArrayList(u8).init(allocator);

    for (compilationData.classpath, 0..) |cp, ix| {
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

    if (cp.len > 0) {
        const _cp = try allocator.dupe(u8, "-cp");

        try argv.append(_cp);
        try argv.append(cp);
    }

    for (compilationData.sources) |src| {
        try argv.append(src);
    }

    const javac_argv = try argv.toOwnedSlice();

    var proc = process.Child.init(javac_argv, allocator);

    const term = try proc.spawnAndWait();

    const exit_code = term.Exited;

    process.exit(exit_code);
}

