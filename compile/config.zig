const std = @import("std");
const shared = @import("lift_shared");

pub const CompileConfiguration = struct {
    targetVersion: u16 = 0,
    sourceVersion: u16 = 0,
    args: [][]u8 = &[_][]u8{},
};

pub const BuildStepConfig = shared.BuildStepConfig(CompileConfiguration);
