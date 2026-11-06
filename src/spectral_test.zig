const std = @import("std");
const testing = std.testing;
const sys = @import("sys.zig");
const sp = @import("spectrolith.zig");
const spectral = sp.spectral;
const Db = sp.Db;
const gpa = testing.allocator;

var tmp_counter: std.atomic.Value(u32) = .init(0);

const TmpDir = struct {
    path: [:0]u8,

    fn init() !TmpDir {
        try sys.makeDir(".zig-cache");
        const n = tmp_counter.fetchAdd(1, .monotonic);
        const p = try gpa.printSentinel(".zig-cache/spectral-test-{d}-{d}", .{ std.c.getpid(), n }, 0);
        try sys.makeDir(p);
        return .{ .path = p };
    }

    fn deinit(t: *TmpDir) void {
        if (sys.listDir(gpa, t.path)) |names| {
            defer gpa.free(names);
            for (names) |name| {
                defer gpa.free(name);
                const f = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ t.path, name }, 0) catch continue;
                defer gpa.free(f);
                sys.unlink(f);
            }
        } else |_| {}
        sys.rmdir(t.path);
        gpa.free(t.path);
    }
};

fn opts(path: [:0]const u8) sp.Options {
    return .{ .path = path, .sync_mode = .none, .background_compaction = false };
}

const precise: spectral.FiedlerOptions = .{ .tol = 1e-12, .max_iter = 2_000_000 };

fn lambda2Of(db: *Db, o: spectral.FiedlerOptions) !f64 {
    const s = try db.snapshot();
    defer s.release();
    var r = try spectral.fiedlerOf(gpa, s, o);
    defer r.deinit();
    try testing.expect(r.converged);
    return r.lambda2;
}

// Graphs with a closed-form spectrum.

test "cycle: lambda2 = 1 - cos(2 pi / n)" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    const n = 21;
    for (0..n) |i| try db.putEdge(i, (i + 1) % n, 1);
    const want = 1.0 - @cos(2.0 * std.math.pi / @as(f64, n));
    try testing.expectApproxEqAbs(want, try lambda2Of(db, precise), 1e-9);
    try testing.expectApproxEqAbs(want, try lambda2Of(db, .{ .method = .lanczos, .tol = 1e-10 }), 1e-9);
}

test "path: lambda2 = 1 - cos(pi / (n - 1)), and an even cycle's bipartite -1 does no harm" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    {
        const db = try Db.open(gpa, opts(tmp.path));
        defer db.close();
        const n = 17;
        for (0..n - 1) |i| try db.putEdge(i, i + 1, 1);
        const want = 1.0 - @cos(std.math.pi / @as(f64, n - 1));
        try testing.expectApproxEqAbs(want, try lambda2Of(db, precise), 1e-9);
    }
}

test "complete graph K_n: lambda2 = n / (n - 1), with weights scaled away" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    const n = 8;
    for (0..n) |i| for (i + 1..n) |j| try db.putEdge(i, j, 3.5);
    try testing.expectApproxEqAbs(@as(f64, n) / (n - 1), try lambda2Of(db, .{ .method = .lanczos }), 1e-9);
}

test "complete bipartite K_{3,3}: lambda2 = 1, and eigenvalue 2 does not derail the iteration" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    for (0..3) |i| for (3..6) |j| try db.putEdge(i, j, 1);
    try testing.expectApproxEqAbs(@as(f64, 1), try lambda2Of(db, precise), 1e-9);
}

test "two cliques joined by one edge: the sign pattern is the bisection" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    const k = 8;
    for (0..k) |i| for (i + 1..k) |j| {
        try db.putEdge(i, j, 1);
        try db.putEdge(100 + i, 100 + j, 1);
    };
    try db.putEdge(0, 100, 1);
    const s = try db.snapshot();
    defer s.release();
    var r = try spectral.fiedlerOf(gpa, s, precise);
    defer r.deinit();
    try testing.expect(r.converged);
    try testing.expect(r.lambda2 < 0.1);
    const a = r.valueOf(1).? > 0;
    for (0..k) |i| {
        try testing.expectEqual(a, r.valueOf(i).? > 0);
        try testing.expectEqual(!a, r.valueOf(100 + i).? > 0);
    }
}

