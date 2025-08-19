const std = @import("std");
const testing = std.testing;

pub const project = @import("project/project.zig");
const utils = @import("utils.zig");

test "run all tests" {
    // testing.refAllDecls(project);
    testing.refAllDecls(utils);
}
