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
    });
    defer db.close();
    for (0..1000) |i| try db.putEdge(i % 10, i, 1);
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
    const p = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/000002.seg", .{tmp.path}, 0);
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

test "model: 1M random ops, flushes, frozen snapshots and reopens match the reference" {
    const seed: u64 = 0x5eed_2;
    const total_ops: usize = 1_000_000;
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();

    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const opts: sp.Options = .{
        .path = tmp.path,
        .undirected = false,
        .sync_mode = .none,
        .memgraph_limit_bytes = 1 << 20, // ~43k records: about 20 flushes
    };
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
    try testing.expect(try countFiles(tmp.path, ".seg") >= 10);
    const last = try db.snapshot();
    defer last.release();
    try expectMatches(seed, done, "final", last, model);
}
