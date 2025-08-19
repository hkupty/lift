/// Represents the XDG directory specification, trimmed down
/// to only those that might be relevant to lift.
///
/// Note that this will already point to lift specific folders
const std = @import("std");
const known_folders = @import("known-folders");

const XDG = @This();

/// All cache files should be placed in a directory nested to this one.
cache: []u8,
/// Path to runtime dir, where builds will happen
run: []u8,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, name: []const u8, fingerprint: []const u8) XDG {
    const child = std.fs.path.join(allocator, &[_][]const u8{
        "lift",
        fingerprint,
        name,
    }) catch |err| x: {
        std.log.err("Failed to join paths: {any}. Falling back", .{err});
        break :x "lift";
    };
    defer allocator.free(child);

    const liftCache = fallbackGetDirectory(allocator, .cache, "lift");
    const liftRuntime = fallbackGetDirectory(allocator, .runtime, child);

    return .{
        .cache = liftCache,
        .run = liftRuntime,
        .allocator = allocator,
    };
}

pub fn runFor(self: *XDG, stepName: []const u8) ![]const u8 {
    return std.fs.path.join(self.allocator, &[_][]const u8{ self.run, stepName });
}

pub fn deinit(self: *XDG) void {
    self.allocator.free(self.cache);
    self.allocator.free(self.run);
}

fn fallbackGetDirectory(allocator: std.mem.Allocator, folder: known_folders.KnownFolder, child: []const u8) []u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = known_folders.getPath(allocator, folder) catch |err| x: {
        std.log.debug("Unable to get {any} folder: {any}", .{ folder, err });
        break :x null;
    } orelse y: {
        const target = switch (folder) {
            .cache => ".cache/",
            .runtime => ".run/", // TODO: Actually fail because we can't create a fallback to XDG_RUNTIME_DIR
            else => unreachable,
        };

        const home = known_folders.getPath(allocator, .home) catch |err| x: {
            std.log.warn("Unable to get home folder: {any}", .{err});

            break :x std.fs.realpath(".", &buf) catch |err2| {
                std.debug.panic("Unable to get any path: {any}. Aborting", .{err2});
            };
        } orelse unreachable;
        defer allocator.free(home);

        const homeDir = std.fs.openDirAbsolute(home, .{}) catch |err| {
            std.debug.panic("Unable to open path to operate: {any}. Aborting", .{err});
        };

        homeDir.makeDir(target) catch |err| {
            std.debug.panic("Unable to create path to operate: {any}. Aborting", .{err});
        };

        break :y homeDir.realpath(target, &buf) catch |err| {
            std.debug.panic("Likely going out of memory. If failing to allocate at this stage, better not to continue. {any}", .{err});
        };
    };
    defer allocator.free(dir);

    // Errors were handled above, if it fails now, we need to panic anyways.
    var root = std.fs.openDirAbsolute(dir, .{}) catch unreachable;

    root.makePath(child) catch |err| {
        switch (err) {
            std.fs.Dir.MakeError.PathAlreadyExists => {
                std.log.debug("Folder already exists", .{});
            },
            else => {
                std.debug.panic("Unable to operate due to error ({s}. {s}): {any}", .{ dir, child, err });
            },
        }
    };

    return root.realpathAlloc(allocator, child) catch |err| {
        std.debug.panic("Likely going out of memory. If failing to allocate at this stage, better not to continue. {any}", .{err});
    };
}
