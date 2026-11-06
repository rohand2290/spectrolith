const std = @import("std");
const testing = std.testing;
const sys = @import("sys.zig");
const sp = @import("spectrolith.zig");
const Db = sp.Db;

var tmp_counter: std.atomic.Value(u32) = .init(0);

/// A scratch directory under .zig-cache, removed on deinit.
const TmpDir = struct {
    path: [:0]u8,

    fn init() !TmpDir {
        try sys.makeDir(".zig-cache");
        const n = tmp_counter.fetchAdd(1, .monotonic);
        const p = try testing.allocator.printSentinel(".zig-cache/spl-test-{d}-{d}", .{ std.c.getpid(), n }, 0);
        try sys.makeDir(p);
        return .{ .path = p };
    }

    fn deinit(t: *TmpDir) void {
        if (sys.listDir(testing.allocator, t.path)) |names| {
            defer testing.allocator.free(names);
            for (names) |name| {
                defer testing.allocator.free(name);
                const f = std.fmt.allocPrintSentinel(testing.allocator, "{s}/{s}", .{ t.path, name }, 0) catch continue;
                defer testing.allocator.free(f);
                sys.unlink(f);
            }
        } else |_| {}
        sys.rmdir(t.path);
        testing.allocator.free(t.path);
    }

    fn walPath(t: *const TmpDir) ![:0]u8 {
        return testing.allocator.printSentinel("{s}/wal-000001.log", .{t.path}, 0);
    }
};

fn collect(snap: *sp.Snapshot, v: u64, out: *std.ArrayList(sp.Edge)) !void {
    var it = try snap.neighbors(testing.allocator, v);
    defer it.deinit();
    out.clearRetainingCapacity();
    while (it.next()) |e| try out.append(testing.allocator, e);
}

test "put, neighbors, undirected mirror" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, .{ .path = tmp.path });
    defer db.close();

    try db.putEdge(1, 2, 0.5);
    try db.putEdge(1, 3, 0.25);
    try db.putEdge(1, 2, 0.75); // update

    const snap = try db.snapshot();
    defer snap.release();
    var got: std.ArrayList(sp.Edge) = .empty;
    defer got.deinit(testing.allocator);

    try collect(snap, 1, &got);
    try testing.expectEqual(@as(usize, 2), got.items.len);
    try testing.expectEqual(@as(u64, 2), got.items[0].dst);
    try testing.expectEqual(@as(f32, 0.75), got.items[0].weight); // newest wins
    try testing.expectEqual(@as(u64, 3), got.items[1].dst);

    try collect(snap, 2, &got); // mirror edge
    try testing.expectEqual(@as(usize, 1), got.items.len);
    try testing.expectEqual(@as(u64, 1), got.items[0].dst);
    try testing.expectEqual(@as(f32, 0.75), got.items[0].weight);

    try collect(snap, 99, &got);
    try testing.expectEqual(@as(usize, 0), got.items.len);
}

test "directed mode stores one direction; self-loop stored once when undirected" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, .{ .path = tmp.path, .undirected = false });
    defer db.close();
    try db.putEdge(1, 2, 1);
    try testing.expectEqual(@as(u64, 1), db.lastSeq());

    var tmp2 = try TmpDir.init();
    defer tmp2.deinit();
    const db2 = try Db.open(testing.allocator, .{ .path = tmp2.path });
    defer db2.close();
    try db2.putEdge(5, 5, 1);
    try testing.expectEqual(@as(u64, 1), db2.lastSeq());
    try db2.putEdge(5, 6, 1);
    try testing.expectEqual(@as(u64, 3), db2.lastSeq());
}

test "delete hides the edge; re-put brings it back" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, .{ .path = tmp.path });
    defer db.close();
    var got: std.ArrayList(sp.Edge) = .empty;
    defer got.deinit(testing.allocator);

    try db.putEdge(1, 2, 1);
    try db.delEdge(1, 2);
    {
        const s = try db.snapshot();
        defer s.release();
        try collect(s, 1, &got);
        try testing.expectEqual(@as(usize, 0), got.items.len);
        try collect(s, 2, &got); // mirror deleted too
        try testing.expectEqual(@as(usize, 0), got.items.len);
    }
    try db.putEdge(1, 2, 3);
    {
        const s = try db.snapshot();
        defer s.release();
        try collect(s, 1, &got);
        try testing.expectEqual(@as(usize, 1), got.items.len);
        try testing.expectEqual(@as(f32, 3), got.items[0].weight);
    }
}

test "snapshots do not see later writes" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, .{ .path = tmp.path });
    defer db.close();
    var got: std.ArrayList(sp.Edge) = .empty;
    defer got.deinit(testing.allocator);

    try db.putEdge(1, 2, 1);
    const old = try db.snapshot();
    defer old.release();
    try db.putEdge(1, 3, 1);
    try db.delEdge(1, 2);
    const new = try db.snapshot();
    defer new.release();

    try collect(old, 1, &got);
    try testing.expectEqual(@as(usize, 1), got.items.len);
    try testing.expectEqual(@as(u64, 2), got.items[0].dst);

    try collect(new, 1, &got);
    try testing.expectEqual(@as(usize, 1), got.items.len);
    try testing.expectEqual(@as(u64, 3), got.items[0].dst);

    try testing.expectEqual(old.seq, db.oldestSnapshotSeq());
}

test "batch is atomic: a bad op rejects the whole batch" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, .{ .path = tmp.path });
    defer db.close();

    var b: sp.Batch = .{};
    defer b.deinit(testing.allocator);
    try b.put(testing.allocator, 1, 2, 1);
    try b.put(testing.allocator, 3, 4, std.math.nan(f32));
    try testing.expectError(error.InvalidArgument, db.write(&b));
    try testing.expectEqual(@as(u64, 0), db.lastSeq());

    b.clear();
    try b.put(testing.allocator, 1, 2, 1);
    try b.put(testing.allocator, 3, 4, 1);
    try b.del(testing.allocator, 1, 2);
    try db.write(&b);
    try testing.expectEqual(@as(u64, 6), db.lastSeq()); // 3 ops, mirrored
}

