const std = @import("std");
const testing = std.testing;

pub const project = @import("core/project.zig");

test "run all tests" {
    testing.refAllDecls(project);
}
