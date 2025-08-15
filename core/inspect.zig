const std = @import("std");
const mem = std.mem;
const json = std.json;
const fs = std.fs;

// TODO: Use Markers for cache handling

/// Markers are pieces of information that the Step can send back in the output that are interpreted
/// by the main process.
/// They can be used to hint at caching, communicate potential failures across steps, etc, which can be useful
/// to explain errors further down.
const Markers = struct {
    warn: [][]u8 = &[0][]u8{},
};

pub fn readMarkers(allocator: mem.Allocator, jsonFile: fs.File) !json.Parsed(Markers) {
    var reader = json.reader(allocator, jsonFile.reader());
    defer reader.deinit();

    const data = try json.parseFromTokenSource(Markers, allocator, &reader, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    return data;
}

pub fn analyzeOutput(allocator: mem.Allocator, jsonFile: fs.File) !void {
    const out = try readMarkers(allocator, jsonFile);
    defer out.deinit();
    for (out.value.warn) |warn| {
        std.log.warn("Failed with message: {s}", .{warn});
    }
}
