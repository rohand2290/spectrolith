//! Database handle: open/recover, the write path, snapshots.
const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const types = @import("types.zig");
const batch_mod = @import("batch.zig");
const wal_mod = @import("wal.zig");
const MemGraph = @import("memgraph.zig").MemGraph;
const Batch = batch_mod.Batch;
const Op = batch_mod.Op;
const EdgeRec = types.EdgeRec;

pub const Error = types.Error;
pub const Edge = types.Edge;

pub const SyncMode = enum { every, none };

pub const Options = struct {
    path: []const u8,
    /// Phase 2: MemGraph flush threshold. Phase 1 has no flush, so the
    /// MemGraph grows until the process exits.
    memgraph_limit_bytes: usize = 64 << 20,
    l0_compaction_trigger: u32 = 4, // phase 4
    l0_stop_trigger: u32 = 12, // phase 4
    size_ratio: u32 = 10, // phase 4
    level1_bytes: u64 = 256 << 20, // phase 4
    sync_mode: SyncMode = .every,
    /// Store (u,v) and (v,u) in one atomic batch. The expansion happens
    /// before the WAL append, so recovery never depends on this flag.
    undirected: bool = true,
};

// Lock order, always: writer_mu -> mu -> any MemGraph lock. Never the reverse.
pub const Db = struct {
    gpa: Allocator,
    opts: Options,
    dir_z: [:0]u8,
    wal_path_z: [:0]u8,
    lock_file: sys.File,

    /// Serializes writers so sequence numbers are contiguous.
    writer_mu: sys.Mutex = .{},
    /// Guards `mem`, `snapshots`, `bg_error`. Held for microseconds, never
    /// across I/O.
    mu: sys.Mutex = .{},

    /// Highest sequence number visible to readers. Written only by the writer,
    /// after the WAL append and the MemGraph apply.
    last_seq: std.atomic.Value(u64) = .init(0),
    mem: *MemGraph,
    wal: wal_mod.Wal,
    snapshots: std.ArrayList(u64) = .empty,
    /// Set when the log and memory may disagree; all later writes fail.
    /// Reopening replays the log and recovers.
    bg_error: ?Error = null,

    // Reused by the writer (guarded by writer_mu).
    scratch_ops: std.ArrayList(Op) = .empty,

    pub fn open(gpa: Allocator, opts: Options) Error!*Db {
        const dir_z = try gpa.dupeSentinel(u8, opts.path, 0);
        errdefer gpa.free(dir_z);
        try sys.makeDir(dir_z);

        const lock_path = try gpa.printSentinel("{s}/LOCK", .{opts.path}, 0);
        defer gpa.free(lock_path);
        const lock_file = try sys.File.open(lock_path, .read_write_create);
        errdefer lock_file.close();
        try lock_file.lockExclusive();

        const wal_path = try gpa.printSentinel("{s}/wal-{d:0>6}.log", .{ opts.path, 1 }, 0);
        errdefer gpa.free(wal_path);

        const mem = try MemGraph.create(gpa);
        errdefer mem.unref();

        // Recover: replay the log into the MemGraph.
        var last_seq: u64 = 0;
        var wal: wal_mod.Wal = undefined;
        const existing: ?[]u8 = blk: {
            const f = (try sys.File.openOptional(wal_path, .read)) orelse break :blk null;
            defer f.close();
            break :blk try f.readAll(gpa);
        };
        if (existing) |bytes| {
            defer gpa.free(bytes);
            const Sink = struct {
                m: *MemGraph,
                pub fn applyReplay(s: @This(), first_seq: u64, ops: []const Op) Allocator.Error!void {
                    try s.m.apply(first_seq, ops);
                }
            };
            const res = try wal_mod.replay(gpa, bytes, Sink{ .m = mem });
            last_seq = res.last_seq;
            if (res.valid_len == 0) {
                wal = try wal_mod.Wal.create(gpa, wal_path, dir_z); // crashed during creation
            } else {
                wal = try wal_mod.Wal.openExisting(gpa, wal_path, res.valid_len);
            }
        } else {
            wal = try wal_mod.Wal.create(gpa, wal_path, dir_z);
        }
        errdefer wal.close();

        const db = try gpa.create(Db);
        db.* = .{
            .gpa = gpa,
            .opts = opts,
            .dir_z = dir_z,
            .wal_path_z = wal_path,
            .lock_file = lock_file,
            .mem = mem,
            .wal = wal,
        };
        db.opts.path = dir_z; // own the path; the caller's slice may not outlive us
        db.last_seq.store(last_seq, .release);
        return db;
    }

    pub fn close(db: *Db) void {
        const gpa = db.gpa;
        // No sync here: with sync_mode .none the caller accepted that.
        db.wal.close();
        db.mem.unref();
        db.snapshots.deinit(gpa);
        db.scratch_ops.deinit(gpa);
        db.lock_file.close(); // drops the flock
        gpa.free(db.wal_path_z);
        gpa.free(db.dir_z);
        gpa.destroy(db);
    }

    pub fn putEdge(db: *Db, src: u64, dst: u64, w: f32) Error!void {
        const ops = [_]Op{.{ .kind = .put, .src = src, .dst = dst, .weight = w }};
        try db.writeOps(&ops);
    }

    pub fn delEdge(db: *Db, src: u64, dst: u64) Error!void {
        const ops = [_]Op{.{ .kind = .del, .src = src, .dst = dst, .weight = 0 }};
        try db.writeOps(&ops);
    }

    /// Apply every op in `batch` atomically: all become durable and visible
    /// together, or none do.
    pub fn write(db: *Db, batch: *const Batch) Error!void {
        try db.writeOps(batch.ops.items);
    }

    fn writeOps(db: *Db, user_ops: []const Op) Error!void {
        try batch_mod.validate(user_ops);
        if (user_ops.len == 0) return;

        db.writer_mu.lock(); // one writer at a time
        defer db.writer_mu.unlock();

        {
            db.mu.lock();
            defer db.mu.unlock();
            if (db.bg_error) |err| return err;
        }

        // Undirected graphs store both directions inside the same batch. The
        // expanded form is what reaches the log. Check the size after expanding.
        const ops: []const Op = if (db.opts.undirected) blk: {
            db.scratch_ops.clearRetainingCapacity();
            try db.scratch_ops.ensureTotalCapacity(db.gpa, user_ops.len * 2);
            for (user_ops) |op| {
                db.scratch_ops.appendAssumeCapacity(op);
                if (op.src != op.dst) { // a self-loop is its own mirror
                    var rev = op;
                    rev.src = op.dst;
                    rev.dst = op.src;
                    db.scratch_ops.appendAssumeCapacity(rev);
                }
            }
            try batch_mod.validate(db.scratch_ops.items);
            break :blk db.scratch_ops.items;
        } else user_ops;

        const first = db.last_seq.load(.monotonic) + 1;

        // Any failure from here on leaves the log in an unknown state (a
        // failed fsync cannot be retried safely), so poison the handle.
        db.wal.append(first, ops) catch |err| return db.fail(err);
        if (db.opts.sync_mode == .every) db.wal.sync() catch |err| return db.fail(err);

        db.mem.apply(first, ops) catch |err| {
            // In the log but not (fully) in memory. Refuse further writes;
            // reopening replays the log and recovers the batch.
            return db.fail(err);
        };
        db.last_seq.store(first + ops.len - 1, .release); // publish
    }

    fn fail(db: *Db, err: Error) Error {
        db.mu.lock();
        defer db.mu.unlock();
        if (db.bg_error == null) db.bg_error = err;
        return err;
    }

    /// Force the log to stable storage (useful with sync_mode .none).
    pub fn sync(db: *Db) Error!void {
        db.writer_mu.lock();
        defer db.writer_mu.unlock();
        db.wal.sync() catch |err| return db.fail(err);
    }

    pub fn lastSeq(db: *const Db) u64 {
        return db.last_seq.load(.acquire);
    }

    pub fn snapshot(db: *Db) Error!*Snapshot {
        const s = try db.gpa.create(Snapshot);
        errdefer db.gpa.destroy(s);

        db.mu.lock(); // microseconds, never across I/O
        defer db.mu.unlock();
        const seq = db.last_seq.load(.acquire);
        try db.snapshots.append(db.gpa, seq); // may fail, so before taking refs
        s.* = .{ .seq = seq, .mem = db.mem.ref(), .db = db };
        return s;
    }

    /// Smallest sequence number any live snapshot reads at, or `last_seq` when
    /// there are none. Compaction (phase 4) uses it to decide what is garbage.
    pub fn oldestSnapshotSeq(db: *Db) u64 {
        db.mu.lock();
        defer db.mu.unlock();
        var oldest = db.last_seq.load(.acquire);
        for (db.snapshots.items) |s| oldest = @min(oldest, s);
        return oldest;
    }
};

