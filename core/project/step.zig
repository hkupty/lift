const std = @import("std");
const models = @import("models.zig");

name: models.StepName,
bitPosition: models.StepBitPosition,
dependsOn: []models.StepName,
runner: []const u8,
data: []u8,

const Step = @This();
