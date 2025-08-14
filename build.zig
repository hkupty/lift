const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -- [ External dependencies ]--
    const tomlz = b.dependency("tomlz", .{
        .target = target,
        .optimize = optimize,
    });

    const curl = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
    });

    const known_folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    });

    const xml = b.dependency("xml", .{
        .target = target,
        .optimize = optimize,
    });

    // --[ Shared ]--
    const shared = b.createModule(.{
        .root_source_file = b.path("shared/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --[ Sources ]--
    const sources = b.createModule(.{
        .root_source_file = b.path("sources/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    sources.addImport("lift_shared", shared);
    const sources_exe = b.addExecutable(.{
        .name = "sources",
        .root_module = sources,
    });

    b.installArtifact(sources_exe);

    const sources_step = b.step("sources", "Build `sources` binary");
    const install_sources = b.addInstallArtifact(sources_exe, .{});
    sources_step.dependOn(&install_sources.step);

    // --[ Compile ]--
    const compile = b.createModule(.{
        .root_source_file = b.path("compile/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    compile.addImport("lift_shared", shared);
    const compile_exe = b.addExecutable(.{
        .name = "compile",
        .root_module = compile,
    });

    b.installArtifact(compile_exe);

    const compile_step = b.step("compile", "Build `compile` binary");
    const install_compile = b.addInstallArtifact(compile_exe, .{});
    compile_step.dependOn(&install_compile.step);

    // --[ Run ]--
    const javarun = b.createModule(.{
        .root_source_file = b.path("javarun/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    javarun.addImport("lift_shared", shared);
    const javarun_exe = b.addExecutable(.{
        .name = "javarun",
        .root_module = javarun,
    });

    b.installArtifact(javarun_exe);

    const javarun_step = b.step("javarun", "Build `javarun` binary");
    const install_javarun = b.addInstallArtifact(javarun_exe, .{});
    javarun_step.dependOn(&install_javarun.step);

    // --[ Dependencies ]--
    const dependencies = b.createModule(.{
        .root_source_file = b.path("dependencies/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    dependencies.addImport("lift_shared", shared);
    dependencies.addImport("curl", curl.module("curl"));
    dependencies.addImport("xml", xml.module("xml"));

    const dependencies_exe = b.addExecutable(.{
        .name = "dependencies",
        .root_module = dependencies,
    });

    dependencies_exe.linkLibC();

    b.installArtifact(dependencies_exe);

    const dependencies_step = b.step("dependencies", "Build `dependencies` binary");
    const install_dependencies = b.addInstallArtifact(dependencies_exe, .{});
    dependencies_step.dependOn(&install_dependencies.step);

    // --[ Lift, Liftd & Core ]--
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib_mod.addImport("lift_shared", shared);
    lib_mod.addImport("tomlz", tomlz.module("tomlz"));
    lib_mod.addImport("known-folders", known_folders.module("known-folders"));

    const lift = b.createModule(.{
        .root_source_file = b.path("lift/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lift.addImport("lift_lib", lib_mod);

    const lift_exe = b.addExecutable(.{
        .name = "lift",
        .root_module = lift,
    });
    b.installArtifact(lift_exe);

    // == UNEDITED ==

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(lift_exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = lift,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
