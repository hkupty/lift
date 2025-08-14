const std = @import("std");
const json = std.json;
const io = std.io;
const fs = std.fs;

const tomlz = @import("tomlz");

const shared = @import("lift_shared");
const StepData = shared.StepData;
const BuildStepConfig = shared.BuildStepConfig([]u8);

pub const JsonBufferWriter = std.json.WriteStream(std.ArrayList(u8).Writer, .assumed_correct);

pub fn writeBuildStepConfig(file: fs.File, bsc: BuildStepConfig) !void {
    var stream = json.writeStream(file.writer(), .{ .whitespace = .minified });
    try stream.beginObject();
    try stream.objectField("buildPath");
    try stream.write(bsc.buildPath);
    try stream.objectField("cachePath");
    try stream.write(bsc.cachePath);
    try stream.objectField("outputPath");
    try stream.write(bsc.outputPath);
    try stream.objectField("projectName");
    try stream.write(bsc.projectName);
    try stream.objectField("stepName");
    try stream.write(bsc.stepName);
    if (bsc.data.len > 0) {
        try stream.objectField("data");
        try stream.beginWriteRaw();
        try stream.stream.writeAll(bsc.data);
        stream.endWriteRaw();
    }
    try stream.endObject();
}

pub fn tomlToJson(writer: *JsonBufferWriter, value: tomlz.Value) !void {
    switch (value) {
        .array => |arr| {
            try writer.beginArray();
            for (arr.items()) |item| {
                try tomlToJson(writer, item);
            }
            try writer.endArray();
        },
        .table => |tbl| {
            try writer.beginObject();
            var keysIter = tbl.table.keyIterator();
            while (keysIter.next()) |key| {
                const keyValue = tbl.table.get(key.*) orelse continue;
                try writer.objectField(key.*);
                try tomlToJson(writer, keyValue);
            }
            try writer.endObject();
        },
        .boolean => |data| try writer.write(data),
        .float => |data| try writer.write(data),
        .integer => |data| try writer.write(data),
        .string => |data| try writer.write(data),
    }
}