test "reopen recovers acknowledged writes" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    {
        const db = try Db.open(testing.allocator, .{ .path = tmp.path });
        defer db.close();
        for (0..100) |i| try db.putEdge(i, i + 1000, @floatFromInt(i));
        try db.delEdge(7, 1007);
    }
    const db = try Db.open(testing.allocator, .{ .path = tmp.path });
    defer db.close();
    try testing.expectEqual(@as(u64, 202), db.lastSeq());

    var got: std.ArrayList(sp.Edge) = .empty;
    defer got.deinit(testing.allocator);
    const s = try db.snapshot();
    defer s.release();
    try collect(s, 8, &got);
    try testing.expectEqual(@as(usize, 1), got.items.len); // 8 -> 1008 only
    try testing.expectEqual(@as(u64, 1008), got.items[0].dst);
    try collect(s, 7, &got);
    try testing.expectEqual(@as(usize, 0), got.items.len);

    // New writes continue the sequence.
    try db.putEdge(500, 501, 1);
    try testing.expectEqual(@as(u64, 204), db.lastSeq());
}

test "recovery cuts a torn tail and keeps appending after it" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    {
        const db = try Db.open(testing.allocator, .{ .path = tmp.path, .undirected = false });
        defer db.close();
        try db.putEdge(1, 2, 1);
        try db.putEdge(3, 4, 1);
    }
    // Simulate a crash mid-append: half a record at the end.
    const wal_path = try tmp.walPath();
    defer testing.allocator.free(wal_path);
    {
        const f = try sys.File.open(wal_path, .append);
        defer f.close();
        try f.writeAll(&[_]u8{ 0xde, 0xad, 0xbe, 0xef, 40, 0, 0, 0, 1, 9, 9 });
    }
    {
        const db = try Db.open(testing.allocator, .{ .path = tmp.path, .undirected = false });
        defer db.close();
        try testing.expectEqual(@as(u64, 2), db.lastSeq());
        try db.putEdge(5, 6, 1); // must land after the cut, not behind the garbage
    }
    const db = try Db.open(testing.allocator, .{ .path = tmp.path, .undirected = false });
    defer db.close();
    try testing.expectEqual(@as(u64, 3), db.lastSeq());
}

test "recovery refuses a damaged record that has acknowledged data after it" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    {
        const db = try Db.open(testing.allocator, .{ .path = tmp.path, .undirected = false });
        defer db.close();
        try db.putEdge(1, 2, 1);
        try db.putEdge(3, 4, 1);
        try db.putEdge(5, 6, 1);
    }
    const wal_path = try tmp.walPath();
    defer testing.allocator.free(wal_path);
    {
        const f = try sys.File.open(wal_path, .read);
        const bytes = try f.readAll(testing.allocator);
        f.close();
        defer testing.allocator.free(bytes);
        bytes[12 + 4] ^= 0xff; // inside the first record's body
        const w = try sys.File.open(wal_path, .read_write_create);
        defer w.close();
        try w.truncate(0);
        try w.writeAll(bytes);
    }
    try testing.expectError(error.Corrupt, Db.open(testing.allocator, .{ .path = tmp.path, .undirected = false }));
}

test "a second open of the same directory fails while the first is live" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, .{ .path = tmp.path });
    try testing.expectError(error.Locked, Db.open(testing.allocator, .{ .path = tmp.path }));
    db.close();
    const again = try Db.open(testing.allocator, .{ .path = tmp.path });
    again.close();
}

test "sync_mode none still recovers after a clean close" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    {
        const db = try Db.open(testing.allocator, .{ .path = tmp.path, .sync_mode = .none });
        defer db.close();
        try db.putEdge(1, 2, 1);
        try db.sync();
    }
    const db = try Db.open(testing.allocator, .{ .path = tmp.path });
    defer db.close();
    try testing.expectEqual(@as(u64, 2), db.lastSeq());
}

test "readers scan consistent snapshots while a writer appends" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, .{ .path = tmp.path, .sync_mode = .none, .undirected = false });
    defer db.close();

    const Reader = struct {
        fn run(d: *Db, stop: *std.atomic.Value(bool), bad: *std.atomic.Value(u32)) void {
            while (!stop.load(.acquire)) {
                const s = d.snapshot() catch return;
                defer s.release();
                var it = s.neighbors(testing.allocator, 1) catch return;
                defer it.deinit();
                // Writer inserts edges 1->1000, 1->1001, ... in order, so a
                // snapshot must see a gapless prefix of them.
                var expect: u64 = 1000;
                while (it.next()) |e| {
                    if (e.dst != expect) bad.store(1, .release);
                    expect += 1;
                }
                if (expect - 1000 > s.seq) bad.store(1, .release);
            }
        }
    };
    var stop: std.atomic.Value(bool) = .init(false);
    var bad: std.atomic.Value(u32) = .init(0);
    var threads: [3]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Reader.run, .{ db, &stop, &bad });
    for (0..3000) |i| try db.putEdge(1, 1000 + i, 1);
    stop.store(true, .release);
    for (threads) |t| t.join();
    try testing.expectEqual(@as(u32, 0), bad.load(.acquire));
}

// ---- phase 2: segments and flush ----------------------------------------------

fn countFiles(dir: [:0]const u8, suffix: []const u8) !usize {
    const names = try sys.listDir(testing.allocator, dir);
    defer {
        for (names) |n| testing.allocator.free(n);
        testing.allocator.free(names);
    }
    var n: usize = 0;
    for (names) |name| {
        if (std.mem.endsWith(u8, name, suffix)) n += 1;
    }
    return n;
}

/// Path of the single file in `dir` ending in `suffix`.
fn onlyFile(dir: [:0]const u8, suffix: []const u8) ![:0]u8 {
    const names = try sys.listDir(testing.allocator, dir);
    defer {
        for (names) |n| testing.allocator.free(n);
        testing.allocator.free(names);
    }
    var found: ?[:0]u8 = null;
    errdefer if (found) |f| testing.allocator.free(f);
    for (names) |name| {
        if (!std.mem.endsWith(u8, name, suffix)) continue;
        try testing.expect(found == null);
        found = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/{s}", .{ dir, name }, 0);
    }
    return found orelse error.FileNotFound;
}

