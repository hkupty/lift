const std = @import("std");
const fs = std.fs;
const json = std.json;
const process = std.process;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) unreachable;
    }
    const allocator = gpa.allocator();

    var args = process.args();
    defer args.deinit();
    _ = args.skip();

    if (args.next()) |path| {
        const jsonFile = try fs.openFileAbsolute(path, .{});
        defer jsonFile.close();
        var reader = json.reader(allocator, jsonFile.reader());
        defer reader.deinit();

        var target = json.writeStream(std.io.getStdOut().writer(), .{ .whitespace = .minified });
        try target.beginArray();

        while (true) {
            switch (try reader.nextAlloc(allocator, .alloc_if_needed)) {
                .string => |fpath| {
                    const dir = try std.fs.openDirAbsolute(fpath, .{ .iterate = true });
                    var walker = try dir.walk(allocator);
                    defer walker.deinit();
                    while (try walker.next()) |entry| {
                        if (entry.kind == .file) {
                            try target.write(entry.path);
                        }
                    }
                },
                .allocated_string => |fpath| {
                    defer allocator.free(fpath);
                    const dir = try std.fs.openDirAbsolute(fpath, .{ .iterate = true });
                    var walker = try dir.walk(allocator);
                    defer walker.deinit();
                    while (try walker.next()) |entry| {
                        if (entry.kind == .file) {
                            try target.write(entry.path);
                        }
                    }
                },
                .array_begin, .array_end => continue,
                .end_of_document => break,
                else => unreachable,
            }
        }

        try target.endArray();
    } else {
        process.exit(1);
    }
}
