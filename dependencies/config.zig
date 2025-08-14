const std = @import("std");
const shared = @import("lift_shared");

// TODO: Enable more complex configuration

// pub const RepoConfiguration = struct {
//     type: []u8,
//     url: []u8,
// };
//
// pub const FullConfiguration = struct {
//     dependencies: [][]u8,
//     repositories: []RepoConfiguration,
// };
//
// pub const DependenciesConfiguration = union(enum) {
//     short: [][]u8,
//     long: FullConfiguration,
//
//     pub fn dependencies(self: *DependenciesConfiguration) [][]u8 {
//         switch (self.*) {
//             .short => |deps| return deps,
//             .long => |full| return full.dependencies,
//         }
//     }
// };

pub const BuildStepConfig = shared.BuildStepConfig([][]u8);
