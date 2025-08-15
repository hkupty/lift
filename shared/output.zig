const std = @import("std");
const BuildStepConfig = @import("models.zig").BuildStepConfig;
const fs = std.fs;
const json = std.json;

const JsonWriter = json.WriteStream(fs.File.Writer, .{ .checked_to_fixed_depth = 256 });

const max_warnings_limit = 32;

const OutputErrors = error{
    MaxWarningsReached,
};

/// Utility to enable sharing data to the parent process (lift/liftd)
/// through the use of markers (i.e. `warn`).
/// Since warnings can come anywhere in the process, it makes sense to
/// accumulate them before outputting them and, therefore,
/// the function `closeJson` needs to be called so they can be flushed.
pub const Output = struct {
    file: fs.File,
    writer: JsonWriter,

    /// Warnings are stored in the stack and are limited to avoid the need of
    /// memory allocation. They're not to be confused with compiler warnings,
    /// for example. They're events in the build process that can help the
    /// developer to understand why a failure further down in the build tree
    /// happened when some non-fatal error happened before.
    ///
    /// For example, an optional dependency that failed to download,
    /// a dependency conflict resolution, a symlinked file that wasn't
    /// included in the sources, etc.
    warnings: [max_warnings_limit][]u8 = undefined,
    w_ix: u8 = 0,

    pub fn deinit(self: *Output) void {
        self.file.close();
    }

    pub fn addWarning(self: *Output, warning: []u8) !void {
        if (self.w_ix >= max_warnings_limit) return OutputErrors.MaxWarningsReached;
        self.warnings[self.w_ix] = warning;
        self.w_ix += 1;
    }

    pub fn closeJson(self: *Output) !void {
        if (self.w_ix > 0) {
            try self.writer.objectField("warn");
            try self.writer.beginArray();
            for (0..self.w_ix) |ix| {
                try self.writer.write(self.warnings[ix]);
            }
            try self.writer.endArray();
        }
        try self.writer.endObject();
    }
};

pub fn getOutputFile(T: type, stepConfig: BuildStepConfig(T)) !Output {
    var file = try std.fs.openFileAbsolute(stepConfig.outputPath, .{});
    const writer = json.writeStreamMaxDepth(file.writer(), .{ .whitespace = .minified }, 256);

    return .{
        .file = file,
        .writer = writer,
    };
}
