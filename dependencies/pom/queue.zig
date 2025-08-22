const std = @import("std");
const spec = @import("spec.zig");
const memory = @import("memory.zig");

/// The ArrayHashMapUnmanaged enables a O(1) lookup to verify if
/// the requested POM is enqued already while still enabling sequential
/// storage.
const QueueBuffer = std.ArrayHashMapUnmanaged(spec.PomKey, ?spec.Pom, spec.PomKey.IgnoreVersionArrayHashMapContext, false);

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
    const JarUrlIterator = struct {};

    /// This function ensures that the underlying buffer
    /// is completely filled and stable, or, in other words, that
    /// each entry has an associated non-null value.
    /// Additionally, if, by adding a value to an entry (resolving the PomKey
    /// to a POM file) new transitive dependencies are identified,
    /// those new dependencies are then added to the queue,
    /// given they're not present yet and they're not conflicting in version
    /// with an existing entry.
    pub fn resolve(self: *@This()) !void {}

    /// This function returns an iterator that goes over the items
    /// in queue and only returns values that are referent to actual jars,
    /// skipping over any POM objects with packaging value of anythign other than .jar;
    pub fn jarUrls(self: *@This(), allocator: std.mem.Allocator) !JarUrlIterator {
        return .{};
    }
};
