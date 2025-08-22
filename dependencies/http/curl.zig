const std = @import("std");
const curl = @import("curl");

// TODO: Replace libcurl with default http/tls once either zig supports TLS 1.2 better or TLS 1.2 is deprecated
// HACK: Alternatively, use tls.zig and write a custom HTTP client layer on top of it

pub const DependencyError = error{
    DependencyNotFound,
    DependencyRequestError,
    RetriableFailure,
};

const LibcurlHttpImpl = @This();

cert: std.ArrayList(u8),
api: curl.Easy,

pub fn init(allocator: std.mem.Allocator) !LibcurlHttpImpl {
    const ca = try curl.allocCABundle(allocator);
    const easy = try curl.Easy.init(.{ .ca_bundle = ca, .default_user_agent = "lift/0.0" });

    return .{
        .cert = ca,
        .api = easy,
    };
}

pub fn download(self: *const LibcurlHttpImpl, allocator: std.mem.Allocator, url: [:0]u8) ![]const u8 {
    var writer = curl.ResizableResponseWriter.init(allocator);
    defer writer.deinit();

    self.api.reset();
    try self.api.setUrl(url);
    try self.api.setAnyWriter(&writer.asAny());

    const response = try self.api.perform();

    switch (response.status_code) {
        200...299 => {},
        408, 429, 500, 502, 503, 504 => {
            std.log.warn("Failed to download. Should retry", .{});
            return DependencyError.RetriableFailure;
        },

        404 => {
            std.log.warn("Dependency {s} not found.", .{url});
            return DependencyError.DependencyNotFound;
        },

        else => {
            std.log.warn("Failed to download dependency {s}. Status code: {d}", .{ url, response.status_code });
            return DependencyError.DependencyRequestError;
        },
    }

    return writer.asSlice();
}

pub fn deinit(self: *const LibcurlHttpImpl) void {
    self.api.deinit();
    self.cert.deinit();
}
