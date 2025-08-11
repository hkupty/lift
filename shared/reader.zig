const std = @import("std");
const fs = std.fs;
const json = std.json;
const Parsed = json.Parsed;
const mem = std.mem;
const BuildStepConfig = @import("models.zig").BuildStepConfig;

pub fn readConfig(comptime T: type, allocator: mem.Allocator, path: []const u8) !Parsed(T) {
    const jsonFile = try fs.openFileAbsolute(path, .{});
    defer jsonFile.close();
    var reader = json.reader(allocator, jsonFile.reader());
    defer reader.deinit();

    const data = try json.parseFromTokenSource(T, allocator, &reader, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    return data;
}