test "flush writes an L0 segment; reads merge segment and MemGraph; reopen keeps both" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    var got: std.ArrayList(sp.Edge) = .empty;
    defer got.deinit(testing.allocator);
    {
        const db = try Db.open(testing.allocator, .{ .path = tmp.path, .undirected = false });
        defer db.close();
        try db.putEdge(1, 2, 1);
        try db.putEdge(1, 3, 1);
        try db.flush();
        try testing.expectEqual(@as(usize, 1), try countFiles(tmp.path, ".seg"));
        try testing.expectEqual(@as(usize, 1), try countFiles(tmp.path, ".log")); // old log deleted
        try db.delEdge(1, 2); // tombstone in MemGraph hides the segment's edge
        try db.putEdge(1, 4, 1);
        const s = try db.snapshot();
        defer s.release();
        try collect(s, 1, &got);
        try testing.expectEqual(@as(usize, 2), got.items.len);
        try testing.expectEqual(@as(u64, 3), got.items[0].dst);
        try testing.expectEqual(@as(u64, 4), got.items[1].dst);
        try db.flush();
        try db.flush(); // empty MemGraph: no-op
        try testing.expectEqual(@as(usize, 2), try countFiles(tmp.path, ".seg"));
    }
    const db = try Db.open(testing.allocator, .{ .path = tmp.path, .undirected = false });
    defer db.close();
    try testing.expectEqual(@as(u64, 4), db.lastSeq());
    const s = try db.snapshot();
    defer s.release();
    try collect(s, 1, &got);
    try testing.expectEqual(@as(usize, 2), got.items.len);
    try db.putEdge(1, 9, 1);
    try testing.expectEqual(@as(u64, 5), db.lastSeq());
}

test "a snapshot taken before a flush keeps reading the same graph" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, .{ .path = tmp.path, .undirected = false });
    defer db.close();
    var got: std.ArrayList(sp.Edge) = .empty;
    defer got.deinit(testing.allocator);

    try db.putEdge(1, 2, 1);
    const before = try db.snapshot();
    defer before.release();
    try db.flush();
    try db.putEdge(1, 3, 1);
    try db.flush();
    try db.delEdge(1, 2);
    try db.flush();
    try collect(before, 1, &got);
    try testing.expectEqual(@as(usize, 1), got.items.len);
    try testing.expectEqual(@as(u64, 2), got.items[0].dst);
    const after = try db.snapshot();
    defer after.release();
    try collect(after, 1, &got);
    try testing.expectEqual(@as(usize, 1), got.items.len);
    try testing.expectEqual(@as(u64, 3), got.items[0].dst);
}

test "automatic flush at the MemGraph limit" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, .{
        .path = tmp.path,
        .undirected = false,
        .sync_mode = .none,
        .memgraph_limit_bytes = 24 * 100,
        .background_compaction = false,
    });
    defer db.close();
    for (0..1000) |i| try db.putEdge(i % 10, i, 1);
    try db.waitForFlush();
    const n = try countFiles(tmp.path, ".seg");
    try testing.expect(n >= 9 and n <= 10);
    try testing.expectEqual(@as(usize, 1), try countFiles(tmp.path, ".log"));
}

test "recovery after a crash between writing a segment and deleting its log" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    // Keep a copy of the log as it was before the flush.
    const log1 = try tmp.walPath();
    defer testing.allocator.free(log1);
    var saved: []u8 = undefined;
    {
        const db = try Db.open(testing.allocator, .{ .path = tmp.path, .undirected = false });
        defer db.close();
        try db.putEdge(1, 2, 1);
        try db.putEdge(1, 3, 1);
        {
            const f = try sys.File.open(log1, .read);
            defer f.close();
            saved = try f.readAll(testing.allocator);
        }
        try db.flush();
        try db.putEdge(1, 4, 1);
    }
    defer testing.allocator.free(saved);
    // Resurrect the old log, as if the unlink never happened.
    {
        const f = try sys.File.open(log1, .read_write_create);
        defer f.close();
        try f.truncate(0);
        try f.writeAll(saved);
    }
    // Also leave a half-written segment behind.
    {
        const p = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/000099.seg.tmp", .{tmp.path}, 0);
        defer testing.allocator.free(p);
        const f = try sys.File.open(p, .read_write_create);
        defer f.close();
        try f.writeAll("junk");
    }
    const db = try Db.open(testing.allocator, .{ .path = tmp.path, .undirected = false });
    defer db.close();
    try testing.expectEqual(@as(u64, 3), db.lastSeq());
    try testing.expectEqual(@as(usize, 0), try countFiles(tmp.path, ".tmp"));
    try testing.expectEqual(@as(usize, 1), try countFiles(tmp.path, ".log")); // stale log removed
    var got: std.ArrayList(sp.Edge) = .empty;
    defer got.deinit(testing.allocator);
    const s = try db.snapshot();
    defer s.release();
    try collect(s, 1, &got);
    try testing.expectEqual(@as(usize, 3), got.items.len); // 2, 3 once each, plus 4
}

test "open refuses a corrupt segment" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    {
        const db = try Db.open(testing.allocator, .{ .path = tmp.path });
        defer db.close();
        try db.putEdge(1, 2, 1);
        try db.flush();
    }
    const p = try onlyFile(tmp.path, ".seg");
    defer testing.allocator.free(p);
    {
        const f = try sys.File.open(p, .read);
        const bytes = try f.readAll(testing.allocator);
        f.close();
        defer testing.allocator.free(bytes);
        bytes[bytes.len - 20] ^= 1;
        const w = try sys.File.open(p, .read_write_create);
        defer w.close();
        try w.truncate(0);
        try w.writeAll(bytes);
    }
    try testing.expectError(error.Corrupt, Db.open(testing.allocator, .{ .path = tmp.path }));
}

/// Dense reference model: weight of edge (v, d), NaN when absent.
const model_v = 300;
const model_d = 300;
const Model = struct {
    w: []f32,

    fn init() !Model {
        const w = try testing.allocator.alloc(f32, model_v * model_d);
        @memset(w, std.math.nan(f32));
        return .{ .w = w };
    }
    fn deinit(m: Model) void {
        testing.allocator.free(m.w);
    }
    fn clone(m: Model) !Model {
        return .{ .w = try testing.allocator.dupe(f32, m.w) };
    }
    fn row(m: Model, v: usize) []f32 {
        return m.w[v * model_d ..][0..model_d];
    }
};

fn expectMatches(seed: u64, at_op: usize, label: []const u8, snap: *sp.Snapshot, m: Model) !void {
    for (0..model_v) |v| {
        var it = try snap.neighbors(testing.allocator, v);
        defer it.deinit();
        const r = m.row(v);
        var d: usize = 0;
        while (it.next()) |e| {
            while (d < e.dst and std.math.isNan(r[d])) d += 1;
            if (e.dst >= model_d or d != e.dst or r[d] != e.weight) {
                std.debug.print("MISMATCH seed={d} op={d} {s} vertex={d}: store has dst={d} w={d}, model expects dst={d}\n", .{ seed, at_op, label, v, e.dst, e.weight, d });
                return error.ModelMismatch;
            }
            d += 1;
        }
        while (d < model_d) : (d += 1) {
            if (!std.math.isNan(r[d])) {
                std.debug.print("MISMATCH seed={d} op={d} {s} vertex={d}: store is missing dst={d}\n", .{ seed, at_op, label, v, d });
                return error.ModelMismatch;
            }
        }
    }
}

