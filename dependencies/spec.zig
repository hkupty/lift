const std = @import("std");

pub const AssetType = union(enum) {
    jar: void,
    jar_sha1: void,
    pom: void,
    other: []const u8,

    pub fn extension(self: AssetType) []const u8 {
        return switch (self) {
            .jar => "jar",
            .jar_sha1 => "jar.sha1",
            .pom => "pom",
            .other => |fmt| fmt,
        };
    }
};

pub const Repository = union(enum) {
    maven: []const u8,
};

pub const defaultMaven: Repository = .{ .maven = "https://repo1.maven.org/maven2" };

pub const DependencyErrors = error{
    MalformedDependencyDirective,
};

pub const Asset = struct {
    group: []const u8,
    artifact: []const u8,
    version: []const u8,
    allocator: std.mem.Allocator,

    pub fn parse(allocator: std.mem.Allocator, directive: []const u8) !Asset {
        var iter = std.mem.splitSequence(u8, directive, ":");

        const group = try allocator.dupe(u8, iter.first());
        errdefer allocator.free(group);
        const artifact = try allocator.dupe(u8, iter.next() orelse {
            std.log.err("Unable to get artifact from dependency directive {s}", .{directive});
            return DependencyErrors.MalformedDependencyDirective;
        });

        errdefer allocator.free(artifact);

        const version = try allocator.dupe(u8, iter.next() orelse {
            std.log.err("Unable to get version from dependency directive {s}", .{directive});
            return DependencyErrors.MalformedDependencyDirective;
        });

        return .{
            .group = group,
            .artifact = artifact,
            .version = version,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const Asset) void {
        self.allocator.free(self.group);
        self.allocator.free(self.artifact);
        self.allocator.free(self.version);
    }

    pub fn identifier(self: *const Asset, allocator: std.mem.Allocator) ![]u8 {
        const parts = [_][]const u8{ self.group, self.artifact };
        return std.mem.join(
            allocator,
            ":",
            &parts,
        );
    }

    pub fn remoteFilename(self: *const Asset, allocator: std.mem.Allocator, assetType: AssetType) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}-{s}.{s}", .{ self.artifact, self.version, assetType.extension() });
    }

    pub fn remotePath(self: *const Asset, allocator: std.mem.Allocator, host: []const u8) ![]u8 {
        // TODO: Specialize for maven only

        const groupParts = try std.mem.replaceOwned(u8, allocator, self.group, ".", "/");
        defer allocator.free(groupParts);
        const parts = [_][]const u8{
            host,
            groupParts,
            self.artifact,
            self.version,
        };

        return std.mem.join(allocator, "/", &parts);
    }

    pub fn uri(self: *const Asset, allocator: std.mem.Allocator, repository: Repository) ![]u8 {
        switch (repository) {
            .maven => |url| return self.remotePath(allocator, url),
        }
    }
};
