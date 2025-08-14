const std = @import("std");
const testing = std.testing;
const tomlz = @import("tomlz");
const json = @import("json.zig");
const XDG = @import("xdg.zig");
const shared = @import("lift_shared");
const BuildStepConfig = shared.BuildStepConfig([]u8);
const utils = @import("utils.zig");

const hash = std.crypto.hash;
const b3 = hash.Blake3;

// TODO: Implement `listener` steps, which declare inverse dependency (they're executed when their dependency executes);
// TODO: Define step input/output contract;
// TODO: Implement step execution;
// TODO: Implement parallel step execution;
// TODO: Tweak StepsList/ExecutionPlan to prioritize no-dependency steps first (i.e. A <- B <- C; D <- E <- C should yield [A, D, B, E, C] instead of [A, B, D, E, C].
// TODO: Implement (separate file) merkle-tree cache based on project steps-graph (i.e. for cacheable tasks);
// TODO: Memoize/pre-process execution plan for quicker resolution
// TODO: Break into smaller functions and modules

pub const StepErrors = error{
    /// This error is fired when a step is re-defined.
    StepRedefinition,

    /// This error is fired when a step parameter can't be parsed
    StepParameterIssue,

    /// This error is fired when a target/step is requested but it doesn't exist
    StepNotFound,

    /// Step run unsuccessfully.
    StepExecutionFailed,
};

pub const StepName = []u8;

/// StepBand is represents a bit field where the number of bits is the maximum number of steps
/// Any run could take.
/// NOTE: could be replaced by a comptime construct from u+size where size represents the maximum number
pub const StepBitPosition = u64;

pub const Step = struct {
    name: StepName,
    bitPosition: StepBitPosition,
    dependsOn: []StepName,
    runner: []const u8,
    data: []u8,

    fn getStepConfig(self: *Step, project: *Project) !BuildStepConfig {
        const stepPath = try project.pathForStep(self.name);
        const outPath = try project.pathForStepFile(self.name, "output.json");
        const file = try std.fs.createFileAbsolute(outPath, .{});
        file.close();
        return .{
            .buildPath = stepPath,
            .cachePath = project.xdg.cache,
            .outputPath = outPath,
            .projectName = project.name,
            .stepName = self.name,
            .data = self.data,
        };
    }

    pub fn run(self: *Step, project: *Project) !void {
        // TODO: Locate runner
        // it can be either a path-based binary(+ lift installation folder) or a remote target that might need downloading (future);

        if (self.runner.len == 0) {
            return;
        }

        var arguments = std.ArrayList([]const u8).init(project.arena.allocator());
        defer arguments.deinit();

        try arguments.append(self.runner);
        if (self.data.len > 0) {
            const dataPath = try project.pathForStepFile(self.name, "data.json");
            const dataFile = try std.fs.createFileAbsolute(dataPath, .{ .truncate = true });
            const content = try self.getStepConfig(project);

            try json.writeBuildStepConfig(dataFile, content);
            try arguments.append(dataPath);
        }

        for (self.dependsOn) |dependency| {
            const dependencyPath = try project.pathForStepFile(dependency, "output.json");
            var fileExists = true;
            std.fs.accessAbsolute(dependencyPath, .{}) catch |err| {
                switch (err) {
                    std.fs.Dir.AccessError.FileBusy => {},
                    std.fs.Dir.AccessError.FileNotFound => {
                        fileExists = false;
                    },
                    else => return err,
                }
            };
            if (fileExists) {
                try arguments.append(dependencyPath);
            }
        }

        const args = try arguments.toOwnedSlice();

        std.log.info("-- Running {s}", .{self.name});
        var process = std.process.Child.init(args, project.arena.allocator());

        try process.spawn();

        const term = try process.wait();

        if (term.Exited != 0) {
            return StepErrors.StepExecutionFailed;
        }

        // TODO: Aggregate arguments to runner (self.data + dependencies outputs);
    }
};

// TODO: Move common types out so json formatting can be aware of those polymorphic types
pub const StepArgument = union(enum) {
    string: []u8,
    number: i64,
    boolean: bool,
};

