const std = @import("std");
const shared = @import("lift_shared");
const tomlz = @import("tomlz");

const json = @import("json.zig");
const Step = @import("step.zig");
const models = @import("models.zig");
const StepMapper = @import("stepMapper.zig");
const StepsList = @import("stepsList.zig");

const BuildStepConfig = models.BuildStepConfig;

name: []u8,
dir: std.fs.Dir,
steps: std.StringHashMap(Step),
arena: std.heap.ArenaAllocator,
stepMapper: StepMapper,

const Project = @This();

const Runner = struct {
    const ArgsList = std.ArrayList([]const u8);

    execution: models.StepBitPosition = 0,
    allocator: std.mem.Allocator,
    args: ArgsList,
    plan: StepsList,
    mapper: *StepMapper,

    pub fn init(allocator: std.mem.Allocator, project: *Project, target: []const u8) !Runner {
        const initialStep = project.steps.getPtr(target) orelse return models.StepErrors.StepNotFound;
        var plan = StepsList.init(allocator);
        try plan.dfsAppend(&project.steps, initialStep);

        return .{
            .plan = plan,
            .mapper = &project.stepMapper,
            .args = ArgsList.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Runner) void {
        self.args.deinit();
        self.plan.deinit();
    }

    pub fn run(self: *Runner) !void {
        for (self.plan.queue.items) |step| {
            defer self.execution |= step.bitPosition;
            defer self.args.clearRetainingCapacity();
            if (step.runner.len == 0) continue;
            try self.args.ensureUnusedCapacity(2 + step.dependsOn.len);
            self.args.appendAssumeCapacity(step.runner);
            self.args.appendAssumeCapacity(try self.mapper.datapath(step));

            // HACK: Explicit assumption here that `dep` was already executed.
            // We shouldn't trust ourselves.
            for (step.dependsOn) |dep| {
                self.args.appendAssumeCapacity(try self.mapper.outpath(dep));
            }

            var process = std.process.Child.init(self.args.items, self.allocator);

            // TODO: Split spawn and wait
            const term = try process.spawnAndWait();

            if (term.Exited != 0) {
                return models.StepErrors.StepExecutionFailed;
            }
        }
    }
};

pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir) !Project {
    const arena = std.heap.ArenaAllocator.init(allocator);

    const path = try dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);
    const name = try allocator.dupe(u8, std.fs.path.basename(path));

    var project: Project = .{
        .arena = arena,
        .name = name,
        .stepMapper = StepMapper.init(allocator, name, path),
        .dir = dir,
        .steps = std.StringHashMap(Step).init(allocator),
    };

    try project.parseBuildFile();

    return project;
}

pub fn deinit(self: *Project) void {
    var allocator = self.arena.child_allocator;
    self.stepMapper.deinit();
    self.steps.deinit();
    allocator.free(self.name);
    self.arena.deinit();
}

pub fn run(self: *Project, target: []const u8) !void {
    var runner = try Runner.init(self.arena.allocator(), self, target);
    defer runner.deinit();
    try runner.run();
}

fn parseBuildFile(self: *Project) !void {
    const file = try self.dir.openFile("build.toml", .{});
    defer file.close();
    const allocator = self.arena.allocator();
    const content = try file.readToEndAlloc(allocator, std.math.maxInt(u32));
    defer allocator.free(content);

    return self.parseBuildData(content);
}

fn parseBuildData(self: *Project, data: []const u8) !void {
    const allocator = self.arena.allocator();
    var table = try tomlz.parse(allocator, data);
    defer table.deinit(allocator);

    // TODO: Merge defaults into a single Project definition instead of carrying over the paths to the struct
    if (table.getArray("defaults")) |_| {
        // TODO: Match path to a file and avoid re-processing the file

        // for (arr.items()) |ref| {
        //     std.debug.print("ref: {s}\n", .{ref.string});
        // }
    }

    var iter = table.table.keyIterator();
    var index: u6 = 0;
    while (iter.next()) |key| {
        const tbl = table.getTable(key.*) orelse continue;

        const name = try allocator.dupe(u8, key.*);

        if (self.steps.get(name)) |_| {
            return models.StepErrors.StepRedefinition;
        }

        const runner = res: {
            if (tbl.getString("runner")) |runner| {
                break :res try allocator.dupe(u8, runner);
            } else {
                break :res "";
            }
        };

        var step: Step = .{
            .name = name,
            .bitPosition = @as(models.StepBitPosition, 1) << index,
            .data = undefined,
            .runner = runner,
            .dependsOn = &.{},
        };

        if (tbl.getArray("dependsOn")) |deps| {
            const items = deps.items();
            var dependsOn = try allocator.alloc(models.StepName, items.len);

            for (items, 0..) |item, ix| {
                dependsOn[ix] = try allocator.dupe(u8, item.string);
            }

            step.dependsOn = dependsOn;
        }

        if (tbl.table.get("data")) |tableData| {
            var dataBuilder = std.ArrayList(u8).init(allocator);
            defer dataBuilder.deinit();
            const jsonWriter = dataBuilder.writer();
            var jsonData = json.JsonBufferWriter.init(allocator, jsonWriter, .{ .whitespace = .minified });
            defer jsonData.deinit();

            try json.tomlToJson(&jsonData, tableData);

            step.data = try dataBuilder.toOwnedSlice();
        } else {
            step.data = try allocator.alloc(u8, 0);
        }

        try self.steps.put(name, step);

        index += 1;
    }
}