pub const Snapshot = struct {
    seq: u64,
    mem: *MemGraph,
    db: *Db,

    pub fn release(s: *Snapshot) void {
        const db = s.db;
        {
            db.mu.lock();
            defer db.mu.unlock();
            for (db.snapshots.items, 0..) |seq, i| {
                if (seq == s.seq) {
                    _ = db.snapshots.swapRemove(i);
                    break;
                }
            }
        }
        s.mem.unref();
        db.gpa.destroy(s);
    }

    pub fn neighbors(s: *const Snapshot, gpa: Allocator, v: u64) Error!EdgeIter {
        var recs: std.ArrayList(EdgeRec) = .empty;
        errdefer recs.deinit(gpa);
        try s.mem.collect(gpa, v, s.seq, &recs);
        return .{ .gpa = gpa, .recs = recs, .snap_seq = s.seq };
    }
};

/// Phase 1 has a single sorted run (the MemGraph). Later phases merge one run
/// per level through a priority queue; the `next` contract stays the same.
pub const EdgeIter = struct {
    gpa: Allocator,
    recs: std.ArrayList(EdgeRec), // (dst asc, seq desc), all seq <= snap_seq
    snap_seq: u64,
    pos: usize = 0,
    last_dst: ?u64 = null,

    /// Yields each live edge once, at its newest version visible to the snapshot.
    pub fn next(it: *EdgeIter) ?Edge {
        while (it.pos < it.recs.items.len) {
            const e = it.recs.items[it.pos];
            it.pos += 1;
            if (e.seq > it.snap_seq) continue; // written after the snapshot
            if (it.last_dst) |d| if (d == e.dst) continue; // older version
            it.last_dst = e.dst;
            if ((e.flags & types.tombstone) != 0) continue; // newest version is a delete
            return .{ .dst = e.dst, .weight = e.weight };
        }
        return null;
    }

    pub fn deinit(it: *EdgeIter) void {
        it.recs.deinit(it.gpa);
    }
};