test "model: 1M random ops, flushes, background compaction, frozen snapshots and reopens match the reference" {
    try runModel(0x5eed_2, 1_000_000, true);
}

test "model: random manual compactions at every level never resurrect a delete" {
    try runModel(0x5eed_3, 600_000, false);
}

test "model: tiered with background compaction" {
    try runModelStyle(0x5eed_4, 800_000, true, .tiered);
}

test "model: tiered, compactions at random points and levels" {
    try runModelStyle(0x5eed_5, 800_000, false, .tiered);
}

/// Small levels so data really descends: ~1 MiB flushes, L1 holds 1 MiB, each
/// level 3x the one above, output segments of 128 KiB (many per level, so the
/// disjoint-range handling is exercised too).
fn compactingOptions(path: [:0]const u8, bg: bool) sp.Options {
    return .{
        .path = path,
        .undirected = false,
        .sync_mode = .none,
        .memgraph_limit_bytes = 1 << 20,
        .l0_compaction_trigger = 3,
        .l0_stop_trigger = 6,
        .size_ratio = 3,
        .level1_bytes = 1 << 20,
        .target_segment_bytes = 128 << 10,
        .background_compaction = bg,
    };
}

fn runModel(seed: u64, total_ops: usize, bg: bool) !void {
    try runModelStyle(seed, total_ops, bg, .leveled);
}

fn runModelStyle(seed: u64, total_ops: usize, bg: bool, style: sp.CompactionStyle) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();

    var tmp = try TmpDir.init();
    defer tmp.deinit();
    var opts = compactingOptions(tmp.path, bg);
    opts.compaction_style = style;
    var db = try Db.open(testing.allocator, opts);
    var open = true;
    defer if (open) db.close();

    var model = try Model.init();
    defer model.deinit();

    const Frozen = struct { snap: *sp.Snapshot, model: Model };
    var frozen: std.ArrayList(Frozen) = .empty;
    defer {
        for (frozen.items) |f| {
            f.snap.release();
            f.model.deinit();
        }
        frozen.deinit(testing.allocator);
    }

    var b: sp.Batch = .{};
    defer b.deinit(testing.allocator);

    var done: usize = 0;
    var next_check: usize = 100_000;
    var reopens: usize = 0;
    while (done < total_ops) {
        // A batch of 1..8 ops, applied to the store and the model together.
        b.clear();
        const n = 1 + rnd.uintLessThan(usize, 8);
        for (0..n) |k| {
            const v = rnd.uintLessThan(usize, model_v);
            const d = rnd.uintLessThan(usize, model_d);
            if (rnd.uintLessThan(u8, 10) < 3) { // 30% deletes
                try b.del(testing.allocator, v, d);
                model.row(v)[d] = std.math.nan(f32);
            } else {
                const w: f32 = @floatFromInt(done + k + 1);
                try b.put(testing.allocator, v, d, w);
                model.row(v)[d] = w;
            }
        }
        try db.write(&b);
        done += n;

        if (rnd.uintLessThan(u32, 40_000) == 0) try db.flush();
        if (!bg and rnd.uintLessThan(u32, 3_000) == 0) {
            // Deterministic compactions at random points, any level, with
            // frozen snapshots outstanding.
            if (rnd.boolean()) {
                _ = try db.compactOnce();
            } else {
                _ = try db.compactLevel(rnd.uintLessThan(u16, 4));
            }
        }

        if (done >= next_check) {
            next_check += 100_000;
            const s = try db.snapshot();
            try expectMatches(seed, done, "fresh", s, model);
            try frozen.append(testing.allocator, .{ .snap = s, .model = try model.clone() });
            // Every earlier snapshot must still show the graph it was taken on.
            for (frozen.items) |f| try expectMatches(seed, done, "frozen", f.snap, f.model);

            if (frozen.items.len % 3 == 0) { // reopen: recover from segments + log
                for (frozen.items) |f| {
                    f.snap.release();
                    f.model.deinit();
                }
                frozen.clearRetainingCapacity();
                db.close();
                open = false;
                db = try Db.open(testing.allocator, opts);
                open = true;
                reopens += 1;
                const s2 = try db.snapshot();
                defer s2.release();
                try expectMatches(seed, done, "after reopen", s2, model);
            }
        }
    }
    try testing.expect(reopens >= 2);
    try db.waitForCompaction();
    {
        const last = try db.snapshot();
        defer last.release();
        try expectMatches(seed, done, "final", last, model);
    }

    // Compaction really ran and really collected garbage.
    const st = db.stats();
    var compactions: u64 = 0;
    for (st.levels[1..]) |l| compactions += l.compactions;
    // Counters restart at each reopen, and tiered compacts far less often.
    try testing.expect(compactions >= @as(u64, if (style == .tiered) 1 else 5));
    try testing.expect(st.dropped_records > 0);
    var deep: usize = 0;
    for (st.levels[1..]) |l| deep += l.files;
    try testing.expect(deep > 0);
    try testing.expect(db.levelFileCounts()[0] < 3 or !bg); // L0 stays bounded

    // Release the frozen snapshots: every obsolete file must then be gone, so
    // the directory holds exactly the segments of the current layout.
    for (frozen.items) |f| {
        f.snap.release();
        f.model.deinit();
    }
    frozen.clearRetainingCapacity();
    try testing.expectEqual(db.segmentCount(), try countFiles(tmp.path, ".seg"));

    // And the compacted layout survives a reopen.
    db.close();
    open = false;
    db = try Db.open(testing.allocator, opts);
    open = true;
    try db.waitForCompaction();
    const again = try db.snapshot();
    defer again.release();
    try expectMatches(seed, done, "final after reopen", again, model);
}

// ---- phase 3: versions, manifest, recovery -----------------------------------

