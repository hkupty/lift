const std = @import("std");
const config = @import("config.zig");
const shared = @import("lift_shared");
const fs = std.fs;
const json = std.json;
const process = std.process;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) unreachable;
    }
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = process.args();
    defer args.deinit();
    _ = args.skip();

    const stepConfigFile = args.next() orelse {
        std.log.err("Missing default data file", .{});
        process.exit(1);
    };

    const parsed = try shared.readConfig(config.BuildStepConfig, allocator, stepConfigFile);
    defer parsed.deinit();

    const stepConfig = parsed.value;

    var target = json.writeStream(std.io.getStdOut().writer(), .{ .whitespace = .minified });
    try target.beginObject();
    try target.objectField("sources");
    try target.beginArray();

    const cwd = fs.cwd();

    for (stepConfig.data) |fpath| {
        const base = try allocator.dupe(u8, fpath);
        std.log.info("Walking {s}", .{base});
        const dir = cwd.openDir(fpath, .{ .iterate = true }) catch |err| {
            std.log.err("Unable to open path {s}: {any}", .{ fpath, err });
            process.exit(1);
        };
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind == .file) {
                const paths = [2][]const u8{ base, entry.path };
                const file = try std.fs.path.join(allocator, &paths);
                std.log.info("Adding file {s}", .{file});
                try target.write(&file);
            }
        }
    }

    try target.endArray();
    try target.endObject();
}
