const std = @import("std");
const worker = @import("worker.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

    const dep = try worker.Dependency.jar(allocator, group, artifact, version);

    var w1 = try worker.Worker.init(allocator);

    for (0..44) |_| {
        const item = try allocator.create(worker.WorkItem);
        item.* = worker.WorkItem.Dep(dep);
        try w1.enqueue(item);
    }

    try w1.enqueue(&worker.WorkItem.StopQueue());
    w1.thread.join();
}
