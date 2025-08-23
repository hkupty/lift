const std = @import("std");
const xxhash = std.hash.XxHash32;
const spec = @import("../spec.zig");

pub const PomKey = struct {
    group: []const u8,
    artifact: []const u8,
    version: []const u8,

    const Error = error{
        MalformedIdentifier,
    };

    pub const Context = struct {
        pub fn hash(_: *const Context, key: PomKey) u32 {
            var hashValue = xxhash.init(0);
            hashValue.update(key.group);
            hashValue.update(key.artifact);
            hashValue.update(key.version);

            return hashValue.final();
        }

        pub fn eql(_: *const Context, a: PomKey, b: PomKey) bool {
            return std.mem.eql(u8, a.group, b.group) and
                std.mem.eql(u8, a.artifact, b.artifact) and
                std.mem.eql(u8, a.version, b.version);
        }
    };

    pub const IgnoreVersionArrayHashMapContext = struct {
        pub fn hash(_: @This(), key: PomKey) u32 {
            var hashValue = xxhash.init(0);
            hashValue.update(key.group);
            hashValue.update(key.artifact);

            return hashValue.final();
        }

        pub fn eql(_: @This(), a: PomKey, b: PomKey, _: usize) bool {
            return std.mem.eql(u8, a.group, b.group) and
                std.mem.eql(u8, a.artifact, b.artifact);
        }
    };

    pub fn fullRemotePathZ(self: *const @This(), allocator: std.mem.Allocator, host: []const u8) ![:0]u8 {
        const groupParts = try std.mem.replaceOwned(u8, allocator, self.group, ".", "/");
        const filename = try std.fmt.allocPrint(allocator, "{s}-{s}.pom", .{ self.artifact, self.version });
        defer allocator.free(groupParts);
        const parts = [_][]const u8{
            host,
            groupParts,
            self.artifact,
            self.version,
            filename,
        };

        return std.mem.joinZ(allocator, "/", &parts);
    }

    pub fn parse(allocator: std.mem.Allocator, identifier: []const u8) !PomKey {
        const groupIx = std.mem.indexOfScalar(u8, identifier, ':') orelse return Error.MalformedIdentifier;
        const group = try allocator.dupe(u8, identifier[0..groupIx]);
        errdefer allocator.free(group);
        const artifactIx = std.mem.indexOfScalarPos(u8, identifier, groupIx + 1, ':') orelse return Error.MalformedIdentifier;
        const artifact = try allocator.dupe(u8, identifier[groupIx + 1 .. artifactIx]);
        errdefer allocator.free(artifact);
        const version = try allocator.dupe(u8, identifier[artifactIx + 1 ..]);

        return .{
            .group = group,
            .artifact = artifact,
            .version = version,
        };
    }

    pub fn deinit(self: *PomKey, allocator: std.mem.Allocator) void {
        allocator.free(self.group);
        allocator.free(self.artifact);
        allocator.free(self.version);
    }
};

pub const PomCache = std.HashMap(PomKey, Pom, PomKey.Context, 80);
pub const Dependencies = std.ArrayListUnmanaged(spec.Asset);
pub const PropertiesMap = std.StringArrayHashMapUnmanaged([]const u8);

pub const Pom = struct {
    packaging: Packaging = .jar,
    properties: PropertiesMap,
    parent: ?PomKey = null,
    dependencies: Dependencies,
    dependencyManagement: Dependencies,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.dependencies.deinit(allocator);
        self.dependencyManagement.deinit(allocator);
        self.properties.deinit(allocator);
    }
};

pub const Asset = spec.Asset;
pub const Scope = spec.Scope;
pub const Packaging = spec.Packaging;
