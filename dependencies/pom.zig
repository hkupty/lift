const std = @import("std");
const xml = @import("xml");
const spec = @import("spec.zig");

const Cursor = enum {
    group,
    artifact,
    version,
    scope,
    optional,
};

const Buffer = std.io.FixedBufferStream([]u8);
const Document = xml.StreamingDocument(Buffer.Reader);
const Reader = xml.GenericReader(Document.Error);

pub const AssetsIterator = struct {
    document: Document,
    reader: Reader,

    const Self = @This();

    pub fn init(doc: Document, innerReader: Reader) Self {
        return .{
            .document = doc,
            .reader = innerReader,
        };
    }

    pub fn deinit(self: *const Self) void {
        self.document.deinit();
        self.reader.deinit();
    }

    pub fn next(self: *Self, allocator: std.mem.Allocator) ?spec.Asset {
        var asset: spec.Asset = undefined;
        asset.scope = .compile;
        asset.optional = false;
        asset.allocator = allocator;
        var inDependency = false;
        var cursor: ?Cursor = null;
        while (true) {
            const node = self.reader.read() catch |err| {
                std.log.warn("Malformed XML: {any}", .{err});
                return null;
            };

            switch (node) {
                .eof => return null,
                .element_start => {
                    const name = self.reader.elementName();
                    if (std.mem.eql(u8, "dependency", name)) {
                        inDependency = true;
                    } else if (inDependency) {
                        if (std.mem.eql(u8, "groupId", name)) {
                            cursor = .group;
                        } else if (std.mem.eql(u8, "artifactId", name)) {
                            cursor = .artifact;
                        } else if (std.mem.eql(u8, "version", name)) {
                            cursor = .version;
                        } else if (std.mem.eql(u8, "scope", name)) {
                            cursor = .scope;
                        } else if (std.mem.eql(u8, "optional", name)) {
                            cursor = .optional;
                        }
                    }
                },
                .text => {
                    if (cursor) |curs| {
                        const baseText = self.reader.text() catch |err| {
                            std.log.warn("Error reading text: {any}", .{err});
                            return null;
                        };

                        const text = allocator.dupe(u8, baseText) catch |err| {
                            std.log.warn("Error reading text: {any}", .{err});
                            return null;
                        };

                        switch (curs) {
                            .group => asset.group = text,
                            .artifact => asset.artifact = text,
                            .version => asset.version = text,
                            .scope => {
                                var scope: spec.Scope = undefined;

                                if (std.mem.eql(u8, "compile", text)) {
                                    scope = .compile;
                                } else if (std.mem.eql(u8, "provided", text)) {
                                    scope = .provided;
                                } else if (std.mem.eql(u8, "runtime", text)) {
                                    scope = .runtime;
                                } else if (std.mem.eql(u8, "test", text)) {
                                    scope = .test_scope;
                                } else if (std.mem.eql(u8, "system", text)) {
                                    scope = .system;
                                } else if (std.mem.eql(u8, "import", text)) {
                                    scope = .import;
                                } else {
                                    std.log.warn("Got unknown scope {s}", .{text});
                                }
                                asset.scope = scope;
                            },
                            .optional => asset.optional = std.mem.eql(u8, "true", text),
                        }
                    }
                },
                .element_end => {
                    const name = self.reader.elementName();
                    if (std.mem.eql(u8, "dependency", name)) {
                        inDependency = false;
                        return asset;
                    } else if (inDependency) {
                        if (std.mem.eql(u8, "groupId", name) or
                            std.mem.eql(u8, "artifactId", name) or
                            std.mem.eql(u8, "version", name) or
                            std.mem.eql(u8, "scope", name) or
                            std.mem.eql(u8, "optional", name))
                        {
                            cursor = null;
                        }
                    }
                },
                else => {},
            }
        }
    }
};

pub fn parseDeps(allocator: std.mem.Allocator, reader: Buffer.Reader) !AssetsIterator {
    var doc = xml.streamingDocument(allocator, reader);
    const dreader = doc.reader(allocator, .{});

    const iter = AssetsIterator.init(doc, dreader);

    return iter;
}
