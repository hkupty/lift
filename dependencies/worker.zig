const std = @import("std");
const Thread = std.Thread;
const spec = @import("spec.zig");
const DownloadManager = @import("http.zig");
const LocalRepo = @import("local_repo.zig").LocalRepo;

pub const WorkItem = union(enum) {
    dependency: spec.Asset,
    close: void,

    pub fn StopQueue() WorkItem {
        return WorkItem.close;
    }

    pub fn Dep(dep: spec.Asset) WorkItem {
        return .{ .dependency = dep };
    }

    pub fn deinit(self: *const WorkItem) void {
        switch (self.*) {
            .dependency => |dep| dep.deinit(),
            .close => {},
        }
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
    hasFailure: bool = false,
    dm: DownloadManager,
    lr: LocalRepo,

    // NOTE: Ideally, we don't return any errors here, we handle everything gracefully.
    pub fn work(self: *Worker) void {
        var running = true;
        const allocator = self.arena.allocator();
        outer: while (running) {
            while (self.queue.next()) |item| {
                defer item.deinit();
                switch (item.*) {
                    .close => {
                        running = false;
                        std.log.info("Closing the loop", .{});
                        break :outer;
                    },
                    .dependency => |dep| {
                        // TODO: Configure repository

                        const baseUrl = dep.uri(allocator, spec.defaultMaven) catch |err| {
                            std.log.err("Failed to resolve url: {any}", .{err});
                            self.hasFailure = true;
                            continue;
                        };
                        defer allocator.free(baseUrl);

                        const jar = dep.remoteFilename(allocator, .jar) catch |err| {
                            std.log.err("Failed to resolve remote filename: {any}", .{err});
                            self.hasFailure = true;
                            continue;
                        };
                        defer allocator.free(jar);

                        const parts = [_][]const u8{ baseUrl, jar };

                        const url = std.mem.joinZ(allocator, "/", &parts) catch |err| {
                            std.log.err("Failed to resolve full url: {any}", .{err});
                            self.hasFailure = true;
                            continue;
                        };
                        defer allocator.free(url);

                        self.lr.prepare(allocator, dep) catch |err| {
                            std.log.err("Failed to prepare path for dependency: {any}", .{err});
                            self.hasFailure = true;
                            continue;
                        };
                        const path = self.lr.absolutePath(allocator, dep, .jar) catch |err| {
                            std.log.err("Failed to get full local path: {any}", .{err});
                            self.hasFailure = true;
                            continue;
                        };
                        defer allocator.free(path);

                        var file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch |err| {
                            std.log.err("Failed open file at path {s}: {any}", .{ path, err });
                            self.hasFailure = true;
                            continue;
                        };
                        defer file.close();

                        var reader = self.dm.download(url) catch |err| {
                            std.log.err("Failed to download jar: {any}", .{err});
                            self.hasFailure = true;
                            continue;
                        };
                        defer reader.deinit();

                        file.writer().writeAll(reader.asSlice()) catch |err| {
                            std.log.err("Unable to save jar to file: {any}", .{err});
                            self.hasFailure = true;
                            continue;
                        };
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

    pub fn init(parentThreadAllocator: std.mem.Allocator, lr: LocalRepo) !*Worker {

        // HACK: Measure and fine tune. 2MB should be OK for now

        var worker = try parentThreadAllocator.create(Worker);

        worker.queue = .{};
        worker.memBuffer = try parentThreadAllocator.alloc(u8, 2 * 1024 * 1024);
        errdefer parentThreadAllocator.free(worker.memBuffer);
        worker.fba = std.heap.FixedBufferAllocator.init(worker.memBuffer);
        worker.active = std.atomic.Value(bool).init(true);
        worker.arena = std.heap.ArenaAllocator.init(worker.fba.allocator());
        errdefer worker.arena.deinit();
        worker.thread = try std.Thread.spawn(.{ .allocator = worker.arena.allocator() }, Worker.work, .{worker});
        errdefer worker.thread.join();

        worker.dm = try DownloadManager.init(worker.arena.allocator());
        worker.lr = lr;
        return worker;
    }

    pub fn deinit(self: *Worker, parentThreadAllocator: std.mem.Allocator) void {
        self.active.store(false, .release);
        self.thread.join();
        self.arena.deinit();
        self.dm.deinit();
        parentThreadAllocator.free(self.memBuffer);
    }
};

pub const WorkerPool = struct {
    allocator: std.mem.Allocator,
    localRepo: LocalRepo,
    workers: std.ArrayList(*Worker),
    lastInsert: usize,

    pub fn init(allocator: std.mem.Allocator, localRepo: LocalRepo) !*WorkerPool {
        var pool = try allocator.create(WorkerPool);
        pool.allocator = allocator;
        pool.localRepo = localRepo;
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
            const next = try Worker.init(self.allocator, self.localRepo);
            errdefer next.deinit(self.allocator);
            try self.workers.append(next);
            try next.enqueue(item);
            self.lastInsert = view.len; // same as self.workers.items.len - 1;
        }
    }

    pub fn deinit(self: *WorkerPool) bool {
        std.log.info("Deinitializing {d} workers from pool", .{self.workers.items.len});
        var anyFailure = false;
        for (self.workers.items) |w| {
            w.deinit(self.allocator);
            if (!anyFailure and w.hasFailure) {
                anyFailure = true;
            }
        }
        self.workers.deinit();
        return anyFailure;
    }
};