pub const ExecutionPlan = struct {
    execution: u64,
    project: *Project,
    steps: []*Step,

    pub fn run(self: *ExecutionPlan) !void {
        for (self.steps) |step| {
            self.execution |= step.bitPosition;
            try step.run(self.project);
        }
    }
};

/// StepsList is an auxiliary data type which enables building a queue for the execution plan by
/// performing a graph traversal through all the steps based on their declared dependencies
const StepsList = struct {
    queue: std.ArrayList(*Step),
    filter: u64,
    // TODO: Keep track of circular dependencies

    pub fn init(allocator: std.mem.Allocator) StepsList {
        return .{ .filter = 0, .queue = std.ArrayList(*Step).init(allocator) };
    }

    pub fn deinit(self: *StepsList) void {
        self.queue.deinit();
    }

    pub fn dfsAppend(self: *StepsList, proj: *Project, ref: *Step) !void {
        for (ref.dependsOn) |dep| {
            const next = proj.steps.getPtr(dep) orelse continue;
            if ((self.filter & next.bitPosition) != 0) continue;
            try self.dfsAppend(proj, next);
        }
        self.filter |= ref.bitPosition;
        try self.queue.append(ref);
    }
};

pub const Project = struct {
    // TODO: Add project name
    name: []u8,
    xdg: XDG,
    steps: std.StringHashMap(Step),
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Project) void {
        self.xdg.deinit();
        self.steps.deinit();
        self.arena.deinit();
    }

    fn pathForStep(self: *Project, stepName: StepName) ![]u8 {
        _ = self.steps.get(stepName) orelse return StepErrors.StepNotFound;
        const path = try std.fs.path.join(self.arena.allocator(), &[_][]const u8{ self.xdg.run, stepName });
        std.fs.makeDirAbsolute(path) catch |err| {
            switch (err) {
                std.fs.Dir.MakeError.PathAlreadyExists => {},
                else => return err,
            }
        };

        return path;
    }

    fn pathForStepFile(self: *Project, stepName: StepName, file: []const u8) ![]u8 {
        _ = self.steps.get(stepName) orelse return StepErrors.StepNotFound;
        const path = try self.pathForStep(stepName);
        return try std.fs.path.join(self.arena.allocator(), &[_][]const u8{ path, file });
    }

    pub fn prepareRunForTarget(self: *Project, target: []const u8) !ExecutionPlan {
        const initialStep = self.steps.getPtr(target) orelse return StepErrors.StepNotFound;
        const allocator = self.arena.allocator();
        var steps = StepsList.init(allocator);
        defer steps.deinit();

        try steps.dfsAppend(self, initialStep);

        const stepsSlice = try steps.queue.toOwnedSlice();

        return .{
            .execution = 0,
            .project = self,
            .steps = stepsSlice,
        };
    }

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !*Project {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const arenaAllocator = arena.allocator();
        const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(cwd);
        var fingerprint: [13]u8 = undefined;
        utils.fingerprint(cwd, &fingerprint);

        var xdg = XDG.init(allocator, name, &fingerprint);
        errdefer xdg.deinit();
        const ownedName = try arenaAllocator.dupe(u8, name);

        const proj = try arenaAllocator.create(Project);
        proj.* = .{
            .arena = arena,
            .name = ownedName,
            .xdg = xdg,
            .steps = std.StringHashMap(Step).init(allocator),
        };

        return proj;
    }
};

// pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !Project {
//     const table = try toml.parse(allocator);
// }

pub fn parseFile(allocator: std.mem.Allocator, file: std.fs.File) !*Project {
    const content = try file.readToEndAlloc(allocator, std.math.maxInt(u32));
    defer allocator.free(content);

    return parseString(allocator, content);
}

