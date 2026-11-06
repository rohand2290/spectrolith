//! Benchmark harness. Prints one JSON object per measurement on stdout;
//! scripts/run_benchmarks.sh collects them and scripts/plot_results.py turns
//! them into every chart and table.
//!
//! usage:
//!   bench store <engine> <edges.tsv> <workdir> [dataset-name]
//!   bench sync <engine> <edges.tsv> <workdir> [dataset-name]
//!   bench analytics <edges.tsv> <workdir> [dataset-name] [edges-per-sec] [interval-sec]
//!   bench spectral <edges.tsv> <workdir> [dataset-name]
//!   bench kernels
//!
//! engines: leveled, tiered, nobloom, rocksdb
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const options = @import("bench_options");
const sp = @import("spectrolith");
const util = @import("benchutil.zig");
const spectral = sp.spectral;
const Allocator = std.mem.Allocator;
const InputEdge = util.InputEdge;

const Rocks = if (options.rocksdb) @import("rocks_engine.zig").Rocks else void;

extern "c" fn mach_absolute_time() u64;

/// Monotonic nanoseconds. On macOS `clock_gettime` only ticks once a
/// microsecond, too coarse for an insert; the raw counter on Apple silicon is
/// 24 MHz, so about 42 ns.
fn now() u64 {
    if (builtin.os.tag.isDarwin()) {
        return @intCast(@as(u128, mach_absolute_time()) * 125 / 3);
    }
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn secs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e9;
}

fn sleepMs(ms: u64) void {
    var ts: c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = c.nanosleep(&ts, null);
}

/// Latency histogram: 32 buckets per power of two, about 2% resolution, in
/// constant memory however many samples arrive.
const Hist = struct {
    const sub = 32;
    counts: [64 * sub]u64 = @splat(0),
    n: u64 = 0,
    max: u64 = 0,

    fn add(h: *Hist, ns: u64) void {
        const v = @max(ns, 1);
        const log: u6 = @intCast(63 - @clz(v));
        const frac: u64 = if (log >= 5) (v >> (log - 5)) & (sub - 1) else (v << (5 - log)) & (sub - 1);
        h.counts[@as(usize, log) * sub + @as(usize, @intCast(frac))] += 1;
        h.n += 1;
        h.max = @max(h.max, ns);
    }

    fn quantile(h: *const Hist, q: f64) u64 {
        const target: u64 = @intFromFloat(@ceil(q * @as(f64, @floatFromInt(h.n))));
        var seen: u64 = 0;
        for (h.counts, 0..) |n, i| {
            seen += n;
            if (seen >= target and n > 0) {
                const log = i / sub;
                const frac = i % sub;
                const base = @as(u128, sub + frac) << @intCast(log);
                return @intCast(base >> 5);
            }
        }
        return h.max;
    }

    fn print(h: *const Hist, w: *std.Io.Writer, name: []const u8) !void {
        try w.print("\"{s}_p50_ns\":{d},\"{s}_p99_ns\":{d},\"{s}_p999_ns\":{d},\"{s}_max_ns\":{d},\"{s}_n\":{d},", .{
            name, h.quantile(0.5), name, h.quantile(0.99), name, h.quantile(0.999), name, h.max, name, h.n,
        });
    }
};

// ---- engines ----------------------------------------------------------------

