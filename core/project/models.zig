const std = @import("std");
const shared = @import("lift_shared");

pub const BuildStepConfig = shared.BuildStepConfig([]u8);

pub const StepErrors = error{
    /// This error is fired when a step is re-defined.
    StepRedefinition,

    /// This error is fired when a step parameter can't be parsed
    StepParameterIssue,

    /// This error is fired when a target/step is requested but it doesn't exist
    StepNotFound,

    /// Step run unsuccessfully.
    StepExecutionFailed,
};

pub const StepName = []const u8;

pub const StepBitPosition = u64;