fn collectDsts(snap: *sp.Snapshot, v: u64) !usize {
    var it = try snap.neighbors(testing.allocator, v);
    defer it.deinit();
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

fn manualOpts(path: [:0]const u8) sp.Options {
    return .{
        .path = path,
        .undirected = false,
        .background_compaction = false,
        .target_segment_bytes = 1 << 20,
    };
}

fn overwriteFile(path: [*:0]const u8, bytes: []const u8) !void {
    const w = try sys.File.open(path, .read_write_create);
    defer w.close();
    try w.truncate(0);
    try w.writeAll(bytes);
}

test "the level layout survives a reopen, including compacted levels" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    var layout: [sp.max_levels]usize = undefined;
    {
        const db = try Db.open(testing.allocator, manualOpts(tmp.path));
        defer db.close();
        for (0..3) |round| {
            for (0..50) |i| try db.putEdge(i, 1000 + round, 1);
            try db.flush();
        }
        try testing.expect(try db.compactLevel(0)); // L0 -> L1
        for (0..50) |i| try db.putEdge(i, 2000, 1);
        try db.flush(); // a fresh L0 on top of L1
        layout = db.levelFileCounts();
        try testing.expectEqual(@as(usize, 1), layout[0]);
        try testing.expect(layout[1] >= 1);
    }
    const db = try Db.open(testing.allocator, manualOpts(tmp.path));
    defer db.close();
    try testing.expectEqualSlices(usize, &layout, &db.levelFileCounts());
    const s = try db.snapshot();
    defer s.release();
    try testing.expectEqual(@as(usize, 4), try collectDsts(s, 7));
    try testing.expectEqual(@as(u64, 200), db.lastSeq());
    // New files must not reuse numbers of files that exist.
    try db.putEdge(7, 9999, 1);
    try db.flush();
    try testing.expectEqual(layout[0] + 1, db.levelFileCounts()[0]);
}

test "last_seq survives when every log is gone and compaction dropped the newest records" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    {
        const db = try Db.open(testing.allocator, manualOpts(tmp.path));
        defer db.close();
        try db.putEdge(1, 2, 1); // seq 1
        try db.flush();
        try db.delEdge(1, 2); // seq 2
        try db.flush();
        // Nothing lies below L1, so this merge is the bottom: the tombstone and
        // the put cancel out, and no segment records seq 2 any more.
        try testing.expect(try db.compactLevel(0));
        try testing.expectEqual(@as(usize, 0), db.segmentCount());
    }
    const db = try Db.open(testing.allocator, manualOpts(tmp.path));
    defer db.close();
    try testing.expectEqual(@as(u64, 2), db.lastSeq()); // from the manifest, not a segment
    try db.putEdge(1, 3, 1);
    try testing.expectEqual(@as(u64, 3), db.lastSeq()); // no sequence number reused
}

test "a tombstone is kept above the bottom level so a deleted edge stays deleted" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, manualOpts(tmp.path));
    defer db.close();

    try db.putEdge(1, 2, 1);
    try db.flush();
    try testing.expect(try db.compactLevel(0)); // put now at L1
    try testing.expect(try db.compactLevel(1)); // ... and at L2, the deepest level so far
    try db.delEdge(1, 2);
    try db.flush();
    try testing.expect(try db.compactLevel(0)); // tombstone to L1; the put still sits below it
    {
        const s = try db.snapshot();
        defer s.release();
        try testing.expectEqual(@as(usize, 0), try collectDsts(s, 1));
    }
    // L1 holds only the tombstone; had it been dropped, the put in L2 would be back.
    const counts = db.levelFileCounts();
    try testing.expectEqual(@as(usize, 1), counts[1]);
    try testing.expectEqual(@as(usize, 1), counts[2]);
    // Merging into L2 meets the put; now both can go.
    try testing.expect(try db.compactLevel(1));
    try testing.expectEqual(@as(usize, 0), db.segmentCount());
    const s = try db.snapshot();
    defer s.release();
    try testing.expectEqual(@as(usize, 0), try collectDsts(s, 1));
}

test "an old snapshot keeps its versions through compaction; releasing it lets them go" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, manualOpts(tmp.path));
    defer db.close();

    try db.putEdge(1, 2, 1);
    try db.putEdge(1, 3, 1);
    try db.flush();
    const old = try db.snapshot(); // sees 1->2 and 1->3
    try db.delEdge(1, 2);
    try db.putEdge(1, 3, 5); // overwrite
    try db.flush();
    try testing.expect(try db.compactLevel(0));
    try testing.expect(try db.compactLevel(1));
    try testing.expect(try db.compactLevel(2));

    // The old snapshot still sees what it saw, from the pinned Version.
    var got: std.ArrayList(sp.Edge) = .empty;
    defer got.deinit(testing.allocator);
    try collect(old, 1, &got);
    try testing.expectEqual(@as(usize, 2), got.items.len);
    try testing.expectEqual(@as(f32, 1), got.items[1].weight);

    // New snapshots see the current graph, though the old version of 1->3 must
    // survive in the files for `old`'s sake only if a snapshot could need it.
    const fresh = try db.snapshot();
    defer fresh.release();
    try collect(fresh, 1, &got);
    try testing.expectEqual(@as(usize, 1), got.items.len);
    try testing.expectEqual(@as(f32, 5), got.items[0].weight);

    // The pre-compaction files are pinned by `old`, so they are still on disk.
    try testing.expect(try countFiles(tmp.path, ".seg") > db.segmentCount());
    old.release();
    try testing.expectEqual(db.segmentCount(), try countFiles(tmp.path, ".seg"));
    try collect(fresh, 1, &got);
    try testing.expectEqual(@as(usize, 1), got.items.len);
}

test "output segments split at vertex boundaries and a hub gets a segment of its own" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    var opts = manualOpts(tmp.path);
    opts.target_segment_bytes = 24 * 50; // ~50 records per output
    const db = try Db.open(testing.allocator, opts);
    defer db.close();

    for (0..40) |v| for (0..5) |d| try db.putEdge(v * 10, d, 1); // 40 vertices, 5 edges each
    for (0..300) |d| try db.putEdge(1000, d, 1); // one hub, 300 edges, over the target
    for (0..20) |v| try db.putEdge(2000 + v, 1, 1);
    try db.flush();
    try testing.expect(try db.compactLevel(0));
    const counts = db.levelFileCounts();
    try testing.expectEqual(@as(usize, 0), counts[0]);
    try testing.expect(counts[1] >= 5); // split into many segments

    // Every vertex is still readable, which exercises the per-level binary search
    // over disjoint segments (and fails if two segments shared a vertex).
    const s = try db.snapshot();
    defer s.release();
    for (0..40) |v| try testing.expectEqual(@as(usize, 5), try collectDsts(s, v * 10));
    try testing.expectEqual(@as(usize, 300), try collectDsts(s, 1000));
    for (0..20) |v| try testing.expectEqual(@as(usize, 1), try collectDsts(s, 2000 + v));
    try testing.expectEqual(@as(usize, 0), try collectDsts(s, 5)); // a gap between segments
}

