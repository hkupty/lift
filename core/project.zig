const std = @import("std");
const testing = std.testing;
const tomlz = @import("tomlz");
const json = @import("json.zig");

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
    data: StepData,

    pub fn run(self: *Step, project: *Project) !void {
        // TODO: Locate runner
        // it can be either a path-based binary(+ lift installation folder) or a remote target that might need downloading (future);

        if (self.runner.len == 0) {
            return;
        }

        var arguments = std.ArrayList([]const u8).init(project.arena.allocator());
        defer arguments.deinit();

        try arguments.append(self.runner);
        switch (self.data) {
            .none => {},
            else => {
                const dataPath = try project.pathForStepFile(self.name, "data.json");
                try self.data.asJson(dataPath);
                try arguments.append(dataPath);
            },
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

        std.debug.print("[{s}] Running", .{self.name});
        for (args) |arg| {
            std.debug.print(" {s}", .{arg});
        }
        std.debug.print("\n", .{});
        var process = std.process.Child.init(args, project.arena.allocator());

        process.stdout_behavior = .Pipe;

        try process.spawn();

        const stdoutReader = process.stdout.?.reader();

        const outPath = try project.pathForStepFile(self.name, "output.json");
        const outFile = try std.fs.createFileAbsolute(outPath, .{});
        const writer = outFile.writer();

        var read = true;
        var buffer: [512]u8 = undefined;
        while (read) {
            const amountRead = try stdoutReader.read(&buffer);
            read = amountRead > 0;
            if (read) {
                _ = try writer.write(buffer[0..amountRead]);
            }
        }

        const term = try process.wait();

        if (term.Exited != 0) {
            return StepErrors.StepExecutionFailed;
        }

        defer outFile.close();

        // TODO: Aggregate arguments to runner (self.data + dependencies outputs);
    }
};

// TODO: Incorporate this in StepData so steps can take more than strings
// TODO: Move common types out so json formatting can be aware of those polymorphic types
pub const StepArgument = union(enum) {
    string: []u8,
    number: i64,
    boolean: bool,
};

pub const StepData = union(enum) {
    list: [][]u8,
    // TODO: replace with std.HashMapUnmanaged for better memory usage (i.e. arenas)
    map: std.StringHashMap([]u8),
    none: void,

    pub fn asJson(self: *StepData, fpath: []u8) !void {
        switch (self.*) {
            .list => |ls| {
                const datafile = try std.fs.createFileAbsolute(fpath, .{});
                defer datafile.close();
                try json.writeList(datafile, ls);
            },
            .map => |mp| {
                const datafile = try std.fs.createFileAbsolute(fpath, .{});
                defer datafile.close();
                try json.writeMap(datafile, mp);
            },
            .none => {},
        }
    }
};

pub const ExecutionPlan = struct {
    execution: u64,
    project: *Project,
    steps: []*Step,

    pub fn print(self: *ExecutionPlan) void {
        std.debug.print("[", .{});
        var hasRun = false;
        for (self.steps) |step| {
            if (!hasRun) {
                hasRun = true;
            } else {
                std.debug.print(", ", .{});
            }
            std.debug.print("{s}", .{step.name});
        }
        std.debug.print("]\n", .{});
    }

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
    buildPath: []u8,
    steps: std.StringHashMap(Step),
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Project) void {
        self.steps.deinit();
        self.arena.deinit();
    }

    fn pathForStepFile(self: *Project, stepName: StepName, file: []const u8) ![]u8 {
        _ = self.steps.get(stepName) orelse return StepErrors.StepNotFound;
        return try std.fmt.allocPrint(self.arena.allocator(), "{s}{s}-{s}", .{ self.buildPath, stepName, file });
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
        const buildPath = try std.fmt.allocPrint(arenaAllocator, "/tmp/lift/build-{s}/", .{name});
        const ownedName = try arenaAllocator.dupe(u8, name);

        std.fs.makeDirAbsolute(buildPath) catch |err| {
            switch (err) {
                std.fs.Dir.MakeError.FileNotFound => {
                    std.fs.makeDirAbsolute("/tmp/lift/") catch |perr| {
                        switch (perr) {
                            std.fs.Dir.MakeError.PathAlreadyExists => {
                                // TODO: Log
                            },
                            else => return perr,
                        }
                    };
                    try std.fs.makeDirAbsolute(buildPath);
                },

                std.fs.Dir.MakeError.PathAlreadyExists => {
                    // TODO: Log
                },
                else => return err,
            }
        };

        const proj = try arenaAllocator.create(Project);
        proj.* = .{
            .arena = arena,
            .name = ownedName,
            .buildPath = buildPath,
            .steps = std.StringHashMap(Step).init(allocator),
        };

        return proj;
    }
};

// pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !Project {
//     const table = try toml.parse(allocator);
// }

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
            .data = StepData.none,
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

        if (tbl.getArray("data")) |dataArray| {
            const items = dataArray.items();
            var config = try arenaAllocator.alloc([]u8, items.len);
            for (items, 0..) |item, ix| {
                config[ix] = try arenaAllocator.dupe(u8, item.string);
            }
            step.data = .{ .list = config };
        } else if (tbl.getTable("data")) |dataTable| {
            var keys = dataTable.table.keyIterator();

            var map = std.StringHashMap([]u8).init(arenaAllocator);

            while (keys.next()) |innerKey| {
                const localKey = try arenaAllocator.dupe(u8, innerKey.*);
                const val = dataTable.getString(innerKey.*) orelse return StepErrors.StepParameterIssue;
                const ownedVal = try arenaAllocator.dupe(u8, val);
                try map.put(localKey, ownedVal);
            }

            step.data = .{ .map = map };
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
        \\targetVersion = "21"
        \\sourceVersion = "21"
        \\
        \\[build]
        \\runner = "build-v0.1"
        \\dependsOn = ["dependencies", "sources", "compile"]
    ;

    var project = try parseString(testing.allocator, toml);
    defer project.deinit();

    const deps = project.steps.getPtr("dependencies").?;
    try testing.expectEqual(0, deps.dependsOn.len);
    try testing.expectEqualStrings("org.slf4j:slf4j-api:jar:2.0.17", deps.data.list[0]);

    const sources = project.steps.getPtr("sources").?;
    try testing.expectEqual(0, sources.dependsOn.len);
    try testing.expectEqualStrings("./src/main/java/", sources.data.list[0]);

    const compile = project.steps.getPtr("compile").?;
    try testing.expectEqual(2, compile.dependsOn.len);
    try testing.expectEqualStrings("21", compile.data.map.get("targetVersion").?);

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
    try testing.expectEqualStrings("/tmp/lift/build-dummy/build-output.json", targetPath);
}
