pub fn BuildStepConfig(comptime T: type) type {
    return struct {
        buildPath: []u8,
        projectName: []u8,
        stepName: []u8,
        data: T,
    };
}