pub fn parseString(allocator: std.mem.Allocator, data: []const u8) !*Project {
    var table = try tomlz.parse(allocator, data);
    defer table.deinit(allocator);

    // TODO: Merge defaults into a single Project definition instead of carrying over the paths to the struct
    if (table.getArray("defaults")) |_| {
        // TODO: Match path to a file and avoid re-processing the file

        // for (arr.items()) |ref| {
        //     std.debug.print("ref: {s}\n", .{ref.string});
        // }
    }

    var project = try Project.init(allocator, "dummy");
    errdefer project.deinit();

    const arenaAllocator = project.arena.allocator();

    var iter = table.table.keyIterator();
    var index: u6 = 0;
    while (iter.next()) |key| {
        const tbl = table.getTable(key.*) orelse continue;

        const name = try arenaAllocator.dupe(u8, key.*);

        if (project.steps.get(name)) |_| {
            return StepErrors.StepRedefinition;
        }

        const runner = res: {
            if (tbl.getString("runner")) |runner| {
                break :res try arenaAllocator.dupe(u8, runner);
            } else {
                break :res "";
            }
        };

        var step: Step = .{
            .name = name,
            .bitPosition = @as(StepBitPosition, 1) << index,
            .data = undefined,
            .runner = runner,
            .dependsOn = &.{},
        };

        if (tbl.getArray("dependsOn")) |deps| {
            const items = deps.items();
            var dependsOn = try arenaAllocator.alloc(StepName, items.len);

            for (items, 0..) |item, ix| {
                dependsOn[ix] = try arenaAllocator.dupe(u8, item.string);
            }

            step.dependsOn = dependsOn;
        }

        if (tbl.table.get("data")) |tableData| {
            var dataBuilder = std.ArrayList(u8).init(arenaAllocator);
            defer dataBuilder.deinit();
            const jsonWriter = dataBuilder.writer();
            var jsonData = json.JsonBufferWriter.init(arenaAllocator, jsonWriter, .{ .whitespace = .minified });
            defer jsonData.deinit();

            try json.tomlToJson(&jsonData, tableData);

            step.data = try dataBuilder.toOwnedSlice();
        } else {
            step.data = try arenaAllocator.alloc(u8, 0);
        }

        try project.steps.put(name, step);

        index += 1;
    }

    return project;
}

test "basic add functionality" {
    // const data = try parseFile(testing.allocator, "./sample.lift.toml");
    // try testing.expect(data.steps.contains("dependencies"));

    const toml =
        \\defaults = ["./base.toml", "./extra.toml"]
        \\[dependencies]
        \\runner = "echo"
        \\data = [
        \\  "org.slf4j:slf4j-api:jar:2.0.17"
        \\]
        \\
        \\[sources]
        \\runner = "echo"
        \\data = [
        \\  "./src/main/java/"
        \\]
        \\
        \\[compile]
        \\runner = "echo"
        \\dependsOn = ["dependencies", "sources"]
        \\
        \\[compile.data]
        \\targetVersion = 21
        \\sourceVersion = 21
        \\
        \\[build]
        \\runner = "build-v0.1"
        \\dependsOn = ["dependencies", "sources", "compile"]
    ;

    var project = try parseString(testing.allocator, toml);
    defer project.deinit();

    const deps = project.steps.getPtr("dependencies").?;
    try testing.expectEqual(0, deps.dependsOn.len);
    try testing.expectEqualStrings("[\"org.slf4j:slf4j-api:jar:2.0.17\"]", deps.data);

    const sources = project.steps.getPtr("sources").?;
    try testing.expectEqual(0, sources.dependsOn.len);
    try testing.expectEqualStrings("[\"./src/main/java/\"]", sources.data);

    const compile = project.steps.getPtr("compile").?;
    try testing.expectEqual(2, compile.dependsOn.len);
    try testing.expectEqualStrings("{\"targetVersion\":21,\"sourceVersion\":21}", compile.data);

    const executionPlan = try project.prepareRunForTarget("build");

    try testing.expectEqual(4, executionPlan.steps.len);
    try testing.expectEqual(project.steps.getPtr("dependencies").?, executionPlan.steps[0]);
    try testing.expectEqual(project.steps.getPtr("sources").?, executionPlan.steps[1]);
    try testing.expectEqual(project.steps.getPtr("compile").?, executionPlan.steps[2]);
    try testing.expectEqual(project.steps.getPtr("build").?, executionPlan.steps[3]);

    var unknown: [5]u8 = undefined;
    try testing.expectError(StepErrors.StepNotFound, project.pathForStepFile(&unknown, "data.json"));
    const build = project.steps.getPtr("build").?;

    const targetPath = try project.pathForStepFile(build.name, "output.json");
    try testing.expectEqualStrings("/run/user/1000/lift/9E4TPB8S320FP/dummy/build/output.json", targetPath);
}