const Spectro = struct {
    gpa: Allocator,
    db: *sp.Db,

    fn open(gpa: Allocator, path: []const u8, engine: []const u8, sync: bool) !Spectro {
        const style: sp.CompactionStyle = if (std.mem.eql(u8, engine, "tiered")) .tiered else .leveled;
        const db = try sp.Db.open(gpa, .{
            .path = path,
            .sync_mode = if (sync) .every else .none,
            .compaction_style = style,
            .bloom_bits_per_vertex = if (std.mem.eql(u8, engine, "nobloom")) 0 else 10,
        });
        return .{ .gpa = gpa, .db = db };
    }

    fn close(e: *Spectro) void {
        e.db.close();
    }

    fn put(e: *Spectro, u: u64, v: u64, w: f32) !void {
        try e.db.putEdge(u, v, w);
    }

    fn scan(e: *Spectro, v: u64) !f64 {
        const s = try e.db.snapshot();
        defer s.release();
        var it = try s.neighbors(e.gpa, v);
        defer it.deinit();
        var sum: f64 = 0;
        while (it.next()) |x| sum += x.weight;
        return sum;
    }

    fn settle(e: *Spectro) !void {
        try e.db.flush();
        try e.db.waitForCompaction();
    }

    fn report(e: *Spectro, w: *std.Io.Writer) !void {
        const st = e.db.stats();
        try w.print("\"write_amp\":{d:.3},\"read_amp\":{d:.3},\"space_amp\":{d:.3},\"disk_bytes\":{d},\"ingested_bytes\":{d},\"wal_bytes\":{d},\"stalls\":{d},\"stall_ns\":{d},\"dropped_records\":{d},\"levels\":[", .{
            st.writeAmp(), st.readAmp(), try e.db.spaceAmp(), st.diskBytes(), st.ingested_bytes, st.wal_bytes, st.stalls, st.stall_ns, st.dropped_records,
        });
        var first = true;
        for (st.levels, 0..) |l, i| {
            if (l.bytes_written == 0 and l.files == 0) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("{{\"level\":{d},\"files\":{d},\"bytes\":{d},\"compactions\":{d},\"bytes_read\":{d},\"bytes_from_above\":{d},\"bytes_written\":{d},\"write_amp\":{d:.3}}}", .{
                i, l.files, l.bytes, l.compactions, l.bytes_read, l.bytes_from_above, l.bytes_written, l.writeAmp(),
            });
        }
        try w.writeAll("],");
    }
};

const RocksEngine = struct {
    r: Rocks,
    gpa: Allocator,
    path: []const u8,
    live_edges: u64,

    fn close(e: *RocksEngine) void {
        e.r.close();
    }
    fn put(e: *RocksEngine, u: u64, v: u64, w: f32) !void {
        try e.r.put(u, v, w);
    }
    fn scan(e: *RocksEngine, v: u64) !f64 {
        return e.r.scan(v);
    }
    fn settle(e: *RocksEngine) !void {
        try e.r.settle();
    }

    fn report(e: *RocksEngine, w: *std.Io.Writer) !void {
        const x = e.r.written();
        const live = e.live_edges * 24; // same yardstick as Stats: 24 bytes per stored record
        const disk = try dirBytes(e.gpa, e.path);
        const total = x.wal + x.flush + x.compaction;
        try w.print("\"write_amp\":{d:.3},\"space_amp\":{d:.3},\"disk_bytes\":{d},\"ingested_bytes\":{d},\"wal_bytes\":{d},\"flush_bytes\":{d},\"compaction_bytes\":{d},\"stall_ns\":{d},", .{
            ratio(total, live), ratio(disk, live), disk, live, x.wal, x.flush, x.compaction, x.stall_ns,
        });
    }
};

fn ratio(a: u64, b: u64) f64 {
    return if (b == 0) 0 else @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b));
}

/// Size of the table files, the counterpart of `Stats.diskBytes`.
fn dirBytes(gpa: Allocator, path: []const u8) !u64 {
    const z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(z);
    const dp = c.opendir(z) orelse return error.CannotOpen;
    defer _ = c.closedir(dp);
    var total: u64 = 0;
    while (c.readdir(dp)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (!std.mem.endsWith(u8, name, ".sst")) continue;
        const p = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ path, name }, 0);
        defer gpa.free(p);
        var st: c.Stat = undefined;
        if (c.stat(p, &st) == 0) total += @intCast(st.size);
    }
    return total;
}

// ---- store workload: ingest, then read/write mixes ------------------------------

const mix_ops = 150_000;

const Mix = struct {
    read: Hist = .{},
    write: Hist = .{},
    secs: f64 = 0,
};

