const std = @import("std");
const xml = @import("xml");
const spec = @import("spec.zig");

const Cursor = enum {
    group,
    artifact,
    version,
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
                        }
                    }
                },
                .element_end => {
                    const name = self.reader.elementName();
                    if (std.mem.eql(u8, "dependency", name)) {
                        inDependency = false;
                        return asset;
                    } else if (inDependency) {
                        if (std.mem.eql(u8, "groupId", name)) {
                            cursor = null;
                        } else if (std.mem.eql(u8, "artifactId", name)) {
                            cursor = null;
                        } else if (std.mem.eql(u8, "version", name)) {
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
