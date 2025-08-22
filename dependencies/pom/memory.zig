const std = @import("std");
const spec = @import("spec.zig");
const Http = @import("../http/root.zig").Http;
const parser = @import("pom.zig");

const encoding = "encoding=\"";

fn recoverEncoding(allocator: std.mem.Allocator, slice: []const u8) ![]const u8 {
    const index = std.mem.indexOf(
        u8,
        slice,
        encoding,
    ).?;
    var out = try std.ArrayList(u8).initCapacity(allocator, slice.len * 2);
    for (slice) |b| {
        if (b < 0x80) {
            // ASCII maps 1:1
            try out.append(b);
        } else {
            // Encode as two-byte UTF-8 sequence
            const hi: u8 = 0b1100_0000 | (b >> 6); // top 2 bits
            const lo: u8 = 0b1000_0000 | (b & 0b0011_1111);
            try out.append(hi);
            try out.append(lo);
        }
    }

    out.replaceRangeAssumeCapacity(index + encoding.len, 10, "UTF-8");
    return out.toOwnedSlice();
}

/// The PomHive acts as a cache of inter-connected POM files, enabling them to resolve
/// values based on parent-defined properties
pub const PomHive = struct {
    cache: spec.PomCache,
    http: Http,
    arena: std.heap.ArenaAllocator,

    pub fn init(self: *PomHive, gpa: std.mem.Allocator) !void {
        self.arena = std.heap.ArenaAllocator.init(gpa);
        const allocator = self.arena.allocator();
        self.cache = spec.PomCache.initContext(allocator, .{});
        self.http = try Http.init(allocator);
    }

    pub fn deinit(self: *PomHive) void {
        self.cache.deinit();
        self.http.deinit();
        self.arena.deinit();
    }

    pub const PomDependencies = struct {
        hive: *PomHive,
        deps: []spec.Asset,
        properties: spec.PropertiesMap,
        parent: ?spec.PomKey,
        iter: usize = 0,

        pub fn next(self: *PomDependencies) ?spec.Asset {
            defer self.iter += 1;
            if (self.deps.len <= self.iter) return null;
            var dep = self.deps[self.iter];

            std.log.debug("returning {d} of {d}", .{ self.iter, self.deps.len });

            if (std.mem.indexOfScalar(u8, dep.version, '$')) |match| bail: {
                const propertyEnd = std.mem.indexOfScalar(u8, dep.version, '}').?;

                const propertyStart = match + 2;
                const propertyName = dep.version[propertyStart..propertyEnd];

                const value = self.properties.get(propertyName) orelse v: {
                    if (self.parent) |parentKey| {
                        // TODO: recursively check for parent's property
                        const parent = self.hive.getPom(parentKey) catch {
                            break :bail;
                        };
                        std.log.debug("Using parent's {s} property value", .{propertyName});
                        break :v parent.properties.get(propertyName).?;
                    }
                    break :bail;
                };

                dep.version = value;
            }

            return dep;
        }
    };

    fn getPom(self: *PomHive, key: spec.PomKey) !*spec.Pom {
        const allocator = self.arena.allocator();
        const result = try self.cache.getOrPut(key);

        // TODO: Lazy-load pom files from local cache
        if (!result.found_existing) {
            const identifier = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ key.group, key.artifact, key.version });
            defer allocator.free(identifier);
            std.log.debug("Key {s} doesn't exist. Requesting", .{identifier});
            const xml = try self.http.download(allocator, key);

            var view: parser.PomView = .{ .identifier = identifier, .lines = xml };
            const pom = try view.parse(allocator);
            result.value_ptr.* = pom;
        } else {
            std.log.debug("Key {s}:{s} exists", .{ key.group, key.artifact });
        }

        return result.value_ptr;
    }

    pub fn dependenciesForAsset(self: *PomHive, asset: *const spec.Asset) !PomDependencies {
        const key: spec.PomKey = .{ .artifact = asset.artifact, .group = asset.group, .version = asset.version };
        std.log.debug("Looking up key {s}:{s}", .{ key.group, key.artifact });
        const pom = self.getPom(key) catch |err| {
            std.log.warn("Failed to get pom for key {s}:{s}:{s}. {any}", .{ key.group, key.artifact, key.version, err });
            return err;
        };

        // TODO: Identify when POM is a BOM (Bill of Materials) and return the suggested `dependencyManagement` instead
        // TODO: Better determine if BOM or not

        return .{
            .hive = self,
            .deps = if (pom.dependencies.items.len == 0) pom.dependencyManagement.items else pom.dependencies.items,
            .properties = pom.properties,
            .parent = pom.parent,
        };
    }
};

test {
    const t = std.testing;
    var hive: PomHive = .{
        .arena = std.heap.ArenaAllocator.init(t.allocator),
        .cache = spec.PomCache.initContext(t.allocator, .{}),
        .http = Http.mockedHttp(),
    };
    defer hive.deinit();

    const junit = try hive.getPom(.{
        .group = "junit",
        .artifact = "junit",
        .version = "4.13.2",
    });

    defer junit.deinit(hive.arena.allocator());

    try t.expect(junit.parent == null);
    try t.expectEqual(junit, try hive.getPom(.{
        .group = "junit",
        .artifact = "junit",
        .version = "4.13.2",
    }));
}