/// `read_pct` of the ops are scans of a random already-loaded edge's source,
/// which weights vertices by degree as real traffic does; the rest are inserts.
fn runMix(e: anytype, loaded: []const InputEdge, pending: []const InputEdge, read_pct: u32, rnd: std.Random, sink: *f64) !struct { Mix, usize } {
    var m: Mix = .{};
    var used: usize = 0;
    const t0 = now();
    for (0..mix_ops) |_| {
        if (rnd.uintLessThan(u32, 100) < read_pct or used == pending.len) {
            const edge = loaded[rnd.uintLessThan(usize, loaded.len)];
            const t = now();
            sink.* += try e.scan(edge.u);
            m.read.add(now() - t);
        } else {
            const edge = pending[used];
            used += 1;
            const t = now();
            try e.put(edge.u, edge.v, edge.w);
            m.write.add(now() - t);
        }
    }
    m.secs = secs(now() - t0);
    return .{ m, used };
}

fn storeWorkload(gpa: Allocator, e: anytype, w: *std.Io.Writer, engine: []const u8, dataset: []const u8, edges: []const InputEdge) !void {
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    const n90 = edges.len / 10 * 9;

    var ingest: Hist = .{};
    const t0 = now();
    for (edges[0..n90]) |edge| {
        const t = now();
        try e.put(edge.u, edge.v, edge.w);
        ingest.add(now() - t);
    }
    const ingest_s = secs(now() - t0);

    var sink: f64 = 0;
    var pos = n90;
    const m90 = try runMix(e, edges[0..pos], edges[pos..], 90, rnd, &sink);
    pos += m90[1];
    const m50 = try runMix(e, edges[0..pos], edges[pos..], 50, rnd, &sink);
    pos += m50[1];

    for (edges[pos..]) |edge| try e.put(edge.u, edge.v, edge.w);
    const t1 = now();
    try e.settle();
    const settle_s = secs(now() - t1);

    if (@TypeOf(e) == *RocksEngine) e.live_edges = countLive(edges);

    try w.print("{{\"kind\":\"store\",\"engine\":\"{s}\",\"dataset\":\"{s}\",\"edges\":{d},", .{ engine, dataset, edges.len });
    try w.print("\"ingest_edges_per_sec\":{d:.0},\"settle_s\":{d:.3},", .{ @as(f64, @floatFromInt(n90)) / ingest_s, settle_s });
    try ingest.print(w, "ingest");
    try m90[0].read.print(w, "mix90_read");
    try m90[0].write.print(w, "mix90_write");
    try w.print("\"mix90_ops_per_sec\":{d:.0},", .{mix_ops / m90[0].secs});
    try m50[0].read.print(w, "mix50_read");
    try m50[0].write.print(w, "mix50_write");
    try w.print("\"mix50_ops_per_sec\":{d:.0},", .{mix_ops / m50[0].secs});
    try e.report(w);
    try w.print("\"sink\":{d:.1}}}\n", .{sink});
    _ = gpa;
}

/// Records stored for `edges`: both directions, a self-loop once. Input lists
/// each edge once, so this is the live count.
fn countLive(edges: []const InputEdge) u64 {
    var n: u64 = 0;
    for (edges) |e| n += if (e.u == e.v) 1 else 2;
    return n;
}

fn syncWorkload(e: anytype, w: *std.Io.Writer, engine: []const u8, dataset: []const u8, edges: []const InputEdge) !void {
    const n = @min(edges.len, 3000);
    var h: Hist = .{};
    const t0 = now();
    for (edges[0..n]) |edge| {
        const t = now();
        try e.put(edge.u, edge.v, edge.w);
        h.add(now() - t);
    }
    const s = secs(now() - t0);
    try w.print("{{\"kind\":\"sync\",\"engine\":\"{s}\",\"dataset\":\"{s}\",\"edges_per_sec\":{d:.0},", .{ engine, dataset, @as(f64, @floatFromInt(n)) / s });
    try h.print(w, "write");
    try w.writeAll("\"ok\":true}\n");
}

// ---- analytics during ingest ---------------------------------------------------

