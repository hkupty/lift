pub fn BuildStepConfig(comptime T: type) type {
    return struct {
        buildPath: []const u8,
        cachePath: []const u8,
        outputPath: []const u8,
        projectName: []const u8,
        stepName: []const u8,
        data: T,
    };
}
