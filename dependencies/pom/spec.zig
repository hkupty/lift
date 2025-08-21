const std = @import("std");
const xxhash = std.hash.XxHash32;
const spec = @import("../spec.zig");

pub const PomKey = struct {
    group: []const u8,
    artifactId: []const u8,
    version: []const u8,

    const Context = struct {
        pub fn hash(_: *const Context, key: PomKey) u32 {
            std.log.debug("Hashing key {s}:{s}", .{ key.group, key.artifactId });
            var hashValue = xxhash.init(0);
            hashValue.update(key.group);
            hashValue.update(key.artifactId);
            hashValue.update(key.version);

            return hashValue.final();
        }

        pub fn eql(_: *const Context, a: PomKey, b: PomKey) bool {
            std.log.debug("comparing key {s}:{s} with {s}:{s}", .{ a.group, a.artifactId, b.group, b.artifactId });
            return std.mem.eql(u8, a.group, b.group) and
                std.mem.eql(u8, a.artifactId, b.artifactId) and
                std.mem.eql(u8, a.version, b.version);
        }
    };

    pub fn fullRemotePathZ(self: *const @This(), allocator: std.mem.Allocator, host: []const u8) ![:0]u8 {
        const groupParts = try std.mem.replaceOwned(u8, allocator, self.group, ".", "/");
        const filename = try std.fmt.allocPrint(allocator, "{s}-{s}.pom", .{ self.artifactId, self.version });
        defer allocator.free(groupParts);
        const parts = [_][]const u8{
            host,
            groupParts,
            self.artifactId,
            self.version,
            filename,
        };

        return std.mem.joinZ(allocator, "/", &parts);
    }
};

pub const PomCache = std.HashMap(PomKey, Pom, PomKey.Context, 80);
pub const Dependencies = std.ArrayList(spec.Asset);
pub const PropertiesMap = std.StringHashMap([]const u8);

pub const Pom = struct {
    properties: PropertiesMap,
    parent: ?PomKey = null,
    dependencies: Dependencies,
    dependencyManagement: Dependencies,

    pub fn deinit(self: *@This()) void {
        self.dependencies.deinit();
        self.dependencyManagement.deinit();
        self.properties.deinit();
    }
};

pub const Asset = spec.Asset;
pub const Scope = spec.Scope;