const Writer = struct {
    fn run(db: *sp.Db, edges: []const InputEdge, per_sec: u64, done: *std.atomic.Value(bool)) void {
        const t0 = now();
        for (edges, 0..) |e, i| {
            db.putEdge(e.u, e.v, e.w) catch break;
            if (i % 1024 == 0) { // pace, so analytics rounds cover the whole load
                const due = t0 + @as(u64, @intCast(i)) * std.time.ns_per_s / per_sec;
                const t = now();
                if (due > t) sleepMs((due - t) / std.time.ns_per_ms);
            }
        }
        done.store(true, .release);
    }
};

fn analytics(gpa: Allocator, w: *std.Io.Writer, path: []const u8, dataset: []const u8, edges: []const InputEdge, per_sec: u64, interval_s: u64) !void {
    const db = try sp.Db.open(gpa, .{ .path = path, .sync_mode = .none });
    defer db.close();
    var done: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, Writer.run, .{ db, edges, per_sec, &done });
    defer t.join();

    var prev_lz: ?spectral.FiedlerRun = null;
    var prev_pw: ?spectral.FiedlerRun = null;
    defer if (prev_lz) |*r| r.deinit();
    defer if (prev_pw) |*r| r.deinit();

    const tol_lz = 1e-7;
    const tol_pw = 1e-6;
    var round: u32 = 0;
    while (true) : (round += 1) {
        const finished = done.load(.acquire);
        sleepMs(interval_s * 1000);
        const snap = try db.snapshot();
        defer snap.release();

        const tv = now();
        const view = try snap.csrView();
        const view_ns = now() - tv;
        const td = now();
        var delta = try spectral.Delta.build(gpa, view, snap);
        const delta_ns = now() - td;
        const triples = delta.i.len;
        delta.deinit();

        const lz: spectral.FiedlerOptions = .{ .method = .lanczos, .tol = tol_lz, .max_iter = 20_000 };
        const pw: spectral.FiedlerOptions = .{ .method = .power, .tol = tol_pw, .max_iter = 3_000 };

        const t1 = now();
        const cold_lz = spectral.fiedlerOf(gpa, snap, lz) catch |err| {
            if (err == error.InvalidArgument) continue; // nothing to solve yet
            return err;
        };
        const cold_lz_ns = now() - t1;

        var warm_o = lz;
        if (prev_lz) |*r| warm_o.warm = r;
        const t2 = now();
        var warm_lz = try spectral.fiedlerOf(gpa, snap, warm_o);
        const warm_lz_ns = now() - t2;
        defer warm_lz.deinit();

        const t3 = now();
        const cold_pw = try spectral.fiedlerOf(gpa, snap, pw);
        const cold_pw_ns = now() - t3;

        var warm_po = pw;
        if (prev_pw) |*r| warm_po.warm = r;
        const t4 = now();
        var warm_pw = try spectral.fiedlerOf(gpa, snap, warm_po);
        const warm_pw_ns = now() - t4;
        defer warm_pw.deinit();

        const stale = db.lastSeq() - snap.seq;
        const has_prev = prev_lz != null;
        try w.print("{{\"kind\":\"analytics\",\"dataset\":\"{s}\",\"round\":{d},\"seq\":{d},\"has_prev\":{},\"n\":{d},\"lcc\":{d},\"view_edges\":{d},\"view_ms\":{d:.2},\"delta_ms\":{d:.2},\"delta_triples\":{d},\"lambda2\":{d:.8},", .{
            dataset, round, snap.seq, has_prev, cold_lz.n_vertices, cold_lz.vid.len, view.edges(), secs(view_ns) * 1e3, secs(delta_ns) * 1e3, triples, cold_lz.lambda2,
        });
        try w.print("\"lanczos_cold_iters\":{d},\"lanczos_warm_iters\":{d},\"lanczos_cold_ms\":{d:.1},\"lanczos_warm_ms\":{d:.1},\"power_cold_iters\":{d},\"power_warm_iters\":{d},\"power_cold_ms\":{d:.1},\"power_warm_ms\":{d:.1},\"power_cold_converged\":{},\"power_warm_converged\":{},\"staleness_seq\":{d}}}\n", .{
            cold_lz.iters, warm_lz.iters, secs(cold_lz_ns) * 1e3, secs(warm_lz_ns) * 1e3, cold_pw.iters, warm_pw.iters, secs(cold_pw_ns) * 1e3, secs(warm_pw_ns) * 1e3, cold_pw.converged, warm_pw.converged, stale,
        });
        try w.flush();

        if (prev_lz) |*r| r.deinit();
        prev_lz = cold_lz;
        if (prev_pw) |*r| r.deinit();
        prev_pw = cold_pw;
        if (finished) break;
    }
}

