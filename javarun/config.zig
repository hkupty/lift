const std = @import("std");
const shared = @import("lift_shared");

pub const CompileConfiguration = struct {
    args: [][]u8 = &[_][]u8{},
    mainClass: []u8,
};

pub const BuildStepConfig = shared.BuildStepConfig(CompileConfiguration);
