const std = @import("std");

pub const DependencyFormat = union(enum) {
    jar: void,
    pom: void,
    other: []u8,
};

pub const Repository = union(enum) {
    maven: void,
};

pub const Dependency = struct {
    group: []u8,
    artifact: []u8,
    version: []u8,
    format: DependencyFormat,
    repository: Repository,
    allocator: std.mem.Allocator,

    pub fn string(self: *const Dependency) ![]u8 {
        var buf: [512]u8 = undefined;
        return std.fmt.bufPrint(&buf, "{s}:{s}:{s}", .{ self.group, self.artifact, self.version });
    }

    pub fn filename(self: *const Dependency, allocator: std.mem.Allocator) ![]u8 {
        const extension = switch (self.format) {
            .jar => "jar",
            .pom => "pom",
            .other => |fmt| fmt,
        };
        return std.fmt.allocPrint(allocator, "{s}-{s}.{s}", .{ self.artifact, self.version, extension });
    }

    pub fn deinit(self: *const Dependency) void {
        self.allocator.free(self.group);
        self.allocator.free(self.artifact);
        self.allocator.free(self.version);
    }
};

pub const DependencyErrors = error{
    MalformedDependencyDirective,
};

pub const DependencyCoords = struct {
    group: []const u8,
    artifact: []const u8,
    version: []const u8,

    pub fn parse(directive: []const u8) !DependencyCoords {
        var iter = std.mem.splitSequence(u8, directive, ":");

        const group = iter.first();
        const artifact = iter.next() orelse {
            std.log.err("Unable to get artifact from dependency directive {s}", .{directive});
            return DependencyErrors.MalformedDependencyDirective;
        };

        const version = iter.next() orelse {
            std.log.err("Unable to get version from dependency directive {s}", .{directive});
            return DependencyErrors.MalformedDependencyDirective;
        };

        return .{
            .group = group,
            .artifact = artifact,
            .version = version,
        };
    }

    pub fn jar(self: *const DependencyCoords, allocator: std.mem.Allocator) !Dependency {
        const group = try allocator.dupe(u8, self.group);
        errdefer allocator.free(group);
        const artifact = try allocator.dupe(u8, self.artifact);
        errdefer allocator.free(artifact);
        const version = try allocator.dupe(u8, self.version);
        errdefer allocator.free(version);

        return .{
            .group = group,
            .artifact = artifact,
            .version = version,
            .format = .jar,
            .repository = .maven, // TODO: Make repository configurable
            .allocator = allocator,
        };
    }

    pub fn pom(self: *const DependencyCoords, allocator: std.mem.Allocator) !Dependency {
        const group = try allocator.dupe(u8, self.group);
        errdefer allocator.free(group);
        const artifact = try allocator.dupe(u8, self.artifact);
        errdefer allocator.free(artifact);
        const version = try allocator.dupe(u8, self.version);
        errdefer allocator.free(version);

        return .{
            .group = group,
            .artifact = artifact,
            .version = version,
            .format = .pom,
            .repository = .maven, // TODO: Make repository configurable
            .allocator = allocator,
        };
    }
};