test "recovery drops orphan segments left by a flush or compaction that never reached the manifest" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    {
        const db = try Db.open(testing.allocator, manualOpts(tmp.path));
        defer db.close();
        try db.putEdge(1, 2, 1);
        try db.flush();
    }
    // A valid segment file that no manifest lists: copy the real one under a new number.
    const real = try onlyFile(tmp.path, ".seg");
    defer testing.allocator.free(real);
    const orphan = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/000900.seg", .{tmp.path}, 0);
    defer testing.allocator.free(orphan);
    {
        const f = try sys.File.open(real, .read);
        defer f.close();
        const bytes = try f.readAll(testing.allocator);
        defer testing.allocator.free(bytes);
        try overwriteFile(orphan, bytes);
    }
    try testing.expectEqual(@as(usize, 2), try countFiles(tmp.path, ".seg"));
    const db = try Db.open(testing.allocator, manualOpts(tmp.path));
    defer db.close();
    try testing.expectEqual(@as(usize, 1), try countFiles(tmp.path, ".seg"));
    try testing.expectEqual(@as(usize, 1), db.segmentCount());
    try db.putEdge(5, 6, 1);
    try db.flush(); // file numbers continue past the orphan's
    try testing.expectEqual(@as(usize, 2), try countFiles(tmp.path, ".seg"));
}

test "a manifest edit that was torn mid-append is ignored; damage elsewhere is refused" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    {
        const db = try Db.open(testing.allocator, manualOpts(tmp.path));
        defer db.close();
        try db.putEdge(1, 2, 1);
        try db.flush();
        try db.putEdge(1, 3, 1);
        try db.flush();
    }
    // Find the live manifest through CURRENT.
    const cur = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/CURRENT", .{tmp.path}, 0);
    defer testing.allocator.free(cur);
    const cf = try sys.File.open(cur, .read);
    const name = try cf.readAll(testing.allocator);
    cf.close();
    defer testing.allocator.free(name);
    const manifest = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/{s}", .{ tmp.path, std.mem.trimEnd(u8, name, "\n") }, 0);
    defer testing.allocator.free(manifest);
    const mf = try sys.File.open(manifest, .read);
    const good = try mf.readAll(testing.allocator);
    mf.close();
    defer testing.allocator.free(good);

    // Append half of a record: the crash hit while the edit was being written.
    {
        const torn = try testing.allocator.alloc(u8, good.len + 11);
        defer testing.allocator.free(torn);
        @memcpy(torn[0..good.len], good);
        std.mem.writeInt(u32, torn[good.len..][0..4], 0xdeadbeef, .little);
        std.mem.writeInt(u32, torn[good.len + 4 ..][0..4], 400, .little); // claims more than is there
        @memset(torn[good.len + 8 ..], 7);
        try overwriteFile(manifest, torn);
        const db = try Db.open(testing.allocator, manualOpts(tmp.path));
        defer db.close();
        try testing.expectEqual(@as(usize, 2), db.segmentCount());
        try testing.expectEqual(@as(u64, 2), db.lastSeq());
    }
    // Opening wrote a new manifest; damage the first record of that one: the
    // records after it were acknowledged, so this is corruption, not a torn tail.
    {
        const cf2 = try sys.File.open(cur, .read);
        const name2 = try cf2.readAll(testing.allocator);
        cf2.close();
        defer testing.allocator.free(name2);
        const m2 = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/{s}", .{ tmp.path, std.mem.trimEnd(u8, name2, "\n") }, 0);
        defer testing.allocator.free(m2);
        const f = try sys.File.open(m2, .read);
        const bytes = try f.readAll(testing.allocator);
        f.close();
        defer testing.allocator.free(bytes);
        // Append a valid-looking second record so the first has a successor.
        const ext = try testing.allocator.alloc(u8, bytes.len + 8);
        defer testing.allocator.free(ext);
        @memcpy(ext[0..bytes.len], bytes);
        @memset(ext[bytes.len..], 0); // len 0, crc 0 == crc32c("")
        ext[8 + 8 + 2] ^= 0x40; // flip a payload byte of the first record
        try overwriteFile(m2, ext);
        try testing.expectError(error.Corrupt, Db.open(testing.allocator, manualOpts(tmp.path)));
    }
}

test "open refuses a layout whose segment file has gone missing, or CURRENT naming nothing" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    {
        const db = try Db.open(testing.allocator, manualOpts(tmp.path));
        defer db.close();
        try db.putEdge(1, 2, 1);
        try db.flush();
    }
    const seg = try onlyFile(tmp.path, ".seg");
    defer testing.allocator.free(seg);
    const saved = blk: {
        const f = try sys.File.open(seg, .read);
        defer f.close();
        break :blk try f.readAll(testing.allocator);
    };
    defer testing.allocator.free(saved);
    sys.unlink(seg);
    try testing.expectError(error.Corrupt, Db.open(testing.allocator, manualOpts(tmp.path)));
    try overwriteFile(seg, saved);

    const cur = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/CURRENT", .{tmp.path}, 0);
    defer testing.allocator.free(cur);
    try overwriteFile(cur, "MANIFEST-424242\n");
    try testing.expectError(error.Corrupt, Db.open(testing.allocator, manualOpts(tmp.path)));
    try overwriteFile(cur, "garbage");
    try testing.expectError(error.Corrupt, Db.open(testing.allocator, manualOpts(tmp.path)));
}

test "invalid compaction options are rejected" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    var o = manualOpts(tmp.path);
    o.l0_stop_trigger = o.l0_compaction_trigger; // a stalled writer could never be released
    try testing.expectError(error.InvalidArgument, Db.open(testing.allocator, o));
    o = manualOpts(tmp.path);
    o.size_ratio = 1;
    try testing.expectError(error.InvalidArgument, Db.open(testing.allocator, o));
}

// ---- phase 4: background compaction and stalls ---------------------------------

test "background compaction keeps L0 bounded and writers stall when it falls behind" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, .{
        .path = tmp.path,
        .undirected = false,
        .sync_mode = .none,
        .memgraph_limit_bytes = 24 * 200,
        .l0_compaction_trigger = 2,
        .l0_stop_trigger = 3, // tight, so the writer outruns the compactor
        .size_ratio = 4,
        .level1_bytes = 24 * 2000,
        .target_segment_bytes = 24 * 400,
    });
    defer db.close();
    for (0..20_000) |i| {
        try db.putEdge(i % 97, i, 1);
        // Never more than stop_trigger files at once.
        if (i % 500 == 0) try testing.expect(db.levelFileCounts()[0] <= 3);
    }
    try db.waitForCompaction();
    const st = db.stats();
    try testing.expect(st.flushes > 50);
    try testing.expect(st.stalls > 0 and st.stall_ns > 0);
    try testing.expect(db.levelFileCounts()[0] < 2);
    var deep: usize = 0;
    for (db.levelFileCounts()[2..]) |n| deep += n;
    try testing.expect(deep > 0); // data descended past L1

    const s = try db.snapshot();
    defer s.release();
    for (0..97) |v| {
        var want: usize = 0;
        var i = v;
        while (i < 20_000) : (i += 97) want += 1;
        try testing.expectEqual(want, try collectDsts(s, v));
    }
}

