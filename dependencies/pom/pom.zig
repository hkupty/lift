const std = @import("std");
const xml = @import("xml");
const spec = @import("spec.zig");

const eql = std.mem.eql;

// TODO: Solve versions when they're given as parameters
// TODO: Solve versions when they're bundled
// NOTE: Maybe we need a two-step processing: XML -> POM -> []spec.Asset
// NOTE: POMs might need to be resolved recursively (as a file might refer a parent file)

const Cursor = enum {
    group,
    artifact,
    version,
    scope,
    optional,
};

const encoding = "encoding=\"";

fn recoverEncoding(allocator: std.mem.Allocator, slice: []const u8) ![]const u8 {
    const index = std.mem.indexOf(
        u8,
        slice,
        encoding,
    ).?;
    var out = try std.ArrayList(u8).initCapacity(allocator, slice.len * 2);
    for (slice) |b| {
        if (b < 0x80) {
            // ASCII maps 1:1
            try out.append(b);
        } else {
            // Encode as two-byte UTF-8 sequence
            const hi: u8 = 0b1100_0000 | (b >> 6); // top 2 bits
            const lo: u8 = 0b1000_0000 | (b & 0b0011_1111);
            try out.append(hi);
            try out.append(lo);
        }
    }

    out.replaceRangeAssumeCapacity(index + encoding.len, 10, "UTF-8");
    return out.toOwnedSlice();
}

const Buffer = std.io.FixedBufferStream([]const u8);
const Document = xml.StreamingDocument(Buffer.Reader);
const Reader = xml.GenericReader(Document.Error);

pub const PomView = struct {
    lines: []const u8,
    identifier: []const u8 = undefined,
    arena: std.heap.ArenaAllocator,
    recovery: bool = false,

    pub fn parse(self: *PomView) !spec.Pom {
        const allocator = self.arena.allocator();
        var buffered = std.io.fixedBufferStream(self.lines);
        var doc = xml.streamingDocument(allocator, buffered.reader());
        defer doc.deinit();
        var dreader = doc.reader(allocator, .{});
        defer dreader.deinit();

        var parser = PomParser.init(allocator, doc, dreader);
        parser.identifier = self.identifier;

        return parser.parse() catch |err| {
            if (err == PomParser.Errors.UnsupportedEncoding) {
                self.lines = try recoverEncoding(allocator, self.lines);
                self.recovery = true;
                return self.parse();
            } else {
                return err;
            }
        };
    }
};

