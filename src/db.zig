//! Database handle: open/recover, the write path, snapshots.
const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const types = @import("types.zig");
const batch_mod = @import("batch.zig");
const wal_mod = @import("wal.zig");
const MemGraph = @import("memgraph.zig").MemGraph;
const seg_mod = @import("segment.zig");
const merge = @import("merge.zig");
const compaction = @import("compaction.zig");
const version_mod = @import("version.zig");
const Segment = seg_mod.Segment;
const Version = version_mod.Version;
const VersionSet = version_mod.VersionSet;
const VersionEdit = version_mod.VersionEdit;
const max_levels = version_mod.max_levels;
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
    /// L0 files that make L0 -> L1 compaction due.
    l0_compaction_trigger: u32 = 4,
    /// Writers stall (before adding another L0 file) while L0 holds this many.
    /// Must exceed `l0_compaction_trigger`.
    l0_stop_trigger: u32 = 12,
    /// Each level from L1 down may hold this many times more bytes than the one above.
    size_ratio: u32 = 10,
    /// Target size of L1.
    level1_bytes: u64 = 256 << 20,
    /// Compaction closes an output segment, at a vertex boundary, once it holds
    /// this many bytes of edge records.
    target_segment_bytes: u64 = 64 << 20,
    /// Run compaction on a background thread. When false nothing compacts
    /// until the caller runs `compactOnce`, and L0 is never stalled on.
    background_compaction: bool = true,
    sync_mode: SyncMode = .every,
    /// Store (u,v) and (v,u) in one atomic batch. The expansion happens
    /// before the WAL append, so recovery never depends on this flag.
    undirected: bool = true,
};

pub const LevelStats = struct {
    /// Current files and bytes at this level.
    files: usize = 0,
    bytes: u64 = 0,
    /// Compactions that wrote into this level, and the bytes they read (from
    /// this level and the one above) and wrote.
    compactions: u64 = 0,
    bytes_read: u64 = 0,
    bytes_written: u64 = 0,
};

pub const Stats = struct {
    levels: [max_levels]LevelStats = @splat(.{}),
    flushes: u64 = 0,
    flush_bytes: u64 = 0,
    /// Writes that waited for compaction to catch up, and the total time waited.
    stalls: u64 = 0,
    stall_ns: u64 = 0,
    /// Records compaction discarded as unreachable (shadowed versions, dead tombstones).
    dropped_records: u64 = 0,
};