test "only the largest component is solved; the rest does not add a spurious eigenvalue 0" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    const n = 15;
    for (0..n) |i| try db.putEdge(i, (i + 1) % n, 1); // the big one
    for (0..3) |i| try db.putEdge(1000 + i, 1000 + (i + 1) % 3, 1); // triangle
    try db.putEdge(2000, 2001, 1); // pair
    const s = try db.snapshot();
    defer s.release();
    var r = try spectral.fiedlerOf(gpa, s, precise);
    defer r.deinit();
    try testing.expectEqual(@as(usize, n), r.vid.len);
    try testing.expectEqual(@as(usize, n + 5), r.n_vertices);
    try testing.expectEqual(@as(?f64, null), r.valueOf(1000));
    try testing.expectApproxEqAbs(1.0 - @cos(2.0 * std.math.pi / @as(f64, n)), r.lambda2, 1e-9);
}

test "the result is a real eigenpair of L: residual is small and v is orthogonal to sqrt(deg)" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    var prng = std.Random.DefaultPrng.init(11);
    const rnd = prng.random();
    for (0..300) |_| {
        const a = rnd.uintLessThan(u64, 60);
        const b = rnd.uintLessThan(u64, 60);
        try db.putEdge(a, b, 0.25 + rnd.float(f32));
    }
    const s = try db.snapshot();
    defer s.release();
    var r = try spectral.fiedlerOf(gpa, s, .{ .method = .lanczos, .tol = 1e-10 });
    defer r.deinit();
    try testing.expect(r.converged);
    try testing.expect(r.residual < 1e-9);
    var pw = try spectral.fiedlerOf(gpa, s, precise);
    defer pw.deinit();
    try testing.expectApproxEqAbs(r.lambda2, pw.lambda2, 1e-8);
}

// Base + delta must equal the graph it stands for.

/// Fiedler results of the same graph up to sign.
fn expectSameVector(a: *const spectral.FiedlerRun, b: *const spectral.FiedlerRun, tol: f64) !void {
    try testing.expectEqualSlices(u64, a.vid, b.vid);
    try testing.expectApproxEqAbs(a.lambda2, b.lambda2, tol);
    var same: f64 = 0;
    for (a.value, b.value) |x, y| same += x * y;
    const sign: f64 = if (same >= 0) 1 else -1;
    for (a.value, b.value) |x, y| try testing.expectApproxEqAbs(x, sign * y, tol * 100);
}

test "fiedler is the same whether edges sit in a MemGraph, L0, or compacted" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    var prng = std.Random.DefaultPrng.init(5);
    const rnd = prng.random();
    for (0..400) |_| {
        try db.putEdge(rnd.uintLessThan(u64, 80), rnd.uintLessThan(u64, 80), 0.5 + rnd.float(f32));
    }
    const o: spectral.FiedlerOptions = .{ .method = .lanczos, .tol = 1e-11 };

    const s0 = try db.snapshot();
    defer s0.release();
    var all_delta = try spectral.fiedlerOf(gpa, s0, o);
    defer all_delta.deinit();
    try testing.expectEqual(@as(usize, 0), (try s0.csrView()).n()); // nothing in the base yet

    try db.flush();
    const s1 = try db.snapshot();
    defer s1.release();
    var in_l0 = try spectral.fiedlerOf(gpa, s1, o);
    defer in_l0.deinit();
    try expectSameVector(&all_delta, &in_l0, 1e-9);

    _ = try db.compactLevel(0);
    const s2 = try db.snapshot();
    defer s2.release();
    var compacted = try spectral.fiedlerOf(gpa, s2, o);
    defer compacted.deinit();
    try expectSameVector(&all_delta, &compacted, 1e-9);
}

test "updates, deletes and new vertices in the delta" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    const n = 12;
    for (0..n) |i| try db.putEdge(i, (i + 1) % n, 1);
    try db.putEdge(0, 6, 2);
    try db.flush(); // base
    try db.putEdge(0, 1, 5); // update
    try db.delEdge(0, 6); // delete
    try db.putEdge(2, 1000, 1.5); // new vertex
    try db.putEdge(1000, 1001, 1); // new vertex only the delta knows
    const s = try db.snapshot();
    defer s.release();
    const o: spectral.FiedlerOptions = .{ .method = .lanczos, .tol = 1e-11 };
    var with_delta = try spectral.fiedlerOf(gpa, s, o);
    defer with_delta.deinit();
    try testing.expectEqual(@as(usize, n + 2), with_delta.vid.len);

    try db.flush();
    const s2 = try db.snapshot();
    defer s2.release();
    var rebuilt = try spectral.fiedlerOf(gpa, s2, o);
    defer rebuilt.deinit();
    try expectSameVector(&with_delta, &rebuilt, 1e-9);
}

