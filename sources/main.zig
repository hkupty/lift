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
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = process.args();
    defer args.deinit();
    _ = args.skip();

    if (args.next()) |path| {
        const jsonFile = try fs.openFileAbsolute(path, .{});
        defer jsonFile.close();
        var reader = json.reader(allocator, jsonFile.reader());
        defer reader.deinit();

        var target = json.writeStream(std.io.getStdOut().writer(), .{ .whitespace = .minified });
        try target.beginObject();
        try target.objectField("sources");
        try target.beginArray();

        const cwd = fs.cwd();

        while (true) {
            switch (try reader.nextAlloc(allocator, .alloc_if_needed)) {
                .allocated_string, .string => |fpath| {
                    const dir = cwd.openDir(fpath, .{ .iterate = true }) catch |err| {
                        std.log.err("Unable to open path {s}: {any}", .{ fpath, err });
                        process.exit(1);
                    };
                    var walker = try dir.walk(allocator);
                    defer walker.deinit();
                    while (try walker.next()) |entry| {
                        if (entry.kind == .file) {
                            const file = try std.fmt.allocPrint(allocator, "{s}{s}", .{ fpath, entry.path });
                            try target.write(file);
                        }
                    }
                },
                .array_begin, .array_end => continue,
                .end_of_document => break,
                else => unreachable,
            }
        }

        try target.endArray();
        try target.endObject();
    } else {
        process.exit(1);
    }
}
