const std = @import("std");
const testing = std.testing;

pub const project = @import("project.zig");

test "run all tests" {
    testing.refAllDecls(project);
}
