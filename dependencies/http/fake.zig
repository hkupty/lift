const std = @import("std");
const spec = @import("../pom/spec.zig");
const config = @import("config");

const Fake = @This();

pub fn download(_: *const Fake, allocator: std.mem.Allocator, key: spec.PomKey) ![]const u8 {
    const fname = try std.fmt.allocPrint(allocator, "{s}-{s}.pom", .{ key.artifactId, key.version });
    const path = try std.fs.path.join(allocator, &[_][]const u8{ config.TEST_DATA_PATH, fname });
    defer allocator.free(fname);
    defer allocator.free(path);

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    // HACK: Arbitrary file size, just for testing - for now
    return file.readToEndAlloc(allocator, 1 << 16);
}
