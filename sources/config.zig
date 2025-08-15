const std = @import("std");
const shared = @import("lift_shared");

pub const StepData = [][]u8;

pub const BuildStepConfig = shared.BuildStepConfig(StepData);
