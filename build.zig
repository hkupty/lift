const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const tomlz = b.dependency("tomlz", .{
        .target = target,
        .optimize = optimize,
    });

    const shared = b.createModule(.{
        .root_source_file = b.path("shared/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib_mod.addImport("lift_shared", shared);
    lib_mod.addImport("tomlz", tomlz.module("tomlz"));

    // We will also create a module for our other entry point, 'main.zig'.
    const lift = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("lift/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    lift.addImport("lift_lib", lib_mod);

    // The binary that lists all the files within given directories
    const sources = b.createModule(.{
        .root_source_file = b.path("sources/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    sources.addImport("lift_shared", shared);

    // The binary that lists compiles java projects
    const compile = b.createModule(.{
        .root_source_file = b.path("compile/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    compile.addImport("lift_shared", shared);

    const dependencies = b.createModule(.{
        .root_source_file = b.path("dependencies/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    dependencies.addImport("lift_shared", shared);

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "lift",
        .root_module = lib_mod,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const lift_exe = b.addExecutable(.{
        .name = "lift",
        .root_module = lift,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(lift_exe);

    const sources_exe = b.addExecutable(.{
        .name = "sources",
        .root_module = sources,
    });

    b.installArtifact(sources_exe);

    const sources_step = b.step("sources", "Build `sources` binary");
    const install_sources = b.addInstallArtifact(sources_exe, .{});
    sources_step.dependOn(&install_sources.step);

    const compile_exe = b.addExecutable(.{
        .name = "compile",
        .root_module = compile,
    });

    b.installArtifact(compile_exe);

    const compile_step = b.step("compile", "Build `compile` binary");
    const install_compile = b.addInstallArtifact(compile_exe, .{});
    compile_step.dependOn(&install_compile.step);

    const dependencies_exe = b.addExecutable(.{
        .name = "dependencies",
        .root_module = dependencies,
    });

    b.installArtifact(dependencies_exe);

    const dependencies_step = b.step("dependencies", "Build `dependencies` binary");
    const install_dependencies = b.addInstallArtifact(dependencies_exe, .{});
    dependencies_step.dependOn(&install_dependencies.step);

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