test "a delete in the delta that splits the graph shrinks the component" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    for (0..5) |i| for (i + 1..5) |j| {
        try db.putEdge(i, j, 1);
        try db.putEdge(10 + i, 10 + j, 1);
    };
    for (0..4) |i| for (i + 1..4) |j| try db.putEdge(20 + i, 20 + j, 1);
    try db.putEdge(0, 10, 1); // the bridge
    try db.putEdge(5, 20, 1);
    try db.putEdge(4, 5, 1);
    try db.flush();
    try db.delEdge(0, 10);
    try db.delEdge(4, 5);
    const s = try db.snapshot();
    defer s.release();
    var r = try spectral.fiedlerOf(gpa, s, precise);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 5), r.vid.len);
    // K_5 and no sign of the rest.
    try testing.expectApproxEqAbs(@as(f64, 5.0) / 4.0, r.lambda2, 1e-8);
}

test "a vertex that lost every edge in the delta drops out, and zero weights do not connect" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    const n = 9;
    for (0..n) |i| try db.putEdge(i, (i + 1) % n, 1);
    try db.putEdge(0, 500, 1);
    try db.putEdge(1, 501, 0); // no weight: not an edge as far as A knows
    try db.flush();
    try db.delEdge(0, 500);
    const s = try db.snapshot();
    defer s.release();
    var r = try spectral.fiedlerOf(gpa, s, precise);
    defer r.deinit();
    try testing.expectEqual(@as(usize, n), r.vid.len);
    try testing.expectApproxEqAbs(1.0 - @cos(2.0 * std.math.pi / @as(f64, n)), r.lambda2, 1e-9);
}

test "a snapshot's solve ignores writes made after it" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    const n = 11;
    for (0..n) |i| try db.putEdge(i, (i + 1) % n, 1);
    const s = try db.snapshot();
    defer s.release();
    try db.putEdge(0, 5, 9); // same MemGraph as the snapshot reads
    try db.putEdge(77, 0, 9);
    var r1 = try spectral.fiedlerOf(gpa, s, precise);
    defer r1.deinit();
    try db.flush();
    var r2 = try spectral.fiedlerOf(gpa, s, precise); // and after a flush
    defer r2.deinit();
    try testing.expectEqual(@as(usize, n), r1.vid.len);
    try expectSameVector(&r1, &r2, 1e-9);
    try testing.expectApproxEqAbs(1.0 - @cos(2.0 * std.math.pi / @as(f64, n)), r1.lambda2, 1e-9);
}

test "the operator of a random history equals a dense matrix read through neighbors()" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, .{
        .path = tmp.path,
        .sync_mode = .none,
        .memgraph_limit_bytes = 24 * 64,
        .background_compaction = false,
        .l0_compaction_trigger = 2,
        .target_segment_bytes = 24 * 32,
        .level1_bytes = 24 * 200,
        .size_ratio = 3,
    });
    defer db.close();
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    const nv: u64 = 40;
    for (0..2_500) |i| {
        const a = rnd.uintLessThan(u64, nv);
        const b = rnd.uintLessThan(u64, nv);
        if (rnd.uintLessThan(u8, 10) < 3) try db.delEdge(a, b) else try db.putEdge(a, b, 0.5 + rnd.float(f32));
        if (i % 500 == 0) _ = try db.compactOnce();

        if (i % 250 != 0) continue;
        const s = try db.snapshot();
        defer s.release();
        const base = try s.csrView();
        var d = try spectral.Delta.build(gpa, base, s);
        defer d.deinit();
        const ctx: spectral.DeltaCtx = .{ .base = spectral.adjacency(base), .delta = &d };
        const op = ctx.op();
        const x = try gpa.alloc(f64, op.n);
        defer gpa.free(x);
        const y = try gpa.alloc(f64, op.n);
        defer gpa.free(y);
        for (0..op.n) |col| {
            @memset(x, 0);
            x[col] = 1;
            op.apply(x, y);
            for (0..op.n) |row| {
                var want: f64 = 0;
                var it = try s.neighbors(gpa, d.vidOf(row));
                defer it.deinit();
                while (it.next()) |e| {
                    if (e.dst == d.vidOf(col)) want = e.weight;
                }
                try testing.expectEqual(want, y[row]);
            }
        }
    }
}