// Lock order, always: writer_mu -> compact_mu -> vs.apply_mu -> mu -> any
// MemGraph lock. Never the reverse.
pub const Db = struct {
    gpa: Allocator,
    opts: Options,
    dir_z: [:0]u8,
    lock_file: sys.File,

    /// Serializes writers so sequence numbers are contiguous.
    writer_mu: sys.Mutex = .{},
    /// Serializes compactions (background thread or `compactOnce`).
    compact_mu: sys.Mutex = .{},
    /// Guards `mem`, `vs.current` (swaps), `snapshots`, `bg_error`, `acc` and
    /// the background-thread flags. Held for microseconds, never across I/O.
    mu: sys.Mutex = .{},

    /// Highest sequence number visible to readers. Written only by the writer,
    /// after the WAL append and the MemGraph apply.
    last_seq: std.atomic.Value(u64) = .init(0),
    mem: *MemGraph,
    wal: wal_mod.Wal,
    /// Number in the active log's file name; changed only by flush.
    wal_no: u64,
    /// The level layout and the manifest that makes it durable. Also hands out
    /// file numbers for segments, logs and manifests.
    vs: VersionSet,
    leveled: compaction.Leveled,
    /// Logs recovered with data that are not the active one; deleted once a
    /// flush has made their contents durable in a segment (guarded by writer_mu).
    stale_wals: std.ArrayList(u64) = .empty,
    snapshots: std.ArrayList(u64) = .empty,
    bg_thread: ?std.Thread = null,
    bg_cond: sys.Cond = .{}, // wakes the compaction thread
    stall_cond: sys.Cond = .{}, // wakes stalled writers
    idle_cond: sys.Cond = .{}, // wakes `waitForCompaction`
    shutdown: bool = false,
    bg_busy: bool = false,
    acc: Stats = .{},
    /// Set when the log and memory may disagree; all later writes fail.
    /// Reopening replays the log and recovers.
    bg_error: ?Error = null,

    // Reused by the writer (guarded by writer_mu).
    scratch_ops: std.ArrayList(Op) = .empty,

    pub fn open(gpa: Allocator, opts: Options) Error!*Db {
        const db = try openStorage(gpa, opts);
        if (opts.background_compaction) {
            db.bg_thread = std.Thread.spawn(.{}, bgMain, .{db}) catch {
                db.close();
                return error.Io;
            };
        }
        return db;
    }

    fn openStorage(gpa: Allocator, opts: Options) Error!*Db {
        if (opts.l0_compaction_trigger == 0 or opts.l0_stop_trigger <= opts.l0_compaction_trigger or
            opts.size_ratio < 2 or opts.level1_bytes == 0 or opts.target_segment_bytes == 0)
        {
            return error.InvalidArgument;
        }
        const dir_z = try gpa.dupeSentinel(u8, opts.path, 0);
        errdefer gpa.free(dir_z);
        try sys.makeDir(dir_z);

        const lock_path = try gpa.printSentinel("{s}/LOCK", .{opts.path}, 0);
        defer gpa.free(lock_path);
        const lock_file = try sys.File.open(lock_path, .read_write_create);
        errdefer lock_file.close();
        try lock_file.lockExclusive();

        // Rebuild the level layout from the manifest; every listed segment is
        // opened and validated, and files nothing refers to are removed.
        var rec = try VersionSet.recover(gpa, dir_z);
        defer gpa.free(rec.wal_nos);
        var vs_moved = false;
        errdefer if (!vs_moved) rec.vs.deinit();

        const mem = try MemGraph.create(gpa);
        errdefer mem.unref();

        // Recover: replay the logs the manifest does not cover, oldest first.
        // Logs below the manifest's log number are already in segments.
        var live_wals: std.ArrayList(u64) = .empty;
        defer live_wals.deinit(gpa);
        for (rec.wal_nos) |n| {
            if (n >= rec.vs.log_number) {
                try live_wals.append(gpa, n);
                continue;
            }
            const path = try walPath(gpa, dir_z, n);
            defer gpa.free(path);
            sys.unlink(path);
        }

        var stale_wals: std.ArrayList(u64) = .empty;
        errdefer stale_wals.deinit(gpa);
        var last_seq: u64 = rec.last_seq;
        var wal: wal_mod.Wal = undefined;
        var wal_no: u64 = undefined;
        var have_wal = false;
        for (live_wals.items, 0..) |n, i| {
            const path = try walPath(gpa, dir_z, n);
            defer gpa.free(path);
            const bytes = (blk: {
                const f = (try sys.File.openOptional(path, .read)) orelse return error.Io;
                defer f.close();
                break :blk try f.readAll(gpa);
            });
            defer gpa.free(bytes);
            const Sink = struct {
                m: *MemGraph,
                applied: bool = false,
                pub fn applyReplay(sk: *@This(), first_seq: u64, ops: []const Op) Allocator.Error!void {
                    sk.applied = true;
                    try sk.m.apply(first_seq, ops);
                }
            };
            var sink = Sink{ .m = mem };
            const res = try wal_mod.replay(gpa, bytes, &sink);
            last_seq = @max(last_seq, res.last_seq);
            if (i == live_wals.items.len - 1) {
                wal = if (res.valid_len == 0)
                    try wal_mod.Wal.create(gpa, path, dir_z) // crashed during creation
                else
                    try wal_mod.Wal.openExisting(gpa, path, res.valid_len);
                wal_no = n;
                have_wal = true;
            } else if (sink.applied) {
                try stale_wals.append(gpa, n); // its data is only in `mem` until the next flush
            } else {
                sys.unlink(path);
            }
        }
        if (!have_wal) {
            wal_no = rec.vs.newFileNumber();
            const path = try walPath(gpa, dir_z, wal_no);
            defer gpa.free(path);
            wal = try wal_mod.Wal.create(gpa, path, dir_z);
        }
        errdefer wal.close();

        // A fresh manifest for this session; CURRENT switches to it atomically.
        try rec.vs.startManifest(last_seq);

        const db = try gpa.create(Db);
        db.* = .{
            .gpa = gpa,
            .opts = opts,
            .dir_z = dir_z,
            .lock_file = lock_file,
            .mem = mem,
            .wal = wal,
            .wal_no = wal_no,
            .vs = rec.vs,
            .leveled = .{ .params = .{
                .l0_compaction_trigger = opts.l0_compaction_trigger,
                .size_ratio = opts.size_ratio,
                .level1_bytes = opts.level1_bytes,
            } },
            .stale_wals = stale_wals,
        };
        vs_moved = true;
        db.opts.path = dir_z; // own the path; the caller's slice may not outlive us
        db.last_seq.store(last_seq, .release);
        return db;
    }

    pub fn close(db: *Db) void {
        const gpa = db.gpa;
        if (db.bg_thread) |t| {
            // Waits for a compaction in progress to finish its install.
            db.mu.lock();
            db.shutdown = true;
            db.bg_cond.broadcast();
            db.mu.unlock();
            t.join();
        }
        // No sync here: with sync_mode .none the caller accepted that.
        db.wal.close();
        db.mem.unref();
        db.vs.deinit();
        db.stale_wals.deinit(gpa);
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
    ///   3. manifest edit (adds the segment, raises the log number) durable,
    ///      then the new Version is installed, then the new MemGraph
    ///   4. delete the old logs
    /// A crash before 3 leaves an orphan segment, which recovery deletes, and
    /// the old log, which it replays. A crash after 3 leaves an old log below
    /// the manifest's log number, which recovery deletes without replaying.
    fn flushLocked(db: *Db) Error!void {
        const old_mem = db.mem;
        if (old_mem.bytes == 0) return;
        try db.waitForL0Room();
        const gpa = db.gpa;

        const file_no = db.vs.newFileNumber();
        const new_wal_no = db.vs.newFileNumber();

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
        defer seg.unref(); // the edit and the new Version hold their own references

        const new_wal_path = try walPath(gpa, db.dir_z, new_wal_no);
        defer gpa.free(new_wal_path);
        var new_wal = try wal_mod.Wal.create(gpa, new_wal_path, db.dir_z);
        errdefer {
            new_wal.close();
            sys.unlink(new_wal_path);
        }
        const new_mem = try MemGraph.create(gpa);
        errdefer new_mem.unref();

        var edit: VersionEdit = .{};
        defer edit.deinit(gpa);
        try edit.addSegment(gpa, 0, seg);
        edit.log_number = new_wal_no;
        edit.last_seq = db.last_seq.load(.monotonic); // writer_mu: stable

        db.vs.logAndApply(&edit, &db.mu) catch |err| {
            // A failed manifest write may still have reached disk. Then the
            // segment must stay, and the handle is unusable until reopened.
            if (db.vs.isBroken()) {
                seg_on_disk = false;
                return db.fail(err);
            }
            return err;
        };
        seg_on_disk = false; // committed: the segment is now part of the database
        // Nothing below can fail. Readers that took a snapshot between the two
        // swaps see the segment and the old MemGraph: the same records twice,
        // which the scan's merge collapses.
        {
            db.mu.lock();
            defer db.mu.unlock();
            db.mem = new_mem;
            db.acc.flushes += 1;
            db.acc.flush_bytes += seg.bytes();
        }
        const old_wal_path = walPath(gpa, db.dir_z, db.wal_no) catch null;
        var old_wal = db.wal;
        db.wal = new_wal;
        db.wal_no = new_wal_no;

        // The data is safe in the segment; failing to delete an old log only
        // leaves a file that recovery will skip and remove.
        old_wal.close();
        if (old_wal_path) |p| {
            sys.unlink(p);
            gpa.free(p);
        }
        for (db.stale_wals.items) |n| {
            if (walPath(gpa, db.dir_z, n)) |p| {
                sys.unlink(p);
                gpa.free(p);
            } else |_| {}
        }
        db.stale_wals.clearRetainingCapacity();
        sys.syncDir(db.dir_z) catch {};
        old_mem.unref(); // snapshots that took a ref keep reading it
        if (db.bg_thread != null) db.bg_cond.signal();
    }

    /// Hold the writer back while L0 is at `l0_stop_trigger` files, so reads
    /// do not drift toward merging dozens of runs. Time spent here is reported
    /// as its own metric.
    fn waitForL0Room(db: *Db) Error!void {
        if (db.bg_thread == null) return; // nobody would ever drain L0
        db.mu.lock();
        defer db.mu.unlock();
        var start: ?u64 = null;
        defer if (start) |t| {
            db.acc.stalls += 1;
            db.acc.stall_ns += sys.nanoTime() - t;
        };
        while (db.vs.current.levels[0].len >= db.opts.l0_stop_trigger) {
            if (db.bg_error) |err| return err;
            if (start == null) start = sys.nanoTime();
            db.bg_cond.signal();
            db.stall_cond.wait(&db.mu);
        }
    }

    // ---- compaction ---------------------------------------------------------

    fn compactionWanted(db: *Db) bool {
        return db.leveled.policy().maxScore(db.vs.current) >= 1;
    }

    fn bgMain(db: *Db) void {
        db.mu.lock();
        while (!db.shutdown) {
            if (db.bg_error == null and db.compactionWanted()) {
                db.bg_busy = true;
                db.mu.unlock();
                const result = db.compactImpl(null);
                db.mu.lock();
                db.bg_busy = false;
                db.stall_cond.broadcast();
                db.idle_cond.broadcast();
                if (result) |ran| {
                    if (ran) continue;
                } else |err| {
                    if (db.bg_error == null) db.bg_error = err;
                    continue;
                }
                // Due but nothing to pick: sleep until the layout changes.
            }
            db.idle_cond.broadcast();
            db.bg_cond.wait(&db.mu);
        }
        db.mu.unlock();
    }

    /// Run the compaction the policy picks, if any is due, on the calling
    /// thread. Returns whether one ran. This is the manual mode for
    /// `background_compaction = false`; it is also safe alongside the thread.
    pub fn compactOnce(db: *Db) Error!bool {
        return db.compactImpl(null);
    }

    /// Compact `level` into `level + 1` now, whatever its score (like
    /// RocksDB's CompactRange). Returns false if the level is empty.
    pub fn compactLevel(db: *Db, level: u16) Error!bool {
        return db.compactImpl(level);
    }

    /// Block until no compaction is due and none is running.
    pub fn waitForCompaction(db: *Db) Error!void {
        if (db.bg_thread == null) {
            while (try db.compactOnce()) {}
            return;
        }
        db.mu.lock();
        defer db.mu.unlock();
        while (true) {
            if (db.bg_error) |err| return err;
            if (!db.bg_busy and !db.compactionWanted()) return;
            db.bg_cond.signal();
            db.idle_cond.wait(&db.mu);
        }
    }

    fn compactImpl(db: *Db, forced: ?u16) Error!bool {
        db.compact_mu.lock();
        defer db.compact_mu.unlock();
        const gpa = db.gpa;

        // Pin the layout we pick from, and read the oldest snapshot in the same
        // critical section. A snapshot taken afterwards reads at a sequence
        // number >= this one, so nothing dropped below is visible to it.
        var v: *Version = undefined;
        var oldest: u64 = undefined;
        {
            db.mu.lock();
            defer db.mu.unlock();
            if (db.bg_error) |err| return err;
            v = db.vs.current.ref();
            oldest = db.oldestSnapshotSeqLocked();
        }
        defer v.unref();

        const comp = (if (forced) |lvl|
            try db.leveled.pickLevel(gpa, v, lvl)
        else
            try db.leveled.policy().pick(gpa, v)) orelse return false;
        defer comp.deinit(gpa);
        const out_level = comp.outLevel();
        const rng = comp.range();

        var outputs: std.ArrayList(*Segment) = .empty;
        var installed = false; // outputs are part of the database
        var keep_files = false; // the manifest may list them: never delete
        defer {
            for (outputs.items) |s| {
                if (!installed and !keep_files) s.markObsolete();
                s.unref();
            }
            outputs.deinit(gpa);
        }
        var st: compaction.MergeStats = .{};
        try compaction.mergeInputs(gpa, db.dir_z, &db.vs, comp, .{
            .out_level = out_level,
            .oldest_snap = oldest,
            .is_bottom = compaction.isBottom(v, out_level, rng.lo, rng.hi),
            .target_bytes = db.opts.target_segment_bytes,
        }, &outputs, &st);

        // One edit swaps inputs for outputs atomically.
        var edit: VersionEdit = .{};
        defer edit.deinit(gpa);
        for (comp.inputs[0]) |s| try edit.deleteFile(gpa, comp.level, s.file_no);
        for (comp.inputs[1]) |s| try edit.deleteFile(gpa, out_level, s.file_no);
        for (outputs.items) |s| try edit.addSegment(gpa, out_level, s);
        db.vs.logAndApply(&edit, &db.mu) catch |err| {
            if (db.vs.isBroken()) {
                keep_files = true;
                return db.fail(err);
            }
            return err;
        };
        installed = true;

        db.mu.lock();
        defer db.mu.unlock();
        const ls = &db.acc.levels[out_level];
        ls.compactions += 1;
        ls.bytes_read += st.bytes_read;
        ls.bytes_written += st.bytes_written;
        db.acc.dropped_records += st.records_in - st.records_out;
        db.stall_cond.broadcast();
        return true;
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

    /// Number of segment files in the current layout (for tests and reporting).
    pub fn segmentCount(db: *Db) usize {
        db.mu.lock();
        defer db.mu.unlock();
        return db.vs.current.totalFiles();
    }

    /// Segment files per level in the current layout.
    pub fn levelFileCounts(db: *Db) [max_levels]usize {
        db.mu.lock();
        defer db.mu.unlock();
        var out: [max_levels]usize = undefined;
        for (&out, 0..) |*n, lvl| n.* = db.vs.current.numFiles(lvl);
        return out;
    }

    /// Counters since open, plus the current size of every level. Write
    /// amplification of a level is its `bytes_written` over the bytes that
    /// entered it from above.
    pub fn stats(db: *Db) Stats {
        db.mu.lock();
        defer db.mu.unlock();
        var out = db.acc;
        for (&out.levels, 0..) |*ls, lvl| {
            ls.files = db.vs.current.numFiles(lvl);
            ls.bytes = db.vs.current.levelBytes(lvl);
        }
        return out;
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
        s.* = .{ .seq = seq, .mem = db.mem.ref(), .version = db.vs.current.ref(), .db = db };
        return s;
    }

    /// Smallest sequence number any live snapshot reads at, or `last_seq` when
    /// there are none. Compaction uses it to decide what is garbage.
    pub fn oldestSnapshotSeq(db: *Db) u64 {
        db.mu.lock();
        defer db.mu.unlock();
        return db.oldestSnapshotSeqLocked();
    }

    fn oldestSnapshotSeqLocked(db: *Db) u64 {
        var oldest = db.last_seq.load(.acquire);
        for (db.snapshots.items) |s| oldest = @min(oldest, s);
        return oldest;
    }
};

pub const Snapshot = struct {
    seq: u64,
    mem: *MemGraph,
    /// The layout at snapshot time. Holding it keeps every segment file it lists
    /// alive, even after compaction has replaced them.
    version: *Version,
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
        s.version.unref(); // may unlink segment files compaction has replaced
        db.gpa.destroy(s);
    }

    /// The iterator reads segment memory in place, so it must not outlive
    /// this snapshot.
    pub fn neighbors(s: *const Snapshot, gpa: Allocator, v: u64) Error!EdgeIter {
        var it: EdgeIter = .{ .gpa = gpa, .snap_seq = s.seq };
        errdefer it.deinit();
        try s.mem.collect(gpa, v, s.seq, &it.mem_recs);
        if (it.mem_recs.items.len > 0) try it.heap.push(gpa, .{ .recs = it.mem_recs.items });
        // L0 ranges overlap: every segment may hold `v`. Deeper levels are
        // disjoint: at most one segment per level does.
        for (s.version.levels[0]) |seg| try it.pushSegment(gpa, seg, v);
        for (1..max_levels) |lvl| {
            if (s.version.findCovering(lvl, v)) |seg| try it.pushSegment(gpa, seg, v);
        }
        return it;
    }
};

const Run = merge.Run;

/// K-way merge of the MemGraph copy and every segment run through a priority
/// queue. Read amplification of a scan is the number of runs merged.
pub const EdgeIter = struct {
    gpa: Allocator,
    heap: merge.RunHeap = .empty,
    mem_recs: std.ArrayList(EdgeRec) = .empty, // owned copy; a run points into it
    snap_seq: u64,
    last_dst: ?u64 = null,

    fn pushSegment(it: *EdgeIter, gpa: Allocator, seg: *const Segment, v: u64) Allocator.Error!void {
        if (seg.min_seq > it.snap_seq) return; // everything in it is too new
        const recs = seg.lookup(v);
        if (recs.len > 0) try it.heap.push(gpa, .{ .recs = recs });
    }

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