// ---- one-shot spectral costs, and kernels ---------------------------------------

fn spectralCost(gpa: Allocator, w: *std.Io.Writer, path: []const u8, dataset: []const u8, edges: []const InputEdge) !void {
    const db = try sp.Db.open(gpa, .{ .path = path, .sync_mode = .none });
    defer db.close();
    const in_mem = edges.len / 100;
    const on_disk = edges[0 .. edges.len - in_mem];
    for (on_disk) |e| try db.putEdge(e.u, e.v, e.w);
    try db.flush();
    try db.waitForCompaction();
    for (edges[on_disk.len..]) |e| try db.putEdge(e.u, e.v, e.w);

    const snap = try db.snapshot();
    defer snap.release();
    const t0 = now();
    const view = try snap.csrView();
    const view_ns = now() - t0;

    const t1 = now();
    var delta = try spectral.Delta.build(gpa, view, snap);
    defer delta.deinit();
    const delta_ns = now() - t1;

    const ctx: spectral.DeltaCtx = .{ .base = spectral.adjacency(view), .delta = &delta };
    const op = ctx.op();
    const x = try gpa.alloc(f64, op.n);
    defer gpa.free(x);
    const y = try gpa.alloc(f64, op.n);
    defer gpa.free(y);
    @memset(x, 1);
    const reps = 20;
    const t2 = now();
    for (0..reps) |_| op.apply(x, y);
    const delta_spmv = secs(now() - t2) / reps;
    const base = spectral.adjacency(view);
    const t3 = now();
    for (0..reps) |_| base.apply(x[0..base.n], y[0..base.n]);
    const base_spmv = secs(now() - t3) / reps;

    try w.print("{{\"kind\":\"spectral\",\"dataset\":\"{s}\",\"n\":{d},\"view_edges\":{d},\"delta_triples\":{d},\"view_ms\":{d:.1},\"delta_ms\":{d:.1},\"base_spmv_ms\":{d:.2},\"delta_spmv_ms\":{d:.2},\"medges_per_sec\":{d:.1},\"sink\":{d}}}\n", .{
        dataset, view.n(), view.edges(), delta.i.len, secs(view_ns) * 1e3, secs(delta_ns) * 1e3, base_spmv * 1e3, delta_spmv * 1e3, @as(f64, @floatFromInt(view.edges())) / base_spmv / 1e6, y[0],
    });
}

fn kernels(gpa: Allocator, w: *std.Io.Writer) !void {
    const n = 1 << 20;
    const a = try gpa.alloc(f64, n);
    defer gpa.free(a);
    const b = try gpa.alloc(f64, n);
    defer gpa.free(b);
    var prng = std.Random.DefaultPrng.init(1);
    for (a, b) |*x, *y| {
        x.* = prng.random().float(f64);
        y.* = prng.random().float(f64);
    }
    const reps = 2000;
    var sink: f64 = 0;
    const Timed = struct {
        fn dotT(f: anytype, x: []const f64, y: []const f64, s: *f64) f64 {
            const t = now();
            for (0..reps) |_| {
                s.* += f(x, y);
                std.mem.doNotOptimizeAway(s.*);
            }
            return secs(now() - t);
        }
        fn axpyT(f: anytype, x: []const f64, y: []f64) f64 {
            const t = now();
            for (0..reps) |i| {
                f(if (i % 2 == 0) 1e-9 else -1e-9, x, y);
                std.mem.doNotOptimizeAway(y.ptr);
            }
            return secs(now() - t);
        }
    };
    const gb = @as(f64, reps) * n * 8.0 / 1e9;
    try w.print("{{\"kind\":\"kernels\",\"dot_scalar_gbps\":{d:.1},\"dot_simd_gbps\":{d:.1},\"distsq_scalar_gbps\":{d:.1},\"distsq_simd_gbps\":{d:.1},\"axpy_scalar_gbps\":{d:.1},\"axpy_simd_gbps\":{d:.1},\"sink\":{d}}}\n", .{
        gb / Timed.dotT(spectral.scalar.dot, a, b, &sink),
        gb / Timed.dotT(spectral.simd.dot, a, b, &sink),
        gb / Timed.dotT(spectral.scalar.distSq, a, b, &sink),
        gb / Timed.dotT(spectral.simd.distSq, a, b, &sink),
        gb / Timed.axpyT(spectral.scalar.axpy, a, b),
        gb / Timed.axpyT(spectral.simd.axpy, a, b),
        sink,
    });
}

