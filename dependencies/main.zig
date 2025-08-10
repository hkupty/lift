const std = @import("std");
const worker = @import("worker.zig");
const Pool = worker.WorkerPool;
const Dependency = @import("spec.zig").Dependency;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) unreachable;
    }
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try allocator.dupe(u8, "asd");
    const artifact = try allocator.dupe(u8, "qwe");
    const version = try allocator.dupe(u8, "1.2");

    const dep = try Dependency.jar(group, artifact, version);

    var pool = try Pool.init(allocator);
    defer pool.deinit();

    for (0..55) |_| {
        const item = try allocator.create(worker.WorkItem);
        item.* = worker.WorkItem.Dep(dep);
        pool.enqueue(item) catch |err| {
            std.log.err("Unable to enqueue: {any}", .{err});
        };
    }
}
