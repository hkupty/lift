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
// TODO: Add project build folder path to project struct

pub const StepErrors = error{
    /// This error is fired when a step is re-defined.
    StepRedefinition,

    /// This error is fired when a step parameter can't be parsed
    StepParameterIssue,

    /// This error is fired when a target/step is requested but it doesn't exist
    StepNotFound,
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

    pub fn run(self: *Step) !void {
        try self.data.asJson(self.name);
        // TODO: Locate runner
        // it can be either a path-based binary(+ lift installation folder) or a remote target that might need downloading (future);
        // TODO: Aggregate arguments to runner (self.data + dependencies outputs);
        std.debug.print("[{s}] Running {s}\n", .{ self.name, self.runner });
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

    pub fn asJson(self: *StepData, step: StepName) !void {
        switch (self.*) {
            .list => |ls| {
                var fpathBuffer: [4096]u8 = undefined;
                // HACK: Replace /tmp/lift-data... with proper project build path
                const fpath = try std.fmt.bufPrint(&fpathBuffer, "/tmp/lift-data-{s}.json", .{step});
                const datafile = try std.fs.createFileAbsolute(fpath, .{});
                defer datafile.close();
                try json.writeList(datafile, ls);
            },
            .map => |mp| {
                var fpathBuffer: [4096]u8 = undefined;
                // HACK: Replace /tmp/lift-data... with proper project build path
                const fpath = try std.fmt.bufPrint(&fpathBuffer, "/tmp/lift-data-{s}.json", .{step});
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
    steps: []*Step,

    pub fn deinit(self: *ExecutionPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.steps);
    }

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
            try step.run();
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
    steps: std.StringHashMap(Step),
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Project) void {
        self.steps.deinit();
        self.arena.deinit();
    }

    pub fn prepareRunForTarget(self: *Project, allocator: std.mem.Allocator, target: []const u8) !ExecutionPlan {
        const initialStep = self.steps.getPtr(target) orelse return StepErrors.StepNotFound;
        var steps = StepsList.init(allocator);
        defer steps.deinit();

        try steps.dfsAppend(self, initialStep);

        const stepsSlice = try steps.queue.toOwnedSlice();

        return .{
            .execution = 0,
            .steps = stepsSlice,
        };
    }

    pub fn init(allocator: std.mem.Allocator) !*Project {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const arenaAllocator = arena.allocator();

        const proj = try arenaAllocator.create(Project);
        proj.* = .{
            .arena = arena,
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

    var project = try Project.init(allocator);
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

    var run2 = try project.prepareRunForTarget(testing.allocator, "build");
    try run2.run();
    defer run2.deinit(testing.allocator);
}
