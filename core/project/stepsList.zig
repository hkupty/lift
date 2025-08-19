const std = @import("std");
const Step = @import("step.zig");

/// StepsList is an auxiliary data type which enables building a queue for the execution plan by
/// performing a graph traversal through all the steps based on their declared dependencies
const StepsList = @This();

queue: std.ArrayList(*Step),
filter: u64,
// TODO: Keep track of circular dependencies

pub fn init(allocator: std.mem.Allocator) StepsList {
    return .{ .filter = 0, .queue = std.ArrayList(*Step).init(allocator) };
}

pub fn deinit(self: *StepsList) void {
    self.queue.deinit();
}

pub fn dfsAppend(self: *StepsList, steps: *std.StringHashMap(Step), ref: *Step) !void {
    for (ref.dependsOn) |dep| {
        const next = steps.getPtr(dep) orelse continue;
        if ((self.filter & next.bitPosition) != 0) continue;
        try self.dfsAppend(steps, next);
    }
    self.filter |= ref.bitPosition;
    try self.queue.append(ref);
}