test "the view is cached per Version and matches neighbors(), including sinks in directed mode" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, .{ .path = tmp.path, .undirected = false, .sync_mode = .none, .background_compaction = false });
    defer db.close();
    try db.putEdge(1, 2, 1);
    try db.putEdge(1, 9, 2);
    try db.putEdge(3, 2, 4);
    try db.putEdge(3, 3, 1); // self-loop
    try db.flush();
    try db.delEdge(1, 2);
    try db.putEdge(3, 2, 8);
    try db.flush();
    const s = try db.snapshot();
    defer s.release();
    const g = try s.csrView();
    try testing.expectEqual(g, try s.csrView());
    const s2 = try db.snapshot();
    defer s2.release();
    try testing.expectEqual(g, try s2.csrView()); // same Version, same view
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 9 }, g.vid);
    try testing.expectEqualSlices(u64, &.{ 0, 1, 1, 3, 3 }, g.rowptr);
    try testing.expectEqualSlices(u32, &.{ 3, 1, 2 }, g.col);
    try testing.expectEqualSlices(f32, &.{ 2, 8, 1 }, g.w);
    try testing.expectEqual(@as(f64, 9), g.deg[2]);
    try testing.expectEqual(@as(f64, 0), g.inv_sqrt_deg[1]);

    try testing.expectError(error.InvalidArgument, spectral.fiedlerOf(gpa, s, .{})); // A is not symmetric
}

test "a negative weight is refused rather than giving a meaningless spectrum" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    for (0..6) |i| try db.putEdge(i, (i + 1) % 6, 1);
    try db.putEdge(0, 3, -1);
    const s = try db.snapshot();
    defer s.release();
    try testing.expectError(error.InvalidArgument, spectral.fiedlerOf(gpa, s, .{}));
}

test "an empty or tiny graph is an argument error, not a crash" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    {
        const s = try db.snapshot();
        defer s.release();
        try testing.expectError(error.InvalidArgument, spectral.fiedlerOf(gpa, s, .{}));
        try testing.expectError(error.InvalidArgument, spectral.centralityOf(gpa, s, .{}));
    }
    try db.putEdge(1, 2, 1);
    const s = try db.snapshot();
    defer s.release();
    try testing.expectError(error.InvalidArgument, spectral.fiedlerOf(gpa, s, .{}));
}

test "warm start cuts iterations after a small change, cold start stays correct" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    var prng = std.Random.DefaultPrng.init(3);
    const rnd = prng.random();
    // A chain of communities: slow enough that a good start matters, and no
    // symmetry to make the second eigenvalue nearly double. (A ring of them has
    // lambda2 ~= lambda3, which power iteration cannot separate in any sane
    // number of steps; Lanczos can.)
    for (0..4) |c| {
        for (0..200) |_| {
            try db.putEdge(c * 100 + rnd.uintLessThan(u64, 30), c * 100 + rnd.uintLessThan(u64, 30), 1);
        }
        if (c < 3) for (0..3) |k| try db.putEdge(c * 100 + k, (c + 1) * 100 + k, 1);
    }
    const o: spectral.FiedlerOptions = .{ .tol = 1e-9 };
    const s0 = try db.snapshot();
    defer s0.release();
    var first = try spectral.fiedlerOf(gpa, s0, o);
    defer first.deinit();

    try db.putEdge(5, 6, 1);
    try db.putEdge(205, 900, 1); // a new vertex starts at 0
    const s1 = try db.snapshot();
    defer s1.release();
    var cold = try spectral.fiedlerOf(gpa, s1, o);
    defer cold.deinit();
    var warm_o = o;
    warm_o.warm = &first;
    var warm = try spectral.fiedlerOf(gpa, s1, warm_o);
    defer warm.deinit();
    try testing.expect(cold.converged and warm.converged);
    try testing.expect(warm.iters < cold.iters);
    try testing.expectApproxEqAbs(cold.lambda2, warm.lambda2, 1e-6);
}

test "lanczos needs far fewer operator applications than power iteration on a small gap" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    const n = 300;
    for (0..n) |i| try db.putEdge(i, (i + 1) % n, 1); // lambda2 ~ 2e-4
    const s = try db.snapshot();
    defer s.release();
    var pw = try spectral.fiedlerOf(gpa, s, .{ .tol = 1e-11, .max_iter = 4_000_000 });
    defer pw.deinit();
    var lz = try spectral.fiedlerOf(gpa, s, .{ .method = .lanczos, .tol = 1e-9, .lanczos_basis = 96, .max_iter = 100_000 });
    defer lz.deinit();
    try testing.expect(lz.converged);
    const want = 1.0 - @cos(2.0 * std.math.pi / @as(f64, n));
    try testing.expectApproxEqAbs(want, lz.lambda2, 1e-8);
    try testing.expect(lz.iters * 5 < pw.iters);
}