test "reads stay consistent while the writer flushes and compaction replaces segments" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, .{
        .path = tmp.path,
        .undirected = false,
        .sync_mode = .none,
        .memgraph_limit_bytes = 24 * 100,
        .l0_compaction_trigger = 2,
        .l0_stop_trigger = 6,
        .size_ratio = 3,
        .level1_bytes = 24 * 800,
        .target_segment_bytes = 24 * 150,
    });
    defer db.close();

    const Reader = struct {
        fn run(d: *Db, stop: *std.atomic.Value(bool), bad: *std.atomic.Value(u32)) void {
            while (!stop.load(.acquire)) {
                const s = d.snapshot() catch return;
                defer s.release();
                // The writer puts 1->1000, 1->1001, ... in order, so every
                // snapshot must see a gapless prefix, wherever the data lives.
                var it = s.neighbors(testing.allocator, 1) catch return;
                defer it.deinit();
                var expect: u64 = 1000;
                while (it.next()) |e| {
                    if (e.dst != expect) bad.store(1, .release);
                    expect += 1;
                }
                if (expect - 1000 != s.seq) bad.store(1, .release);
            }
        }
    };
    var stop: std.atomic.Value(bool) = .init(false);
    var bad: std.atomic.Value(u32) = .init(0);
    var threads: [3]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Reader.run, .{ db, &stop, &bad });
    for (0..4000) |i| try db.putEdge(1, 1000 + i, 1);
    try db.waitForCompaction();
    stop.store(true, .release);
    for (threads) |t| t.join();
    try testing.expectEqual(@as(u32, 0), bad.load(.acquire));
    try testing.expect(db.stats().flushes > 20);
    var compactions: u64 = 0;
    for (db.stats().levels[1..]) |l| compactions += l.compactions;
    try testing.expect(compactions > 5);
}

test "an upgraded database from before manifests opens as an all-L0 layout" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    {
        const db = try Db.open(testing.allocator, manualOpts(tmp.path));
        defer db.close();
        try db.putEdge(1, 2, 1);
        try db.flush();
        try db.putEdge(1, 3, 1);
        try db.flush();
    }
    // Phase 2 directories had no CURRENT and no MANIFEST.
    const cur = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/CURRENT", .{tmp.path}, 0);
    defer testing.allocator.free(cur);
    sys.unlink(cur);
    const mani = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/MANIFEST-000002", .{tmp.path}, 0);
    defer testing.allocator.free(mani);
    sys.unlink(mani);
    const db = try Db.open(testing.allocator, manualOpts(tmp.path));
    defer db.close();
    try testing.expectEqual(@as(usize, 2), db.levelFileCounts()[0]);
    try testing.expectEqual(@as(u64, 2), db.lastSeq());
    const s = try db.snapshot();
    defer s.release();
    try testing.expectEqual(@as(usize, 2), try collectDsts(s, 1));
}

// ---- background flush ---------------------------------------------------------

test "a scan during a flush sees the frozen MemGraph, and snapshots keep it after the flush" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, .{
        .path = tmp.path,
        .undirected = false,
        .sync_mode = .none,
        .memgraph_limit_bytes = 24 * 50,
        .background_compaction = false,
    });
    defer db.close();

    // Each snapshot may land before, during or after any flush; every one must
    // see exactly the edges acknowledged before it, whichever source holds them.
    var snaps: std.ArrayList(*sp.Snapshot) = .empty;
    defer {
        for (snaps.items) |s| s.release();
        snaps.deinit(testing.allocator);
    }
    for (0..2_000) |i| {
        try db.putEdge(7, i, @floatFromInt(i));
        if (i % 97 == 0) try snaps.append(testing.allocator, try db.snapshot());
    }
    try db.waitForFlush();
    for (snaps.items, 0..) |s, k| {
        try testing.expectEqual(k * 97 + 1, try collectDsts(s, 7));
    }
}

test "a kill between rotation and install replays both logs in order" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    // Stop the world at the on-disk state a crash mid-flush leaves: two live
    // logs, and a newer version of an edge in the second.
    const opts: sp.Options = .{ .path = tmp.path, .undirected = false };
    var first: []u8 = undefined;
    const log1 = try tmp.walPath();
    defer testing.allocator.free(log1);
    {
        const db = try Db.open(testing.allocator, opts);
        defer db.close();
        try db.putEdge(1, 2, 1.0);
        try db.putEdge(1, 3, 1.0);
        const f = try sys.File.open(log1, .read);
        defer f.close();
        first = try f.readAll(testing.allocator);
    }
    defer testing.allocator.free(first);
    const log2 = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/wal-000099.log", .{tmp.path}, 0);
    defer testing.allocator.free(log2);
    {
        const wal = @import("wal.zig");
        const ops = [_]@import("batch.zig").Op{.{ .kind = .put, .src = 1, .dst = 2, .weight = 9.0 }};
        var w = try wal.Wal.create(testing.allocator, log2, tmp.path);
        defer w.close();
        try w.append(3, &ops);
        try w.sync();
    }
    const db = try Db.open(testing.allocator, opts);
    defer db.close();
    try testing.expectEqual(@as(u64, 3), db.lastSeq());
    const s = try db.snapshot();
    defer s.release();
    var got: std.ArrayList(sp.Edge) = .empty;
    defer got.deinit(testing.allocator);
    try collect(s, 1, &got);
    try testing.expectEqual(@as(usize, 2), got.items.len);
    try testing.expectEqual(@as(f32, 9.0), got.items[0].weight);

    // The older log is released by the next flush, and writes keep going.
    try db.putEdge(1, 4, 1.0);
    try db.flush();
    try testing.expectEqual(@as(usize, 1), try countFiles(tmp.path, ".log"));
}

test "close drains a frozen MemGraph into L0" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const opts: sp.Options = .{
        .path = tmp.path,
        .undirected = false,
        .sync_mode = .none,
        .memgraph_limit_bytes = 24 * 100,
        .background_compaction = false,
    };
    {
        const db = try Db.open(testing.allocator, opts);
        defer db.close();
        for (0..101) |i| try db.putEdge(1, i, 1);
        try db.putEdge(1, 101, 1); // the write that freezes the first 101
    }
    try testing.expectEqual(@as(usize, 1), try countFiles(tmp.path, ".seg"));
    const db = try Db.open(testing.allocator, opts);
    defer db.close();
    const s = try db.snapshot();
    defer s.release();
    try testing.expectEqual(@as(usize, 102), try collectDsts(s, 1));
}

