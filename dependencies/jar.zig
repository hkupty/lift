const std = @import("std");
const Dependency = @import("spec.zig").Dependency;
const http = std.http;

pub fn resolveMavenDependencyUrl(allocator: std.mem.Allocator, repository: []const u8, dep: Dependency) ![]u8 {
    var groupIter = std.mem.splitSequence(u8, dep.group, ".");
    var pathParts = try std.ArrayList([]u8).initCapacity(allocator, 8);
    defer pathParts.deinit();

    const repo = try allocator.dupe(u8, repository);

    // TODO: Fix allocations

    pathParts.appendAssumeCapacity(repo);
    const group = try allocator.dupe(u8, groupIter.first());
    pathParts.appendAssumeCapacity(group);

    while (groupIter.next()) |part| {
        try pathParts.append(try allocator.dupe(u8, part));
    }

    try pathParts.append(dep.artifact);
    try pathParts.append(dep.version);

    try pathParts.append(try dep.filename(allocator));
    const parts = try pathParts.toOwnedSlice();

    return std.mem.join(allocator, "/", parts);
}
