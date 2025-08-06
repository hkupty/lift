const std = @import("std");
const Thread = std.Thread;

pub const Dependency = struct {
    group: []u8,
    artifact: []u8,
    version: []u8,
    format: []u8,

    pub fn jar(allocator: std.mem.Allocator, group: []u8, artifact: []u8, version: []u8) !Dependency {
        const format = try allocator.dupe(u8, "jar");
        return .{
            .group = group,
            .artifact = artifact,
            .version = version,
            .format = format,
        };
    }

    pub fn string(self: *const Dependency) ![]u8 {
        var buf: [512]u8 = undefined;
        return std.fmt.bufPrint(&buf, "{s}:{s}:{s}", .{ self.group, self.artifact, self.version });
    }
};

pub const WorkItem = union(enum) {
    dependency: Dependency,
    close: void,

    pub fn StopQueue() WorkItem {
        return WorkItem.close;
    }

    pub fn Dep(dep: Dependency) WorkItem {
        return .{ .dependency = dep };
    }
};

const QueueError = error{
    BufferFull,
};

const WorkQueue = struct {
    buffer: [32]*const WorkItem = undefined,
    readIx: u5 = 0,
    writeIx: u5 = 0,

    pub fn next(self: *WorkQueue) ?*const WorkItem {
        const read = @atomicLoad(u5, &self.readIx, .monotonic);
        const write = @atomicLoad(u5, &self.writeIx, .monotonic);
        if (read == write) {
            return null;
        }

        const wi = self.buffer[self.readIx];
        const nextRead = @addWithOverflow(self.readIx, 1)[0];
        @atomicStore(u5, &self.readIx, nextRead, .monotonic);

        return wi;
    }

    pub fn insert(self: *WorkQueue, item: *const WorkItem) !void {
        const read = @atomicLoad(u5, &self.readIx, .monotonic);
        const write = @atomicLoad(u5, &self.writeIx, .monotonic);
        const nextWrite = @addWithOverflow(write, 1)[0];
        if (nextWrite == read) return QueueError.BufferFull;
        self.buffer[write] = item;
        @atomicStore(u5, &self.writeIx, nextWrite, .monotonic);
    }

    pub fn new() WorkQueue {
        return .{};
    }
};

pub const Worker = struct {
    queue: *WorkQueue,
    thread: Thread,

    // HACK: Ideally, we don't return any errors here, we handle everything gracefully.
    pub fn work(self: *Worker) void {
        var running = true;
        while (running) {
            inner: while (self.queue.next()) |item| {
                switch (item.*) {
                    .close => {
                        running = false;
                        break :inner;
                    },
                    .dependency => |dep| {
                        const strDep = dep.string() catch |err| {
                            std.log.err("Unable to resolve dependency: {any}", .{err});
                            continue;
                        };
                        std.log.info("Resolving {s}\n", .{strDep});
                    },
                }
            }
            // Park the thread until new items show up in the queue
            std.Thread.yield() catch |err| {
                std.log.err("Failed to yield: {any}", .{err});
            };
        }
    }

    pub fn enqueue(self: *Worker, item: *const WorkItem) !void {
        try self.queue.insert(item);
        // Resume the thread if parked, ignore if already running
        // ????
    }

    pub fn init(allocator: std.mem.Allocator) !*Worker {
        const queue = try allocator.create(WorkQueue);
        var worker = try allocator.create(Worker);

        worker.queue = queue;
        worker.thread = try std.Thread.spawn(.{ .allocator = allocator }, Worker.work, .{worker});
        return worker;
    }
};