// ---- tiered compaction and metrics ---------------------------------------------

fn tieredOpts(path: [:0]const u8) sp.Options {
    return .{
        .path = path,
        .undirected = false,
        .sync_mode = .none,
        .background_compaction = false,
        .compaction_style = .tiered,
        .l0_compaction_trigger = 2,
        .size_ratio = 2,
    };
}

test "tiered: a delete survives until no older run below can hold the edge" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, tieredOpts(tmp.path));
    defer db.close();
    // An old run of the edge in L1, then a delete that compacts down onto the
    // same level. Dropping the tombstone there would bring the edge back.
    try db.putEdge(1, 2, 1);
    try db.flush();
    _ = try db.compactLevel(0);
    try db.delEdge(1, 2);
    try db.putEdge(1, 3, 1);
    try db.flush();
    _ = try db.compactLevel(0);
    try testing.expectEqual(@as(usize, 2), db.levelFileCounts()[1]);
    {
        const s = try db.snapshot();
        defer s.release();
        try testing.expectEqual(@as(usize, 1), try collectDsts(s, 1));
    }
    // Merged together at the bottom, the tombstone and the old edge both go.
    _ = try db.compactLevel(1);
    try testing.expectEqual(@as(usize, 1), db.levelFileCounts()[2]);
    const s = try db.snapshot();
    defer s.release();
    try testing.expectEqual(@as(usize, 1), try collectDsts(s, 1));
    try testing.expect(db.stats().dropped_records >= 2);
}

test "tiered: a full level merges into one run, leaving the runs below alone" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, tieredOpts(tmp.path));
    defer db.close();
    for (0..5) |round| {
        for (0..3) |i| try db.putEdge(round * 10 + i, i, 1);
        try db.flush();
        while (try db.compactOnce()) {}
    }
    const c = db.levelFileCounts();
    for (c[0..]) |n| try testing.expect(n <= 2);
    const s = try db.snapshot();
    defer s.release();
    for (0..5) |round| try testing.expectEqual(@as(usize, 1), try collectDsts(s, round * 10));
}

test "a tiered store reopens, but will not open as leveled" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    {
        const db = try Db.open(testing.allocator, tieredOpts(tmp.path));
        defer db.close();
        for (0..2) |_| {
            try db.putEdge(1, 2, 1);
            try db.flush();
            _ = try db.compactLevel(0);
        }
        try testing.expectEqual(@as(usize, 2), db.levelFileCounts()[1]);
    }
    {
        const db = try Db.open(testing.allocator, tieredOpts(tmp.path));
        defer db.close();
        try testing.expectEqual(@as(usize, 2), db.levelFileCounts()[1]);
    }
    var leveled = tieredOpts(tmp.path);
    leveled.compaction_style = .leveled;
    try testing.expectError(error.InvalidArgument, Db.open(testing.allocator, leveled));
}

test "a leveled store opens as tiered" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    {
        const db = try Db.open(testing.allocator, manualOpts(tmp.path));
        defer db.close();
        for (0..20) |i| try db.putEdge(i, i, 1);
        try db.flush();
        _ = try db.compactLevel(0);
    }
    const db = try Db.open(testing.allocator, tieredOpts(tmp.path));
    defer db.close();
    const s = try db.snapshot();
    defer s.release();
    try testing.expectEqual(@as(usize, 1), try collectDsts(s, 7));
}

test "stats: amplification numbers add up on a known workload" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, manualOpts(tmp.path));
    defer db.close();
    for (0..1000) |i| try db.putEdge(i, i + 1, 1);
    try db.flush();
    var st = db.stats();
    try testing.expectEqual(@as(u64, 24_000), st.ingested_bytes);
    try testing.expect(st.wal_bytes > 21_000);
    try testing.expectEqual(st.flush_bytes, st.levels[0].bytes_written);
    try testing.expect(st.writeAmp() > 1 and st.writeAmp() < 5);

    // Rewrites of the same edges: dead versions take space until compacted.
    for (0..1000) |i| try db.putEdge(i, i + 1, 2);
    try db.flush();
    const before = try db.spaceAmp();
    _ = try db.compactLevel(0);
    const after = try db.spaceAmp();
    try testing.expect(after > 1); // the vertex index and bloom filter are real bytes
    try testing.expectApproxEqAbs(@as(f64, 2), before / after, 0.01);
    st = db.stats();
    try testing.expectEqual(@as(u64, 1), st.levels[1].compactions);
    try testing.expect(st.levels[1].writeAmp() > 0.3 and st.levels[1].writeAmp() < 0.7);
}

test "stats: runs merged counts the sources a scan really touches" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(testing.allocator, manualOpts(tmp.path));
    defer db.close();
    try db.putEdge(1, 2, 1);
    try db.flush();
    try db.putEdge(1, 3, 1);
    try db.flush();
    try db.putEdge(1, 4, 1);
    const s = try db.snapshot();
    defer s.release();
    {
        var it = try s.neighbors(testing.allocator, 1);
        defer it.deinit();
        try testing.expectEqual(@as(usize, 3), it.runs); // two segments + MemGraph
    }
    {
        var it = try s.neighbors(testing.allocator, 999); // bloom or range rules all out
        defer it.deinit();
        try testing.expectEqual(@as(usize, 0), it.runs);
    }
    const st = db.stats();
    try testing.expectEqual(@as(u64, 2), st.scans);
    try testing.expectEqual(@as(f64, 1.5), st.readAmp());
}

test "bloom filters can be switched off and stay compatible on reopen" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    var o = manualOpts(tmp.path);
    o.bloom_bits_per_vertex = 0;
    {
        const db = try Db.open(testing.allocator, o);
        defer db.close();
        try db.putEdge(1, 2, 1);
        try db.flush();
    }
    o.bloom_bits_per_vertex = 10;
    const db = try Db.open(testing.allocator, o);
    defer db.close();
    try db.putEdge(1, 3, 1);
    try db.flush();
    const s = try db.snapshot();
    defer s.release();
    try testing.expectEqual(@as(usize, 2), try collectDsts(s, 1));
    o.bloom_bits_per_vertex = 65;
    try testing.expectError(error.InvalidArgument, Db.open(testing.allocator, o));
}
