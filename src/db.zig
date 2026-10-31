//! Database handle: open/recover, the write path, snapshots.
const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const types = @import("types.zig");
const batch_mod = @import("batch.zig");
const wal_mod = @import("wal.zig");
const MemGraph = @import("memgraph.zig").MemGraph;
const seg_mod = @import("segment.zig");
const Segment = seg_mod.Segment;
const Batch = batch_mod.Batch;
const Op = batch_mod.Op;
const EdgeRec = types.EdgeRec;

pub const Error = types.Error;
pub const Edge = types.Edge;

pub const SyncMode = enum { every, none };

pub const Options = struct {
    path: []const u8,
    /// The MemGraph is flushed to a new L0 segment before the write that would
    /// find it at or over this size.
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
    /// Number in the active log's file name; changed only by flush.
    wal_no: u64,
    /// L0 segments, newest first. Guarded by `mu`; the list holds one
    /// reference per segment. Phase 3 replaces this with refcounted Versions.
    segments: std.ArrayList(*Segment) = .empty,
    /// Next unused file number for segments and logs (guarded by writer_mu).
    next_file_no: u64,
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

        // Inventory the directory: segments, logs, and leftovers of a flush
        // that crashed before its rename (*.tmp), which are garbage.
        var seg_nos: std.ArrayList(u64) = .empty;
        defer seg_nos.deinit(gpa);
        var wal_nos: std.ArrayList(u64) = .empty;
        defer wal_nos.deinit(gpa);
        {
            const names = try sys.listDir(gpa, dir_z);
            defer {
                for (names) |n| gpa.free(n);
                gpa.free(names);
            }
            for (names) |name| {
                if (seg_mod.parseSegName(name)) |n| {
                    try seg_nos.append(gpa, n);
                } else if (parseWalName(name)) |n| {
                    try wal_nos.append(gpa, n);
                } else if (std.mem.endsWith(u8, name, ".seg.tmp")) {
                    const p = try gpa.printSentinel("{s}/{s}", .{ opts.path, name }, 0);
                    defer gpa.free(p);
                    sys.unlink(p);
                }
            }
        }
        std.mem.sort(u64, seg_nos.items, {}, std.sort.desc(u64)); // newest first
        std.mem.sort(u64, wal_nos.items, {}, std.sort.asc(u64));

        // Open every segment; any damage fails the open rather than serving
        // a partial graph.
        var segments: std.ArrayList(*Segment) = .empty;
        errdefer {
            for (segments.items) |s| s.unref();
            segments.deinit(gpa);
        }
        var flushed_seq: u64 = 0;
        for (seg_nos.items) |n| {
            const p = try seg_mod.segPath(gpa, opts.path, n, false);
            defer gpa.free(p);
            const seg = try Segment.open(gpa, p, n);
            errdefer seg.unref();
            try segments.append(gpa, seg);
            flushed_seq = @max(flushed_seq, seg.max_seq);
        }

        var max_no: u64 = 0;
        if (seg_nos.items.len > 0) max_no = seg_nos.items[0];
        if (wal_nos.items.len > 0) max_no = @max(max_no, wal_nos.items[wal_nos.items.len - 1]);

        const mem = try MemGraph.create(gpa);
        errdefer mem.unref();

        // Recover: replay the logs, oldest first, skipping batches a segment
        // already holds (a crash between writing a segment and deleting its log).
        var last_seq: u64 = flushed_seq;
        var wal: wal_mod.Wal = undefined;
        var wal_no: u64 = undefined;
        var have_wal = false;
        for (wal_nos.items, 0..) |n, i| {
            const path = try walPath(gpa, opts.path, n);
            defer gpa.free(path);
            const bytes = (blk: {
                const f = (try sys.File.openOptional(path, .read)) orelse return error.Io;
                defer f.close();
                break :blk try f.readAll(gpa);
            });
            defer gpa.free(bytes);
            const Sink = struct {
                m: *MemGraph,
                skip_upto: u64,
                applied: bool = false,
                pub fn applyReplay(sk: *@This(), first_seq: u64, ops: []const Op) Allocator.Error!void {
                    if (first_seq + ops.len - 1 <= sk.skip_upto) return; // whole batch is in a segment
                    sk.applied = true;
                    try sk.m.apply(first_seq, ops);
                }
            };
            var sink = Sink{ .m = mem, .skip_upto = flushed_seq };
            const res = try wal_mod.replay(gpa, bytes, &sink);
            last_seq = @max(last_seq, res.last_seq);
            const is_newest = i == wal_nos.items.len - 1;
            if (is_newest) {
                wal = if (res.valid_len == 0)
                    try wal_mod.Wal.create(gpa, path, dir_z) // crashed during creation
                else
                    try wal_mod.Wal.openExisting(gpa, path, res.valid_len);
                wal_no = n;
                have_wal = true;
            } else if (!sink.applied) {
                sys.unlink(path); // fully flushed: obsolete
            }
        }
        if (!have_wal) {
            wal_no = max_no + 1;
            const path = try walPath(gpa, opts.path, wal_no);
            defer gpa.free(path);
            wal = try wal_mod.Wal.create(gpa, path, dir_z);
        }
        errdefer wal.close();

        const db = try gpa.create(Db);
        db.* = .{
            .gpa = gpa,
            .opts = opts,
            .dir_z = dir_z,
            .lock_file = lock_file,
            .mem = mem,
            .wal = wal,
            .wal_no = wal_no,
            .segments = segments,
            .next_file_no = @max(max_no, wal_no) + 1,
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
        for (db.segments.items) |seg| seg.unref();
        db.segments.deinit(gpa);
        db.snapshots.deinit(gpa);
        db.scratch_ops.deinit(gpa);
        db.lock_file.close(); // drops the flock
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

        // Flush first if the MemGraph is full. A failed flush leaves the
        // database as it was; this write is simply not performed.
        if (db.mem.bytes >= db.opts.memgraph_limit_bytes) try db.flushLocked();

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

    /// Write the MemGraph out as an L0 segment now. No-op when it is empty.
    pub fn flush(db: *Db) Error!void {
        db.writer_mu.lock();
        defer db.writer_mu.unlock();
        {
            db.mu.lock();
            defer db.mu.unlock();
            if (db.bg_error) |err| return err;
        }
        try db.flushLocked();
    }

    /// Caller holds `writer_mu`, so `mem` and `wal` cannot change under us and
    /// nothing is appended to `mem` while it is written out.
    ///
    /// Order matters for crash safety:
    ///   1. segment durable (file fsync, rename, dir fsync)
    ///   2. new log durable
    ///   3. swap mem/wal/segments under `mu`
    ///   4. delete the old log
    /// A crash after 1 leaves a segment plus an old log; recovery skips the log
    /// batches the segment already holds. Failure before 3 changes nothing.
    fn flushLocked(db: *Db) Error!void {
        const old_mem = db.mem;
        if (old_mem.bytes == 0) return;
        const gpa = db.gpa;

        const file_no = db.next_file_no;
        const new_wal_no = file_no + 1;

        var w = seg_mod.SegWriter.init(gpa, 0);
        defer w.deinit();
        {
            old_mem.lock.lockShared();
            defer old_mem.lock.unlock();
            const vids = try gpa.alloc(u64, old_mem.adj.count());
            defer gpa.free(vids);
            var kit = old_mem.adj.keyIterator();
            for (vids) |*v| v.* = kit.next().?.*;
            std.mem.sort(u64, vids, {}, std.sort.asc(u64));

            var scratch: std.ArrayList(EdgeRec) = .empty;
            defer scratch.deinit(gpa);
            for (vids) |vid| {
                scratch.clearRetainingCapacity();
                try scratch.appendSlice(gpa, old_mem.adj.get(vid).?.items);
                std.mem.sort(EdgeRec, scratch.items, {}, types.edgeLess);
                try w.addVertex(vid, scratch.items);
            }
        }
        _ = try w.finish(db.dir_z, file_no);
        var seg_on_disk = true;
        errdefer if (seg_on_disk) {
            if (seg_mod.segPath(gpa, db.dir_z, file_no, false)) |p| {
                sys.unlink(p);
                gpa.free(p);
            } else |_| {}
        };

        const seg_path = try seg_mod.segPath(gpa, db.dir_z, file_no, false);
        defer gpa.free(seg_path);
        const seg = try Segment.open(gpa, seg_path, file_no); // re-validates what we wrote
        errdefer seg.unref();

        const new_wal_path = try walPath(gpa, db.dir_z, new_wal_no);
        defer gpa.free(new_wal_path);
        var new_wal = try wal_mod.Wal.create(gpa, new_wal_path, db.dir_z);
        errdefer {
            new_wal.close();
            sys.unlink(new_wal_path);
        }
        const new_mem = try MemGraph.create(gpa);
        errdefer new_mem.unref();
        try db.segments.ensureUnusedCapacity(gpa, 1);

        const old_wal_path = try walPath(gpa, db.dir_z, db.wal_no);
        defer gpa.free(old_wal_path);
        var old_wal = db.wal;

        {
            db.mu.lock();
            defer db.mu.unlock();
            db.segments.insertAssumeCapacity(0, seg);
            db.mem = new_mem;
        }
        seg_on_disk = false; // committed: the segment is now part of the database
        db.wal = new_wal;
        db.wal_no = new_wal_no;
        db.next_file_no = new_wal_no + 1;

        // The data is safe in the segment; failing to delete the old log only
        // leaves a file that recovery will skip and remove.
        old_wal.close();
        sys.unlink(old_wal_path);
        sys.syncDir(db.dir_z) catch {};
        old_mem.unref(); // snapshots that took a ref keep reading it
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

    /// Number of L0 segments (for tests and reporting).
    pub fn segmentCount(db: *Db) usize {
        db.mu.lock();
        defer db.mu.unlock();
        return db.segments.items.len;
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
        errdefer _ = db.snapshots.pop();
        const segs = try db.gpa.alloc(*Segment, db.segments.items.len);
        for (segs, db.segments.items) |*dst, seg| dst.* = seg.ref();
        s.* = .{ .seq = seq, .mem = db.mem.ref(), .segs = segs, .db = db };
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
    /// L0 segments at snapshot time, newest first, each referenced.
    segs: []*Segment,
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
        for (s.segs) |seg| seg.unref();
        db.gpa.free(s.segs);
        db.gpa.destroy(s);
    }

    /// The iterator reads segment memory in place, so it must not outlive
    /// this snapshot.
    pub fn neighbors(s: *const Snapshot, gpa: Allocator, v: u64) Error!EdgeIter {
        var it: EdgeIter = .{ .gpa = gpa, .snap_seq = s.seq };
        errdefer it.deinit();
        try s.mem.collect(gpa, v, s.seq, &it.mem_recs);
        if (it.mem_recs.items.len > 0) try it.heap.push(gpa, .{ .recs = it.mem_recs.items });
        for (s.segs) |seg| {
            if (seg.min_seq > s.seq) continue; // everything in it is too new
            const recs = seg.lookup(v);
            if (recs.len > 0) try it.heap.push(gpa, .{ .recs = recs });
        }
        return it;
    }
};

/// One sorted run: the MemGraph copy or one segment's records of the vertex.
const Run = struct {
    recs: []const EdgeRec, // (dst asc, seq desc)
    pos: usize = 0,
};

fn runOrder(_: void, a: Run, b: Run) std.math.Order {
    const x = a.recs[a.pos];
    const y = b.recs[b.pos];
    if (x.dst != y.dst) return std.math.order(x.dst, y.dst);
    return std.math.order(y.seq, x.seq); // higher seq comes out first
}

/// K-way merge of the MemGraph copy and every segment run through a priority
/// queue. Read amplification of a scan is the number of runs merged.
pub const EdgeIter = struct {
    gpa: Allocator,
    heap: std.PriorityQueue(Run, void, runOrder) = .empty,
    mem_recs: std.ArrayList(EdgeRec) = .empty, // owned copy; a run points into it
    snap_seq: u64,
    last_dst: ?u64 = null,

    /// Yields each live edge once, at its newest version visible to the snapshot.
    pub fn next(it: *EdgeIter) ?Edge {
        while (it.heap.pop()) |popped| {
            var r = popped;
            const e = r.recs[r.pos];
            r.pos += 1;
            // Pushing back after a pop never needs to grow the queue.
            if (r.pos < r.recs.len) it.heap.push(it.gpa, r) catch unreachable;

            if (e.seq > it.snap_seq) continue; // written after the snapshot
            if (it.last_dst) |d| if (d == e.dst) continue; // older version
            it.last_dst = e.dst;
            if ((e.flags & types.tombstone) != 0) continue; // newest version is a delete
            return .{ .dst = e.dst, .weight = e.weight };
        }
        return null;
    }

    pub fn deinit(it: *EdgeIter) void {
        it.heap.deinit(it.gpa);
        it.mem_recs.deinit(it.gpa);
    }
};

fn walPath(gpa: Allocator, dir: []const u8, no: u64) Allocator.Error![:0]u8 {
    return gpa.printSentinel("{s}/wal-{d:0>6}.log", .{ dir, no }, 0);
}

fn parseWalName(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, "wal-") or !std.mem.endsWith(u8, name, ".log")) return null;
    return std.fmt.parseInt(u64, name[4 .. name.len - 4], 10) catch null;
}
