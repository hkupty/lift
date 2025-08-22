const std = @import("std");
const curl = @import("curl.zig");
const fakeImpl = @import("fake.zig");
const spec = @import("../pom/spec.zig");
const maven = @import("../spec.zig").defaultMaven;

pub const Http = union(enum) {
    http: curl,
    fake: fakeImpl,

    pub fn init(allocator: std.mem.Allocator) !Http {
        return .{ .http = try curl.init(allocator) };
    }

    pub fn mockedHttp() Http {
        return .{ .fake = fakeImpl{} };
    }

    pub fn deinit(self: *const Http) void {
        switch (self.*) {
            .http => |h| h.deinit(),
            .fake => {},
        }
    }

    pub fn download(self: *Http, allocator: std.mem.Allocator, key: spec.PomKey) ![]const u8 {
        switch (self.*) {
            .http => |h| {
                const url = try key.fullRemotePathZ(allocator, maven.maven);
                return h.download(allocator, url);
            },
            .fake => |f| return f.download(allocator, key),
        }
    }
};