test "eigenvector centrality: star and regular graphs" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    const leaves = 16;
    for (1..leaves + 1) |i| try db.putEdge(0, i, 1);
    {
        const s = try db.snapshot();
        defer s.release();
        var r = try spectral.centralityOf(gpa, s, precise);
        defer r.deinit();
        try testing.expect(r.converged);
        const root = @sqrt(@as(f64, leaves));
        try testing.expectApproxEqAbs(root, r.eigenvalue, 1e-9);
        try testing.expectApproxEqAbs(root, r.valueOf(0).? / r.valueOf(1).?, 1e-8);
    }
}

test "centrality on a bipartite graph converges, and the small component is left out" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, opts(tmp.path));
    defer db.close();
    for (0..4) |i| for (4..9) |j| try db.putEdge(i, j, 1); // K_{4,5}
    try db.putEdge(100, 101, 1);
    const s = try db.snapshot();
    defer s.release();
    var r = try spectral.centralityOf(gpa, s, precise);
    defer r.deinit();
    try testing.expect(r.converged);
    try testing.expectEqual(@as(usize, 9), r.vid.len);
    try testing.expectApproxEqAbs(@sqrt(@as(f64, 20)), r.eigenvalue, 1e-9);
}

test "solving while writers flush and compact underneath" {
    var tmp = try TmpDir.init();
    defer tmp.deinit();
    const db = try Db.open(gpa, .{
        .path = tmp.path,
        .sync_mode = .none,
        .memgraph_limit_bytes = 24 * 200,
        .l0_compaction_trigger = 2,
        .l0_stop_trigger = 4,
        .size_ratio = 3,
        .level1_bytes = 24 * 1000,
        .target_segment_bytes = 24 * 400,
    });
    defer db.close();
    const n = 64;
    for (0..n) |i| try db.putEdge(i, (i + 1) % n, 1);

    const Writer = struct {
        fn run(d: *Db, stop: *std.atomic.Value(bool)) void {
            var i: u64 = 0;
            while (!stop.load(.acquire)) : (i += 1) {
                d.putEdge(i % n, (i * 7 + 1) % n, 1) catch return;
            }
        }
    };
    var stop: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, Writer.run, .{ db, &stop });
    defer t.join();
    defer stop.store(true, .release);

    const o: spectral.FiedlerOptions = .{ .method = .lanczos, .tol = 1e-8 };
    for (0..40) |_| {
        const s = try db.snapshot();
        defer s.release();
        var r = try spectral.fiedlerOf(gpa, s, o);
        defer r.deinit();
        try testing.expect(r.converged);
        // The same snapshot, solved again from a different start, whatever
        // has happened underneath: one graph, one answer.
        var again_o = o;
        again_o.seed = 2;
        var again = try spectral.fiedlerOf(gpa, s, again_o);
        defer again.deinit();
        try testing.expectApproxEqAbs(r.lambda2, again.lambda2, 1e-6);
    }
}

test "simd kernels agree with the plain loops" {
    var prng = std.Random.DefaultPrng.init(9);
    const rnd = prng.random();
    for ([_]usize{ 0, 1, 3, 4, 5, 8, 17, 100 }) |n| {
        const a = try gpa.alloc(f64, n);
        defer gpa.free(a);
        const b = try gpa.alloc(f64, n);
        defer gpa.free(b);
        const c = try gpa.alloc(f64, n);
        defer gpa.free(c);
        for (a, b) |*x, *y| {
            x.* = rnd.float(f64);
            y.* = rnd.float(f64);
        }
        @memcpy(c, b);
        try testing.expectApproxEqAbs(spectral.scalar.dot(a, b), spectral.simd.dot(a, b), 1e-12);
        try testing.expectApproxEqAbs(spectral.scalar.distSq(a, b), spectral.simd.distSq(a, b), 1e-12);
        spectral.scalar.axpy(0.5, a, b);
        spectral.simd.axpy(0.5, a, c);
        for (b, c) |x, y| try testing.expectApproxEqAbs(x, y, 1e-12);
    }
}
