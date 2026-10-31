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
        for ([_][]const u8{ "LOCK", "wal-000001.log" }) |name| {
            const f = std.fmt.allocPrintSentinel(testing.allocator, "{s}/{s}", .{ t.path, name }, 0) catch continue;
            defer testing.allocator.free(f);
            sys.unlink(f);
        }
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
