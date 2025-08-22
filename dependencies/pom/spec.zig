const std = @import("std");
const xxhash = std.hash.XxHash32;
const spec = @import("../spec.zig");

pub const PomKey = struct {
    group: []const u8,
    artifact: []const u8,
    version: []const u8,

    pub const Context = struct {
        pub fn hash(_: *const Context, key: PomKey) u32 {
            std.log.debug("Hashing key {s}:{s}", .{ key.group, key.artifact });
            var hashValue = xxhash.init(0);
            hashValue.update(key.group);
            hashValue.update(key.artifact);
            hashValue.update(key.version);

            return hashValue.final();
        }

        pub fn eql(_: *const Context, a: PomKey, b: PomKey) bool {
            std.log.debug("comparing key {s}:{s} with {s}:{s}", .{ a.group, a.artifact, b.group, b.artifact });
            return std.mem.eql(u8, a.group, b.group) and
                std.mem.eql(u8, a.artifact, b.artifact) and
                std.mem.eql(u8, a.version, b.version);
        }
    };

    pub const IgnoreVersionArrayHashMapContext = struct {
        pub fn hash(_: Context, key: PomKey) u32 {
            std.log.debug("Hashing key {s}:{s}", .{ key.group, key.artifact });
            var hashValue = xxhash.init(0);
            hashValue.update(key.group);
            hashValue.update(key.artifact);

            return hashValue.final();
        }

        pub fn eql(_: Context, a: PomKey, b: PomKey, _: usize) bool {
            std.log.debug("comparing key {s}:{s} with {s}:{s}", .{ a.group, a.artifact, b.group, b.artifact });
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