pub const PomParser = struct {
    document: Document,
    reader: Reader,
    identifier: []const u8 = undefined,
    allocator: std.mem.Allocator,

    pub const Errors = error{
        OverReading,
        MalformedData,
        UnsupportedEncoding,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, doc: Document, innerReader: Reader) Self {
        return .{
            .document = doc,
            .reader = innerReader,
            .allocator = allocator,
        };
    }

    pub fn readUntil(self: *Self, comptime token: xml.Reader.Node) !xml.Reader.Node {
        var node = self.reader.reader.node orelse try self.reader.read();
        while (true) {
            if (node == .eof) {
                return error.OverReading;
            } else if (node == token) {
                return node;
            } else {
                node = try self.reader.read();
            }
        }
    }

    pub fn readUntilTarget(self: *Self, comptime token: xml.Reader.Node, name: []const u8) !xml.Reader.Node {
        std.debug.assert(token == .element_start or token == .element_end);
        var node = self.reader.reader.node orelse try self.reader.read();
        while (true) {
            if (node == .eof) {
                return error.OverReading;
            } else if (node == token and std.mem.eql(u8, name, self.reader.elementName())) {
                return node;
            } else {
                node = try self.reader.read();
            }
        }
    }

    fn parseProperties(self: *Self, map: *spec.PropertiesMap) !void {
        while (true) {
            const node = try self.reader.read();
            switch (node) {
                .element_start => {
                    const propertyName = try self.allocator.dupe(u8, self.reader.elementName());
                    const ownedPropertyName = try self.allocator.dupe(u8, propertyName);
                    std.log.debug("[{s}] Reading property at: {s}", .{ self.identifier, propertyName });
                    const next = try self.reader.read();
                    std.debug.assert(next == .text or next == .element_end);
                    if (next == .element_end) continue;
                    const text = try self.reader.text();
                    const ownedText = try self.allocator.dupe(u8, text);
                    std.debug.assert(try self.reader.read() == .element_end);
                    try map.put(ownedPropertyName, ownedText);
                },
                .element_end => {
                    std.debug.assert(std.mem.eql(u8, "properties", self.reader.elementName()));
                    return;
                },
                .eof => return error.OverReading,
                else => {},
            }
        }
    }

    fn parseParent(self: *Self) !spec.PomKey {
        var parent: spec.PomKey = undefined;
        while (true) {
            const node = try self.reader.read();
            switch (node) {
                .element_start => {
                    const elementName = try self.allocator.dupe(u8, self.reader.elementName());
                    const next = try self.reader.read();
                    std.debug.assert(next == .text or next == .element_end);
                    if (next == .element_end) continue;
                    const ownedText = try self.allocator.dupe(u8, try self.reader.text());
                    std.debug.assert(try self.reader.read() == .element_end);
                    std.log.debug("[{s}] Set parent to {s} property to {s}", .{ self.identifier, elementName, ownedText });

                    if (std.mem.eql(u8, "groupId", elementName)) {
                        parent.group = ownedText;
                    } else if (std.mem.eql(u8, "artifactId", elementName)) {
                        parent.artifactId = ownedText;
                    } else if (std.mem.eql(u8, "version", elementName)) {
                        parent.version = ownedText;
                    }
                },
                .element_end => {
                    std.log.debug("[{s}] Set parent to {s}:{s}:{s}", .{ self.identifier, parent.group, parent.artifactId, parent.version });
                    std.debug.assert(std.mem.eql(u8, "parent", self.reader.elementName()));
                    return parent;
                },
                .eof => return error.OverReading,
                else => {},
            }
        }
    }

    fn parseDependency(self: *Self) !spec.Asset {
        var asset: spec.Asset = .{
            .scope = .compile,
            .optional = false,
            .allocator = self.allocator,
            .group = undefined,
            .artifact = undefined,
            .version = "",
        };
        // Land at `dependency`
        _ = try self.readUntilTarget(.element_start, "dependency");

        while (true) {
            const node = try self.reader.read();
            switch (node) {
                .element_start => {
                    std.log.debug("[{s}] Reading at level {d}", .{ self.identifier, self.reader.reader.element_names.items.len });
                    const elementName = try self.allocator.dupe(u8, self.reader.elementName());
                    std.log.debug("[{s}] Reading at: {s}", .{ self.identifier, elementName });
                    std.debug.assert(try self.reader.read() == .text);
                    const ownedText = try self.allocator.dupe(u8, try self.reader.text());
                    if (std.mem.eql(u8, "groupId", elementName)) {
                        asset.group = ownedText;
                    } else if (std.mem.eql(u8, "artifactId", elementName)) {
                        asset.artifact = ownedText;
                    } else if (std.mem.eql(u8, "version", elementName)) {
                        asset.version = ownedText;
                    } else if (std.mem.eql(u8, "scope", elementName)) {
                        if (std.mem.eql(u8, "compile", ownedText)) {
                            asset.scope = .compile;
                        } else if (std.mem.eql(u8, "provided", ownedText)) {
                            asset.scope = .provided;
                        } else if (std.mem.eql(u8, "runtime", ownedText)) {
                            asset.scope = .runtime;
                        } else if (std.mem.eql(u8, "test", ownedText)) {
                            asset.scope = .test_scope;
                        } else if (std.mem.eql(u8, "system", ownedText)) {
                            asset.scope = .system;
                        } else if (std.mem.eql(u8, "import", ownedText)) {
                            asset.scope = .import;
                        } else {
                            std.log.warn("[{s}] Got unknown scope {s}", .{ self.identifier, ownedText });
                        }
                    } else if (std.mem.eql(u8, "optional", elementName)) {
                        asset.optional = std.mem.eql(u8, "true", ownedText);
                    } else {
                        try self.reader.skipElement();
                        // Skip ends at </..>, we move past that
                        continue;
                    }

                    std.debug.assert(try self.reader.read() == .element_end);
                },
                .element_end => {
                    std.debug.assert(std.mem.eql(u8, "dependency", self.reader.elementName()));
                    return asset;
                },
                .eof => return error.OverReading,
                else => {},
            }
        }
    }

    fn parseBreaking(self: *Self, pom: *spec.Pom) !void {
        _ = try self.readUntilTarget(.element_start, "project");
        _ = try self.reader.read(); // Move past <project ..>

        while (true) {
            _ = try self.readUntil(.element_start);
            const name = self.reader.elementName();
            if (std.mem.eql(u8, name, "dependencies")) {
                while (true) {
                    if (self.reader.reader.node.? == .element_end and eql(u8, "dependencies", self.reader.elementName())) break;

                    // Reads up until cursor is at </dependency>, so we need to move one
                    const dep = try self.parseDependency();
                    try pom.dependencies.append(dep);
                    _ = try self.reader.read(); // the text inside the element perhaps
                    _ = try self.reader.read();
                }
            } else if (std.mem.eql(u8, name, "dependencyManagement")) {
                // Skip any comments or arguments and go from <dependencyManagement> to <dependency>
                _ = try self.readUntil(.element_start);
                while (true) {
                    if (self.reader.reader.node.? == .element_end and eql(u8, "dependencies", self.reader.elementName())) break;

                    // Reads up until cursor is at </dependency>, so we need to move one
                    const dep = try self.parseDependency();
                    try pom.dependencyManagement.append(dep);
                    _ = try self.reader.read(); // the text inside the element perhaps
                    _ = try self.reader.read();
                }
                _ = try self.readUntil(.element_end);
            } else if (std.mem.eql(u8, "properties", name)) {
                try self.parseProperties(&pom.properties);
            } else if (std.mem.eql(u8, "parent", name)) {
                const key = try self.parseParent();
                pom.parent = key;
            } else {
                try self.reader.skipElement();
            }
            const node = try self.reader.read();
            if (node == .eof) return;
        }
    }

    pub fn parse(self: *Self) !spec.Pom {
        var pom: spec.Pom = .{
            .dependencies = spec.Dependencies.init(self.allocator),
            .dependencyManagement = spec.Dependencies.init(self.allocator),
            .properties = spec.PropertiesMap.init(self.allocator),
        };

        self.parseBreaking(&pom) catch |err| {
            if (err == error.OverReading) {
                return pom;
            } else if (err == error.MalformedXml and self.reader.reader.error_code == .xml_declaration_encoding_unsupported) {
                return error.UnsupportedEncoding;
            }
            return err;
        };

        return pom;
    }
};