// ---- main ---------------------------------------------------------------------

fn withEngine(gpa: Allocator, comptime f: anytype, engine: []const u8, path: []const u8, sync: bool, args: anytype) !void {
    if (std.mem.eql(u8, engine, "rocksdb")) {
        if (!options.rocksdb) return error.BuiltWithoutRocksDb;
        var e: RocksEngine = .{ .r = try Rocks.open(gpa, path, sync), .gpa = gpa, .path = path, .live_edges = 0 };
        defer e.close();
        try @call(.auto, f, .{&e} ++ args);
    } else {
        var e = try Spectro.open(gpa, path, engine, sync);
        defer e.close();
        try @call(.auto, f, .{&e} ++ args);
    }
}

pub fn main(init: std.process.Init) !void {
    // The harness allocates little; the engines' costs are what is measured.
    const gpa = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.Usage;
    const mode = args[1];

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    defer {
        _ = c.write(1, out.written().ptr, out.written().len);
    }

    if (std.mem.eql(u8, mode, "kernels")) return kernels(gpa, w);

    if (std.mem.eql(u8, mode, "store") or std.mem.eql(u8, mode, "sync")) {
        if (args.len < 5) return error.Usage;
        const engine = args[2];
        const dataset = if (args.len > 5) args[5] else "unnamed";
        const edges = try util.loadEdges(gpa, args[3]);
        defer gpa.free(edges);
        util.shuffle(edges, 42);
        if (std.mem.eql(u8, mode, "store")) {
            const Wrap = struct {
                fn run(e: anytype, a: Allocator, wr: *std.Io.Writer, en: []const u8, ds: []const u8, es: []const InputEdge) !void {
                    try storeWorkload(a, e, wr, en, ds, es);
                }
            };
            try withEngine(gpa, Wrap.run, engine, args[4], false, .{ gpa, w, engine, dataset, edges });
        } else {
            const Wrap = struct {
                fn run(e: anytype, wr: *std.Io.Writer, en: []const u8, ds: []const u8, es: []const InputEdge) !void {
                    try syncWorkload(e, wr, en, ds, es);
                }
            };
            try withEngine(gpa, Wrap.run, engine, args[4], true, .{ w, engine, dataset, edges });
        }
        return;
    }

    if (args.len < 4) return error.Usage;
    const dataset = if (args.len > 4) args[4] else "unnamed";
    const edges = try util.loadEdges(gpa, args[2]);
    defer gpa.free(edges);
    util.shuffle(edges, 42);
    if (std.mem.eql(u8, mode, "analytics")) {
        const per_sec = if (args.len > 5) try std.fmt.parseInt(u64, args[5], 10) else 300_000;
        const interval = if (args.len > 6) try std.fmt.parseInt(u64, args[6], 10) else 4;
        return analytics(gpa, w, args[3], dataset, edges, per_sec, interval);
    }
    if (std.mem.eql(u8, mode, "spectral")) return spectralCost(gpa, w, args[3], dataset, edges);
    return error.Usage;
}
