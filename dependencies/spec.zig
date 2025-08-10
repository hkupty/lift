const std = @import("std");

pub const DependencyFormat = union(enum) {
    jar: void,
    other: []u8,
};

pub const Dependency = struct {
    group: []u8,
    artifact: []u8,
    version: []u8,
    format: DependencyFormat,

    pub fn jar(group: []u8, artifact: []u8, version: []u8) !Dependency {
        return .{
            .group = group,
            .artifact = artifact,
            .version = version,
            .format = .jar,
        };
    }

    pub fn string(self: *const Dependency) ![]u8 {
        var buf: [512]u8 = undefined;
        return std.fmt.bufPrint(&buf, "{s}:{s}:{s}", .{ self.group, self.artifact, self.version });
    }

    pub fn filename(self: *const Dependency, allocator: std.mem.Allocator) ![]u8 {
        const extension = switch (self.format) {
            .jar => "jar",
            .other => |fmt| fmt,
        };
        return std.fmt.allocPrint(allocator, "{s}-{s}.{s}", .{ self.artifact, self.version, extension });
    }
};
