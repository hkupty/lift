const std = @import("std");
const io = std.io;
const fs = std.fs;

pub fn writeMap(file: fs.File, map: std.StringHashMap([]u8)) !void {
    const writer = file.writer();
    try writer.print("{{", .{});
    var iter = map.iterator();
    var next = false;
    while (iter.next()) |entry| {
        if (next) {
            try writer.print(",", .{});
        } else {
            next = true;
        }
        try writer.print("\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    try writer.print("}}", .{});
}

pub fn writeList(file: fs.File, list: [][]u8) !void {
    const writer = file.writer();
    try writer.print("[", .{});
    var next = false;
    for (list) |entry| {
        if (next) {
            try writer.print(",", .{});
        } else {
            next = true;
        }
        try writer.print("\"{s}\"", .{entry});
    }
    try writer.print("]", .{});
}
