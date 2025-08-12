const std = @import("std");
const RealErr = std.fs.Dir.RealPathAllocError;
const MakeError = std.fs.Dir.MakeError;
const AccessError = std.fs.Dir.AccessError;
const spec = @import("spec.zig");

pub const LocalRepo = struct {
    base: std.fs.Dir,
    basePath: []const u8,

    pub fn init(path: []const u8) !LocalRepo {
        const dir = try std.fs.openDirAbsolute(path, .{});
        return .{
            .base = dir,
            .basePath = path,
        };
    }

    pub fn deinit(self: *LocalRepo) void {
        self.base.close();
    }

    pub fn absolutePath(self: *LocalRepo, allocator: std.mem.Allocator, dep: spec.Asset, kind: spec.AssetType) ![]u8 {
        const parts = [_][]const u8{
            self.basePath,
            dep.group,
            dep.artifact,
            dep.version,
            try dep.remoteFilename(allocator, kind),
        };

        return std.fs.path.join(allocator, &parts);
    }

    pub fn prepare(self: *LocalRepo, allocator: std.mem.Allocator, dep: spec.Asset) !void {
        const parts = [_][]const u8{
            dep.group,
            dep.artifact,
            dep.version,
        };

        const child = try std.fs.path.join(allocator, &parts);

        self.base.makePath(child) catch |err| {
            switch (err) {
                MakeError.PathAlreadyExists => {},
                else => return err,
            }
        };
    }

    pub fn exists(self: *LocalRepo, allocator: std.mem.Allocator, dep: spec.Asset, kind: spec.AssetType) !bool {
        const child = try self.absolutePath(allocator, dep, kind);
        defer allocator.free(child);
        self.base.access(child, .{}) catch |err| {
            switch (err) {
                AccessError.FileNotFound,
                AccessError.BadPathName,
                AccessError.InvalidUtf8,
                AccessError.InvalidWtf8,
                AccessError.NameTooLong,
                => return false,
                else => return err,
            }

            return true;
        };
    }
};