const Expect = struct {
    descr: []const u8,
    parent: ?struct {
        group: []const u8,
        artifactId: []const u8,
        version: []const u8,
    },
    dependencies: usize,
    properties: usize,
    dependencyManagement: usize,
};

fn loadExpect(allocator: std.mem.Allocator, path: []const u8) !Expect {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const contents = try file.readToEndAllocOptions(allocator, std.math.maxInt(usize), null, 2, 0);
    defer allocator.free(contents);

    return try std.zon.parse.fromSlice(Expect, allocator, contents, null, .{});
}

test {
    // List the .pom and .zon files
    // Open and parse the .pom files
    // Assert that the file is parsed without errors
    // Check their result against the equivalent .zon file
    //
    const config = @import("config");
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var test_data_dir = try std.fs.openDirAbsolute(config.TEST_DATA_PATH, .{ .iterate = true });
    defer test_data_dir.close();

    var iterator = test_data_dir.iterate();

    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".pom")) {
            const alloc = arena.allocator();
            defer _ = arena.reset(.retain_capacity);
            var pathBuffer = try std.ArrayList(u8).initCapacity(alloc, config.TEST_DATA_PATH.len + entry.name.len + std.fs.path.sep_str.len);
            pathBuffer.appendSliceAssumeCapacity(config.TEST_DATA_PATH);
            pathBuffer.appendSliceAssumeCapacity(std.fs.path.sep_str);
            pathBuffer.appendSliceAssumeCapacity(entry.name);
            const path = try pathBuffer.toOwnedSlice();
            var zon = try allocator.alloc(u8, path.len);
            defer allocator.free(zon);
            @memcpy(zon, path);
            @memcpy(zon[path.len - 3 ..], "zon");
            const target = std.fs.path.basename(std.fs.path.stem(path));

            const expect = try loadExpect(alloc, zon);
            errdefer std.debug.print("{s} - {s}\n", .{ target, expect.descr });
            const data = try std.fs.openFileAbsolute(path, .{});
            const lines = try data.readToEndAlloc(alloc, 1 << 16);

            var view = PomView{
                .identifier = target,
                .arena = arena,
                .lines = lines,
            };

            var pom = try view.parse();
            defer pom.deinit();
            if (expect.parent) |ref| {
                try std.testing.expect(pom.parent != null);
                const pom_parent = pom.parent.?;
                try std.testing.expectEqualStrings(ref.group, pom_parent.group);
                try std.testing.expectEqualStrings(ref.artifactId, pom_parent.artifactId);
                try std.testing.expectEqualStrings(ref.version, pom_parent.version);
            } else {
                try std.testing.expect(pom.parent == null);
            }

            try std.testing.expectEqual(expect.dependencies, pom.dependencies.items.len);
            try std.testing.expectEqual(expect.dependencyManagement, pom.dependencyManagement.items.len);
            try std.testing.expectEqual(expect.properties, pom.properties.count());
        }
    }
}
