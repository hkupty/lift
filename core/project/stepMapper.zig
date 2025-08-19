const std = @import("std");
const Step = @import("step.zig");
const models = @import("models.zig");
const json = @import("json.zig");

const utils = @import("../utils.zig");
const XDG = @import("../os/xdg.zig");

const Cache = std.StringHashMap(Paths);

pub const Paths = struct {
    run: []const u8,
    data: []const u8,
    output: []const u8,
    cache: []const u8,
};

cache: Cache,
projectName: []const u8,
xdg: XDG,
allocator: std.mem.Allocator,

/// Creates the Execution cache.
const StepMapper = @This();

pub fn init(allocator: std.mem.Allocator, projectName: []const u8, projectPath: []const u8) StepMapper {
    var fingerprint: [13]u8 = undefined;
    utils.fingerprint(projectPath, &fingerprint);

    const xdg = XDG.init(allocator, projectName, &fingerprint);

    return .{
        .cache = Cache.init(allocator),
        .projectName = projectName,
        .xdg = xdg,
        .allocator = allocator,
    };
}

pub fn deinit(self: *StepMapper) void {
    self.xdg.deinit();
    var iter = self.cache.valueIterator();
    while (iter.next()) |item| {
        self.allocator.free(item.data);
        self.allocator.free(item.run);
        self.allocator.free(item.output);
    }
    self.cache.deinit();
}

fn basepath(self: *StepMapper, stepName: []const u8) ![]const u8 {
    const path = try self.xdg.runFor(stepName);

    std.fs.makeDirAbsolute(path) catch |err| {
        switch (err) {
            std.fs.Dir.MakeError.PathAlreadyExists => {},
            else => return err,
        }
    };

    return path;
}

pub fn paths(self: *StepMapper, target: *Step) !*Paths {
    const entry = try self.cache.getOrPut(target.name);
    if (!entry.found_existing) {
        entry.value_ptr.cache = self.xdg.cache;
        entry.value_ptr.run = try self.basepath(target.name);
        entry.value_ptr.output = try std.fs.path.join(self.xdg.allocator, &[_][]const u8{
            entry.value_ptr.run,
            "output.json",
        });
        entry.value_ptr.data = try std.fs.path.join(self.xdg.allocator, &[_][]const u8{
            entry.value_ptr.run,
            "data.json",
        });
    }

    return entry.value_ptr;
}

pub fn build(self: *StepMapper, target: *Step) !models.BuildStepConfig {
    const path = try self.paths(target);
    return .{
        .buildPath = path.run,
        .cachePath = path.cache,
        .outputPath = path.output,
        .projectName = self.projectName,
        .stepName = target.name,
        .data = target.data,
    };
}

pub fn datapath(self: *StepMapper, target: *Step) ![]const u8 {
    const path = (try self.paths(target)).data;
    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    const config = try self.build(target);
    try json.writeBuildStepConfig(file, config);
    const out = try self.outpath(target.name);
    const fout = try std.fs.createFileAbsolute(out, .{});
    defer fout.close();

    return path;
}

pub fn outpath(self: *StepMapper, target: []const u8) ![]const u8 {
    // HACK: Implicit assumption here that `target` was already executed.
    // We shoudln't trust ourselves.
    return self.cache.get(target).?.output;
}
