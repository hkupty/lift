const std = @import("std");
const Thread = std.Thread;
const Dependency = @import("spec.zig").Dependency;
const jar = @import("jar.zig");

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

const AtomicUsize = std.atomic.Value(usize);

const WorkQueue = struct {
    buffer: [8]*const WorkItem = undefined,
    readIx: AtomicUsize = AtomicUsize.init(0),
    writeIx: AtomicUsize = AtomicUsize.init(0),

    pub fn next(self: *WorkQueue) ?*const WorkItem {
        const read = self.readIx.load(.acquire);
        const write = self.writeIx.load(.acquire);
        if (read == write) {
            return null;
        }

        const wi = self.buffer[read];
        const nextRead = @mod(read + 1, self.buffer.len);
        self.readIx.store(nextRead, .release);
        return wi;
    }

    pub fn insert(self: *WorkQueue, item: *const WorkItem) !void {
        const read = self.readIx.load(.acquire);
        const write = self.writeIx.load(.acquire);
        const nextWrite = @mod(write + 1, self.buffer.len);
        if (nextWrite == read) return QueueError.BufferFull;
        self.buffer[write] = item;
        self.writeIx.store(nextWrite, .release);
    }

    pub fn new() WorkQueue {
        return .{};
    }
};

pub const Worker = struct {
    queue: WorkQueue,
    thread: Thread,
    memBuffer: []u8,
    fba: std.heap.FixedBufferAllocator,
    arena: std.heap.ArenaAllocator,
    active: std.atomic.Value(bool),

    // HACK: Ideally, we don't return any errors here, we handle everything gracefully.
    pub fn work(self: *Worker) void {
        var running = true;
        const allocator = self.arena.allocator();
        outer: while (running) {
            while (self.queue.next()) |item| {
                switch (item.*) {
                    .close => {
                        running = false;
                        std.log.info("Closing the loop", .{});
                        break :outer;
                    },
                    .dependency => |dep| {
                        const strDep = dep.string() catch |err| {
                            std.log.err("Unable to resolve dependency: {any}", .{err});
                            continue;
                        };

                        std.log.info("Resolving {s}", .{strDep});
                        const url = jar.resolveMavenDependencyUrl(allocator, "https://repo1.maven.org/maven2", dep) catch |err| {
                            std.log.err("Failed to resolve url: {any}", .{err});
                            continue;
                        };
                        std.log.info("Resolved URL to {s}", .{url});
                    },
                }
            }

            if (!self.active.load(.acquire)) {
                break :outer;
            }
            // Park the thread until new items show up in the queue
            std.Thread.yield() catch |err| {
                std.log.err("Failed to yield: {any}", .{err});
            };
        }
    }

    pub fn enqueue(self: *Worker, item: *const WorkItem) !void {
        try self.queue.insert(item);
    }

    pub fn init(parentThreadAllocator: std.mem.Allocator) !*Worker {

        // HACK: Measure and fine tune. 2MB should be OK for now

        var worker = try parentThreadAllocator.create(Worker);

        worker.queue = .{};
        worker.memBuffer = try parentThreadAllocator.alloc(u8, 2 * 1024 * 1024);
        worker.fba = std.heap.FixedBufferAllocator.init(worker.memBuffer);
        worker.active = std.atomic.Value(bool).init(true);
        worker.arena = std.heap.ArenaAllocator.init(worker.fba.allocator());
        worker.thread = try std.Thread.spawn(.{ .allocator = worker.arena.allocator() }, Worker.work, .{worker});
        return worker;
    }

    pub fn deinit(self: *Worker, parentThreadAllocator: std.mem.Allocator) void {
        self.active.store(false, .release);
        self.thread.join();
        self.arena.deinit();
        parentThreadAllocator.free(self.memBuffer);
    }
};

pub const WorkerPool = struct {
    allocator: std.mem.Allocator,
    workers: std.ArrayList(*Worker),
    lastInsert: usize,

    pub fn init(allocator: std.mem.Allocator) !*WorkerPool {
        var pool = try allocator.create(WorkerPool);
        errdefer allocator.free(pool);
        pool.allocator = allocator;
        pool.workers = std.ArrayList(*Worker).init(allocator);
        pool.lastInsert = 0;

        return pool;
    }

    pub fn enqueue(self: *WorkerPool, item: *const WorkItem) !void {
        const view = self.workers.items;

        var inserted = false;

        for (0..view.len) |iter| {
            const ix = @rem(iter + self.lastInsert, view.len);
            view[ix].enqueue(item) catch {
                continue;
            };
            self.lastInsert = ix;
            inserted = true;
            break;
        }

        if (!inserted) {
            const next = try Worker.init(self.allocator);
            errdefer next.deinit(self.allocator);
            try self.workers.append(next);
            try next.enqueue(item);
            self.lastInsert = view.len; // same as self.workers.items.len - 1;
        }
    }

    pub fn deinit(self: *WorkerPool) void {
        std.log.info("Deinitializing {d} workers from pool", .{self.workers.items.len});
        for (self.workers.items) |w| {
            w.deinit(self.allocator);
        }
        self.workers.deinit();
    }
};
