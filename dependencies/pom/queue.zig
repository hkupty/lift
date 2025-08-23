const std = @import("std");
const spec = @import("spec.zig");
const memory = @import("memory.zig");

/// The ArrayHashMapUnmanaged enables a O(1) lookup to verify if
/// the requested POM is enqued already while still enabling sequential
/// storage.
const QueueBuffer = std.ArrayHashMapUnmanaged(spec.PomKey, ?*spec.Pom, spec.PomKey.IgnoreVersionArrayHashMapContext, false);

/// The Pom Resolution Queue is a temporary buffer.
/// PomKey entries are added with an initial null value. Once the POM file is resolved
/// (loaded from local cache or downloaded) the entrie is updated.
/// As a Pom object is updated, its dependencies are added to the Queue if they're not
/// already present.
/// For the sake for version conflict resolution, version, although present in the
/// PomKey object, is not considered for equality or hashing purposes.
pub const PomResolutionQueue = struct {
    queue: QueueBuffer = .empty,

    /// Intermediary structure to that points to PomResolutionQueue's queue
    /// in a stateful way, enabling the iterator pattern while providing the
    /// necessary feature of filtering pom files which are not directly relevant,
    /// i.e. POM files for BOMs.
    const JarUrlIterator = struct {
        queue: *const QueueBuffer,
        index: usize = 0,
    };

    /// When two dependencies, of the same group and same artifact id, but of different versions
    /// are enqueued, the provided strategy will dictate how to proceed.
    const ConflictResolutionStrategy = enum {
        /// The value previously inserted in the queue will be respected;
        first_write_wins,

        /// The value that attempted to replace the existing value will be used;
        last_write_wins,

        /// The value with the highest major, minor or patch (or even more granular) version will be used;
        highest_major_wins,

        /// The value with the highest minor or patch (or even more granular) version will be used;
        /// If the values differ by major then an error is issued.
        highest_minor_wins,

        /// The value with the highest patch (or even more granular) version will be used;
        /// If the values differ by major or minor then an error is issued.
        highest_patch_wins,

        /// If the values differ then an error is issued.
        fail_on_conflict,
    };

    const Error = error{
        VersionConflictError,
    };

    /// This function ensures that the underlying buffer
    /// is completely filled and stable, or, in other words, that
    /// each entry has an associated non-null value.
    /// Additionally, if, by adding a value to an entry (resolving the PomKey
    /// to a POM file) new transitive dependencies are identified,
    /// those new dependencies are then added to the queue,
    /// given they're not present yet and they're not conflicting in version
    /// with an existing entry.
    pub fn resolve(self: *@This(), allocator: std.mem.Allocator, hive: *memory.PomHive) !void {
        std.log.debug("We have {d} items in the queue", .{self.queue.entries.len});

        var ix: usize = 0;
        while (true) : (ix += 1) {
            if (ix >= self.queue.entries.len) break;
            const key = self.queue.entries.get(ix).key;
            const entry = self.queue.getEntry(key).?;
            const pom = try hive.getPom(key);

            try hive.resolvePomVersions(pom);

            entry.value_ptr.* = pom;
            const dependencies = switch (pom.packaging) {
                .jar => pom.dependencies.items,
                .pom => pom.dependencyManagement.items,
                else => continue,
            };
            for (dependencies) |item| {
                if (item.optional) {
                    std.log.debug("Skipping optional dependency {s}:{s}:{s}", .{
                        item.group,
                        item.artifact,
                        item.version,
                    });
                    continue;
                }
                switch (item.scope) {
                    .system, .test_scope => {},
                    else => try self.enqueue(allocator, .{
                        .group = item.group,
                        .artifact = item.artifact,
                        .version = item.version,
                    }, .highest_minor_wins),
                }
            }
        }
    }

    ///  Adds a key to the queue for further resolution. The act of enqueueing elements
    ///  does not immediatelly ensure that the pom will be downloaded (as that only happens when resolve
    ///  is called), so by consequence it does not ensure that the jar pointed at by the pom key
    ///  will be downloaded further down.
    pub fn enqueue(self: *@This(), allocator: std.mem.Allocator, key: spec.PomKey, comptime strategy: ConflictResolutionStrategy) !void {
        const item = try self.queue.getOrPutContext(allocator, key, .{});

        if (item.found_existing) {
            if (!std.mem.eql(u8, item.key_ptr.version, key.version)) {
                std.log.debug("Versions for {s}:{s} differ. {s} -> {s}, resolving with {any}", .{ key.group, key.artifact, item.key_ptr.version, key.version, strategy });
                const replace = repl: switch (strategy) {
                    .first_write_wins => false,
                    .last_write_wins => true,
                    .fail_on_conflict => return Error.VersionConflictError,
                    .highest_major_wins, .highest_minor_wins, .highest_patch_wins => {
                        const current = try std.SemanticVersion.parse(item.key_ptr.version);
                        const candidate = try std.SemanticVersion.parse(key.version);
                        switch (strategy) {
                            .highest_major_wins => std.SemanticVersion.order(candidate, current) == std.math.Order.gt,
                            .highest_minor_wins => {
                                if (candidate.major == current.major) {
                                    break :repl std.SemanticVersion.order(candidate, current) == std.math.Order.gt;
                                } else return Error.VersionConflictError;
                            },
                            .highest_patch_wins => {
                                if (candidate.major == current.major and candidate.minor == current.minor) {
                                    break :repl std.SemanticVersion.order(candidate, current) == std.math.Order.gt;
                                } else return Error.VersionConflictError;
                            },
                            else => unreachable,
                        }
                    },
                };

                if (replace) {
                    item.key_ptr.* = key;
                }
            } else {
                std.log.debug("Key {s}:{s} present with same version, skipping ", .{ key.group, key.artifact });
            }
        } else {
            std.log.debug("Adding key {s}:{s} to the queue", .{ key.group, key.artifact });
            item.value_ptr.* = null;
        }
    }

    /// This function returns an iterator that goes over the items
    /// in queue and only returns values that are referent to actual jars,
    /// skipping over any POM objects with packaging value of anythign other than .jar;
    pub fn jarUrls(self: *@This()) !JarUrlIterator {
        return .{ .queue = self.queue };
    }
};
