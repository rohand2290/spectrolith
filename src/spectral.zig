//! Spectral operators over snapshots.
//!
//! A long eigenvector computation sees one consistent graph while ingestion
//! continues. Every algorithm is written against `LinOp`; the graph is never a
//! dense matrix.
//!
//! The adjacency of a snapshot is `A_snap = A_base + Delta`:
//!  - `CsrView` (A_base) merges every level of one Version. All of a Version's
//!    records are visible to every snapshot that holds it (a snapshot reads
//!    `last_seq` and `current` in one critical section), so the view depends on
//!    the Version alone and is cached there.
//!  - `Delta` holds what the snapshot's MemGraphs change on top of it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const merge = @import("merge.zig");
const version_mod = @import("version.zig");
const db_mod = @import("db.zig");
const Version = version_mod.Version;
const Segment = @import("segment.zig").Segment;
const Snapshot = db_mod.Snapshot;
const EdgeRec = types.EdgeRec;
const Error = types.Error;

// ---- linear operators -------------------------------------------------------

/// y = Op x, matrix-free.
pub const LinOp = struct {
    n: usize,
    ctx: *const anyopaque,
    applyFn: *const fn (ctx: *const anyopaque, x: []const f64, y: []f64) void,

    pub fn apply(op: LinOp, x: []const f64, y: []f64) void {
        std.debug.assert(x.len == op.n and y.len == op.n);
        op.applyFn(op.ctx, x, y);
    }
};

/// A vector kernel, `@Vector`-based or a plain loop. The plain ones stay so
/// the difference can be measured.
pub const scalar = struct {
    pub fn dot(a: []const f64, b: []const f64) f64 {
        var s: f64 = 0;
        for (a, b) |x, y| s += x * y;
        return s;
    }
    pub fn distSq(a: []const f64, b: []const f64) f64 {
        var s: f64 = 0;
        for (a, b) |x, y| s += (x - y) * (x - y);
        return s;
    }
    pub fn axpy(alpha: f64, x: []const f64, y: []f64) void {
        for (x, y) |xi, *yi| yi.* += alpha * xi;
    }
};

pub const simd = struct {
    const L = 4;
    const V = @Vector(L, f64);

    fn load(s: []const f64, i: usize) V {
        return s[i..][0..L].*;
    }

    pub fn dot(a: []const f64, b: []const f64) f64 {
        var acc: V = @splat(0);
        var i: usize = 0;
        while (i + L <= a.len) : (i += L) acc += load(a, i) * load(b, i);
        var s = @reduce(.Add, acc);
        while (i < a.len) : (i += 1) s += a[i] * b[i];
        return s;
    }
    pub fn distSq(a: []const f64, b: []const f64) f64 {
        var acc: V = @splat(0);
        var i: usize = 0;
        while (i + L <= a.len) : (i += L) {
            const d = load(a, i) - load(b, i);
            acc += d * d;
        }
        var s = @reduce(.Add, acc);
        while (i < a.len) : (i += 1) s += (a[i] - b[i]) * (a[i] - b[i]);
        return s;
    }
    pub fn axpy(alpha: f64, x: []const f64, y: []f64) void {
        const al: V = @splat(alpha);
        var i: usize = 0;
        while (i + L <= x.len) : (i += L) {
            const r: V = load(y, i) + al * load(x, i);
            y[i..][0..L].* = r;
        }
        while (i < x.len) : (i += 1) y[i] += alpha * x[i];
    }
};

const dot = simd.dot;
const distSq = simd.distSq;
const axpy = simd.axpy;

fn norm(v: []const f64) f64 {
    return @sqrt(dot(v, v));
}

fn normalize(v: []f64) void {
    const n = norm(v);
    if (n > 0) for (v) |*x| {
        x.* /= n;
    };
}

/// v -= (u . v) u, for unit u.
fn projectOut(v: []f64, u: []const f64) void {
    axpy(-dot(u, v), u, v);
}

// ---- materialized CSR view --------------------------------------------------

/// Visible live edges of one Version, in dense indices `0..n-1`. Rows and the
/// columns inside a row are sorted.
pub const CsrView = struct {
    gpa: Allocator,
    vid: []u64, // dense index -> vertex id, sorted, for binary search
    rowptr: []u64, // n + 1 entries
    col: []u32, // dense neighbor index
    w: []f32,
    inv_sqrt_deg: []f64, // 1 / sqrt(weighted degree), 0 for isolated vertices
    deg: []f64, // weighted degree
    built_at_seq: u64,
    has_negative: bool,

    pub fn n(g: *const CsrView) usize {
        return g.vid.len;
    }

    pub fn edges(g: *const CsrView) usize {
        return g.col.len;
    }

    pub fn indexOf(g: *const CsrView, vid: u64) ?u32 {
        return findSorted(g.vid, vid);
    }

    /// Weight of edge (i, j), or null when absent.
    pub fn weight(g: *const CsrView, i: usize, j: u32) ?f32 {
        const lo: usize = @intCast(g.rowptr[i]);
        const hi: usize = @intCast(g.rowptr[i + 1]);
        const k = lowerBound(u32, g.col[lo..hi], 0, j);
        if (k == hi - lo or g.col[lo + k] != j) return null;
        return g.w[lo + k];
    }

    pub fn destroy(g: *CsrView) void {
        const gpa = g.gpa;
        gpa.free(g.vid);
        gpa.free(g.rowptr);
        gpa.free(g.col);
        gpa.free(g.w);
        gpa.free(g.inv_sqrt_deg);
        gpa.free(g.deg);
        gpa.destroy(g);
    }

    /// Merge every level for every vertex, keeping the newest version of each
    /// edge when it is not a delete. No sequence filter: see the file comment.
    pub fn build(gpa: Allocator, v: *const Version) Error!*CsrView {
        var srcs: std.ArrayList(u64) = .empty; // vertices with a live edge
        defer srcs.deinit(gpa);
        var row_ends: std.ArrayList(u64) = .empty; // end offset of each of `srcs`
        defer row_ends.deinit(gpa);
        var dsts: std.ArrayList(u64) = .empty;
        defer dsts.deinit(gpa);
        var weights: std.ArrayList(f32) = .empty;
        errdefer weights.deinit(gpa);

        var all: std.ArrayList(*Segment) = .empty;
        defer all.deinit(gpa);
        var built_at_seq: u64 = 0;
        for (v.levels) |segs| for (segs) |s| {
            try all.append(gpa, s);
            built_at_seq = @max(built_at_seq, s.max_seq);
        };
        const cursors = try gpa.alloc(usize, all.items.len);
        defer gpa.free(cursors);
        @memset(cursors, 0);

        var heap: merge.RunHeap = .empty;
        defer heap.deinit(gpa);
        var has_negative = false;
        while (true) {
            var next: ?u64 = null;
            for (all.items, cursors) |s, cur| {
                if (cur < s.vidx.len) next = @min(next orelse std.math.maxInt(u64), s.vidx[cur].vid);
            }
            const vid = next orelse break;

            heap.clearRetainingCapacity();
            for (all.items, cursors) |s, *cur| {
                if (cur.* >= s.vidx.len or s.vidx[cur.*].vid != vid) continue;
                const vi = s.vidx[cur.*];
                try heap.push(gpa, .{ .recs = s.edges[@intCast(vi.edge_off)..][0..vi.degree] });
                cur.* += 1;
            }
            const row_start = dsts.items.len;
            var last_dst: ?u64 = null;
            while (heap.pop()) |popped| {
                var r = popped;
                const e = r.recs[r.pos];
                r.pos += 1;
                // Pushing back after a pop never needs to grow the queue.
                if (r.pos < r.recs.len) heap.push(gpa, r) catch unreachable;
                if (last_dst) |d| if (d == e.dst) continue; // older version
                last_dst = e.dst;
                if ((e.flags & types.tombstone) != 0) continue;
                try dsts.append(gpa, e.dst);
                try weights.append(gpa, e.weight);
                has_negative = has_negative or e.weight < 0;
            }
            if (dsts.items.len > row_start) {
                try srcs.append(gpa, vid);
                try row_ends.append(gpa, dsts.items.len);
            }
        }

        // A destination with no edges of its own (directed mode) is a vertex too.
        var extra: std.ArrayList(u64) = .empty;
        defer extra.deinit(gpa);
        for (dsts.items) |d| {
            if (findSorted(srcs.items, d) == null) try extra.append(gpa, d);
        }
        std.mem.sort(u64, extra.items, {}, std.sort.asc(u64));

        const vid = try gpa.alloc(u64, srcs.items.len + extra.items.len);
        errdefer gpa.free(vid);
        var nv: usize = 0;
        {
            var a: usize = 0;
            var b: usize = 0;
            while (a < srcs.items.len or b < extra.items.len) {
                const take_a = b == extra.items.len or
                    (a < srcs.items.len and srcs.items[a] <= extra.items[b]);
                const x = if (take_a) srcs.items[a] else extra.items[b];
                if (take_a) a += 1 else b += 1;
                if (nv == 0 or vid[nv - 1] != x) {
                    vid[nv] = x;
                    nv += 1;
                }
            }
        }
        if (nv > std.math.maxInt(u32)) {
            gpa.free(vid);
            return error.InvalidArgument;
        }
        const vids = gpa.realloc(vid, nv) catch vid[0..nv];
        errdefer gpa.free(vids);

        const rowptr = try gpa.alloc(u64, nv + 1);
        errdefer gpa.free(rowptr);
        const col = try gpa.alloc(u32, dsts.items.len);
        errdefer gpa.free(col);
        const deg = try gpa.alloc(f64, nv);
        errdefer gpa.free(deg);
        const inv = try gpa.alloc(f64, nv);
        errdefer gpa.free(inv);

        var si: usize = 0;
        var start: u64 = 0;
        rowptr[0] = 0;
        for (vids, 0..) |x, i| {
            var d: f64 = 0;
            if (si < srcs.items.len and srcs.items[si] == x) {
                const end = row_ends.items[si];
                // Columns ascend within a row, so each search starts at the last hit.
                var from: usize = 0;
                for (start..end) |k| {
                    const at = lowerBound(u64, vids, from, dsts.items[k]);
                    col[k] = @intCast(at);
                    from = at + 1;
                    d += weights.items[k];
                }
                start = end;
                si += 1;
            }
            rowptr[i + 1] = start;
            deg[i] = d;
            inv[i] = if (d > 0) 1.0 / @sqrt(d) else 0;
        }

        const w = try weights.toOwnedSlice(gpa);
        errdefer gpa.free(w);
        const g = try gpa.create(CsrView);
        g.* = .{
            .gpa = gpa,
            .vid = vids,
            .rowptr = rowptr,
            .col = col,
            .w = w,
            .inv_sqrt_deg = inv,
            .deg = deg,
            .built_at_seq = built_at_seq,
            .has_negative = has_negative,
        };
        return g;
    }
};

/// First index >= `from` whose value is >= x. Gallops, so a search that lands
/// near `from` costs little.
fn lowerBound(comptime T: type, s: []const T, from: usize, x: T) usize {
    var lo = from;
    var step: usize = 1;
    var hi = from;
    while (hi < s.len and s[hi] < x) {
        lo = hi + 1;
        hi += step;
        step *= 2;
    }
    hi = @min(hi, s.len);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (s[mid] < x) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn findSorted(s: []const u64, x: u64) ?u32 {
    const i = std.sort.lowerBound(u64, s, x, struct {
        fn cmp(c: u64, e: u64) std.math.Order {
            return std.math.order(c, e);
        }
    }.cmp);
    if (i == s.len or s[i] != x) return null;
    return @intCast(i);
}

fn csrApply(ctx: *const anyopaque, x: []const f64, y: []f64) void {
    const g: *const CsrView = @ptrCast(@alignCast(ctx));
    for (y, 0..) |*yi, i| {
        var acc: f64 = 0;
        for (g.rowptr[i]..g.rowptr[i + 1]) |k| acc += @as(f64, g.w[k]) * x[g.col[k]];
        yi.* = acc;
    }
}

/// y = A x over the base view.
pub fn adjacency(g: *const CsrView) LinOp {
    return .{ .n = g.n(), .ctx = g, .applyFn = csrApply };
}

// ---- delta ------------------------------------------------------------------

/// A_snap - A_base as COO triples sorted by (i, j), plus the degrees of
/// A_snap. Indices past `base.n()` are vertices the base has never seen.
pub const Delta = struct {
    gpa: Allocator,
    base: *const CsrView,
    ext_vid: []u64, // sorted; dense index base.n() + k
    i: []u32,
    j: []u32,
    dw: []f64,
    /// Row `r` of the delta is `dptr[r]..dptr[r + 1]`.
    dptr: []u32,
    deg: []f64,
    has_negative: bool,

    pub fn n(d: *const Delta) usize {
        return d.deg.len;
    }

    pub fn deinit(d: *Delta) void {
        const gpa = d.gpa;
        gpa.free(d.ext_vid);
        gpa.free(d.i);
        gpa.free(d.j);
        gpa.free(d.dw);
        gpa.free(d.dptr);
        gpa.free(d.deg);
    }

    pub fn vidOf(d: *const Delta, i: usize) u64 {
        const nb = d.base.n();
        return if (i < nb) d.base.vid[i] else d.ext_vid[i - nb];
    }

    pub fn indexOf(d: *const Delta, vid: u64) ?u32 {
        if (d.base.indexOf(vid)) |i| return i;
        const k = findSorted(d.ext_vid, vid) orelse return null;
        return @intCast(d.base.n() + k);
    }

    /// Compute the delta as target minus base for every edge the snapshot's
    /// MemGraphs mention, not from the records alone: a snapshot taken between
    /// a flush installing its segment and `imm` clearing has the same record in
    /// the base and in the delta, and that must come out as no change.
    ///
    /// Each vertex is read under a brief shared lock, so writers keep going.
    pub fn build(gpa: Allocator, base: *const CsrView, s: *const Snapshot) Error!Delta {
        var keys: std.ArrayList(u64) = .empty;
        defer keys.deinit(gpa);
        try s.mem.keys(gpa, &keys);
        if (s.imm) |m| try m.keys(gpa, &keys);
        std.mem.sort(u64, keys.items, {}, std.sort.asc(u64));

        const Change = struct { src: u64, dst: u64, dw: f64 };
        var changes: std.ArrayList(Change) = .empty;
        defer changes.deinit(gpa);
        var recs: std.ArrayList(EdgeRec) = .empty;
        defer recs.deinit(gpa);

        var has_negative = false;
        var prev_key: ?u64 = null;
        for (keys.items) |src| {
            if (prev_key == src) continue;
            prev_key = src;
            recs.clearRetainingCapacity();
            try s.mem.collect(gpa, src, s.seq, &recs);
            if (s.imm) |m| try m.collect(gpa, src, s.seq, &recs); // re-sorts both
            const bi = base.indexOf(src);
            var last_dst: ?u64 = null;
            for (recs.items) |e| {
                if (last_dst == e.dst) continue; // older version
                last_dst = e.dst;
                const dead = (e.flags & types.tombstone) != 0;
                const target: f64 = if (dead) 0 else e.weight;
                has_negative = has_negative or target < 0;
                var old: f64 = 0;
                if (bi) |row| if (base.indexOf(e.dst)) |cj| {
                    if (base.weight(row, cj)) |w| old = w;
                };
                if (target != old) try changes.append(gpa, .{ .src = src, .dst = e.dst, .dw = target - old });
            }
        }

        var ext: std.ArrayList(u64) = .empty;
        defer ext.deinit(gpa);
        for (changes.items) |c| {
            if (base.indexOf(c.src) == null) try ext.append(gpa, c.src);
            if (base.indexOf(c.dst) == null) try ext.append(gpa, c.dst);
        }
        std.mem.sort(u64, ext.items, {}, std.sort.asc(u64));
        var w_idx: usize = 0;
        for (ext.items) |x| {
            if (w_idx == 0 or ext.items[w_idx - 1] != x) {
                ext.items[w_idx] = x;
                w_idx += 1;
            }
        }
        ext.shrinkRetainingCapacity(w_idx);

        const nb = base.n();
        const n_total = nb + ext.items.len;
        if (n_total > std.math.maxInt(u32)) return error.InvalidArgument;

        const Triple = struct { i: u32, j: u32, dw: f64 };
        const triples = try gpa.alloc(Triple, changes.items.len);
        defer gpa.free(triples);
        const dense = struct {
            fn of(b: *const CsrView, e: []const u64, vid: u64) u32 {
                if (b.indexOf(vid)) |i| return i;
                return @intCast(b.n() + findSorted(e, vid).?);
            }
        };
        for (changes.items, triples) |c, *t| {
            t.* = .{ .i = dense.of(base, ext.items, c.src), .j = dense.of(base, ext.items, c.dst), .dw = c.dw };
        }
        std.mem.sort(Triple, triples, {}, struct {
            fn less(_: void, a: Triple, b: Triple) bool {
                return if (a.i != b.i) a.i < b.i else a.j < b.j;
            }
        }.less);

        const ext_vid = try gpa.dupe(u64, ext.items);
        errdefer gpa.free(ext_vid);
        const ti = try gpa.alloc(u32, triples.len);
        errdefer gpa.free(ti);
        const tj = try gpa.alloc(u32, triples.len);
        errdefer gpa.free(tj);
        const dw = try gpa.alloc(f64, triples.len);
        errdefer gpa.free(dw);
        const dptr = try gpa.alloc(u32, n_total + 1);
        errdefer gpa.free(dptr);
        const deg = try gpa.alloc(f64, n_total);
        errdefer gpa.free(deg);

        @memset(deg, 0);
        @memcpy(deg[0..nb], base.deg);
        @memset(dptr, 0);
        for (triples, ti, tj, dw) |t, *a, *b, *c| {
            a.* = t.i;
            b.* = t.j;
            c.* = t.dw;
            deg[t.i] += t.dw;
            dptr[t.i + 1] += 1;
        }
        for (1..dptr.len) |r| dptr[r] += dptr[r - 1];

        return .{
            .gpa = gpa,
            .base = base,
            .ext_vid = ext_vid,
            .i = ti,
            .j = tj,
            .dw = dw,
            .dptr = dptr,
            .deg = deg,
            .has_negative = has_negative,
        };
    }
};

/// Decorator: y = (A + Delta) x, over any base operator.
pub const DeltaCtx = struct {
    base: LinOp,
    delta: *const Delta,

    fn apply(ctx: *const anyopaque, x: []const f64, y: []f64) void {
        const c: *const DeltaCtx = @ptrCast(@alignCast(ctx));
        const nb = c.base.n;
        c.base.apply(x[0..nb], y[0..nb]);
        @memset(y[nb..], 0);
        for (c.delta.i, c.delta.j, c.delta.dw) |i, j, dw| y[i] += dw * x[j];
    }

    pub fn op(c: *const DeltaCtx) LinOp {
        return .{ .n = c.delta.n(), .ctx = c, .applyFn = apply };
    }
};

/// Decorator: y = (x + D^-1/2 A D^-1/2 x) / 2, the normalized adjacency shifted
/// so its spectrum lies in [0, 1]. `inv` is zero outside the component being
/// solved; with x zero there too, those entries stay exactly zero.
pub const ShiftedNorm = struct {
    a: LinOp,
    inv: []const f64,
    tmp: []f64,

    fn apply(ctx: *const anyopaque, x: []const f64, y: []f64) void {
        const c: *const ShiftedNorm = @ptrCast(@alignCast(ctx));
        for (c.tmp, x, c.inv) |*t, xi, s| t.* = s * xi;
        c.a.apply(c.tmp, y);
        for (y, x, c.inv) |*yi, xi, s| yi.* = 0.5 * (xi + s * yi.*);
    }

    pub fn op(c: *const ShiftedNorm) LinOp {
        return .{ .n = c.a.n, .ctx = c, .applyFn = apply };
    }
};

/// Decorator: y = (x + A x) / 2. For eigenvector centrality.
const ShiftedAdj = struct {
    a: LinOp,

    fn apply(ctx: *const anyopaque, x: []const f64, y: []f64) void {
        const c: *const ShiftedAdj = @ptrCast(@alignCast(ctx));
        c.a.apply(x, y);
        for (y, x) |*yi, xi| yi.* = 0.5 * (xi + yi.*);
    }

    fn op(c: *const ShiftedAdj) LinOp {
        return .{ .n = c.a.n, .ctx = c, .applyFn = apply };
    }
};

// ---- solvers ----------------------------------------------------------------

pub const FiedlerResult = struct {
    lambda2: f64,
    /// Operator applications.
    iters: u32,
    converged: bool,
};

/// Deflated power iteration. `S` is the shifted operator and `triv` the unit
/// trivial eigenvector. v: in = warm start (or random), out = Fiedler vector.
pub fn fiedler(gpa: Allocator, S: LinOp, triv: []const f64, v: []f64, max_iter: u32, tol: f64) Allocator.Error!FiedlerResult {
    const y = try gpa.alloc(f64, S.n);
    defer gpa.free(y);

    projectOut(v, triv);
    normalize(v);
    var mu: f64 = 0;
    var it: u32 = 0;
    var converged = false;
    while (it < max_iter) {
        S.apply(v, y);
        projectOut(y, triv); // stay orthogonal to the trivial vector
        mu = dot(v, y); // Rayleigh quotient of S
        normalize(y);
        const change = distSq(v, y);
        @memcpy(v, y);
        it += 1;
        if (change < tol * tol) {
            converged = true;
            break;
        }
    }
    return .{ .lambda2 = 2.0 * (1.0 - mu), .iters = it, .converged = converged };
}

/// Restarted Lanczos with full reorthogonalization, deflated against `triv`.
/// Same operator and same contract as `fiedler`; `tol` bounds the residual
/// `|S v - mu v|`. Holds `basis` vectors of length n in memory.
pub fn lanczos(gpa: Allocator, S: LinOp, triv: []const f64, v: []f64, basis: u32, max_iter: u32, tol: f64) Error!FiedlerResult {
    const n = S.n;
    const m: usize = @min(basis, @max(n, 2) - 1);
    const q = try gpa.alloc(f64, (m + 1) * n);
    defer gpa.free(q);
    const alpha = try gpa.alloc(f64, m);
    defer gpa.free(alpha);
    const beta = try gpa.alloc(f64, m);
    defer gpa.free(beta);
    const d = try gpa.alloc(f64, m);
    defer gpa.free(d);
    const e = try gpa.alloc(f64, m);
    defer gpa.free(e);
    const z = try gpa.alloc(f64, m * m);
    defer gpa.free(z);

    projectOut(v, triv);
    normalize(v);
    var applied: u32 = 0;
    var mu: f64 = 0;
    var converged = false;
    while (applied < max_iter and !converged) {
        @memcpy(q[0..n], v);
        var k: usize = 0; // steps this restart
        var last_beta: f64 = 0;
        while (k < m and applied < max_iter) {
            const qk = q[k * n..][0..n];
            const w = q[(k + 1) * n..][0..n];
            S.apply(qk, w);
            applied += 1;
            projectOut(w, triv);
            alpha[k] = dot(qk, w);
            // Twice is enough to keep the basis orthogonal to working precision.
            for (0..2) |_| {
                for (0..k + 1) |i| projectOut(w, q[i * n..][0..n]);
            }
            last_beta = norm(w);
            beta[k] = last_beta;
            k += 1;
            if (last_beta < 1e-14) break; // invariant subspace: exact answer
            for (w) |*x| x.* /= last_beta;
        }
        if (k == 0) break;

        @memcpy(d[0..k], alpha[0..k]);
        @memcpy(e[0 .. k - 1], beta[0 .. k - 1]);
        e[k - 1] = 0;
        @memset(z[0 .. k * k], 0);
        for (0..k) |i| z[i * k + i] = 1;
        try tridiagEigen(d[0..k], e[0..k], z[0 .. k * k]);

        var top: usize = 0;
        for (0..k) |i| {
            if (d[i] > d[top]) top = i;
        }
        mu = d[top];
        @memset(v, 0);
        for (0..k) |i| axpy(z[i * k + top], q[i * n..][0..n], v);
        projectOut(v, triv);
        normalize(v);
        const residual = @abs(last_beta * z[(k - 1) * k + top]);
        converged = residual < tol;
    }
    return .{ .lambda2 = 2.0 * (1.0 - mu), .iters = applied, .converged = converged };
}

/// Implicit QL for a symmetric tridiagonal matrix. d: diagonal in, eigenvalues
/// out. e: off-diagonal in e[0..n-1], e[n-1] unused; destroyed. z: identity in,
/// row-major eigenvectors out (column c is the vector for d[c]).
fn tridiagEigen(d: []f64, e: []f64, z: []f64) Error!void {
    const n = d.len;
    const eps = std.math.floatEps(f64);
    for (0..n) |l| {
        var iter: u32 = 0;
        while (true) {
            var m = l;
            while (m + 1 < n) : (m += 1) {
                const dd = @abs(d[m]) + @abs(d[m + 1]);
                if (@abs(e[m]) <= eps * dd) break;
            }
            if (m == l) break;
            iter += 1;
            if (iter > 100) return error.InvalidArgument; // cannot happen on finite input

            var g = (d[l + 1] - d[l]) / (2.0 * e[l]);
            var r = std.math.hypot(g, 1.0);
            g = d[m] - d[l] + e[l] / (g + std.math.copysign(r, g));
            var s: f64 = 1;
            var c: f64 = 1;
            var p: f64 = 0;
            var underflow = false;
            var i = m;
            while (i > l) {
                i -= 1;
                const f = s * e[i];
                const b = c * e[i];
                r = std.math.hypot(f, g);
                e[i + 1] = r;
                if (r == 0) {
                    d[i + 1] -= p;
                    e[m] = 0;
                    underflow = true;
                    break;
                }
                s = f / r;
                c = g / r;
                g = d[i + 1] - p;
                r = (d[i] - g) * s + 2.0 * c * b;
                p = s * r;
                d[i + 1] = g + p;
                g = c * r - b;
                for (0..n) |row| {
                    const zr = z[row * n ..][0..n];
                    const t = zr[i + 1];
                    zr[i + 1] = s * zr[i] + c * t;
                    zr[i] = c * zr[i] - s * t;
                }
            }
            if (underflow) continue;
            d[l] -= p;
            e[l] = g;
            e[m] = 0;
        }
    }
}

// ---- running against a snapshot ---------------------------------------------

/// A_snap ready to solve on: the operator, and the largest connected component.
const Prepared = struct {
    gpa: Allocator,
    delta: Delta,
    delta_ctx: DeltaCtx,
    /// Dense indices of the component, ascending in position.
    comp: []u32,
    in_comp: []bool,

    /// `self` must not move: the operator points into it.
    fn init(self: *Prepared, gpa: Allocator, s: *const Snapshot) Error!void {
        if (!s.db.opts.undirected) return error.InvalidArgument; // A must be symmetric
        const base = try s.csrView();
        var delta = try Delta.build(gpa, base, s);
        errdefer delta.deinit();
        if (base.has_negative or delta.has_negative) return error.InvalidArgument;

        const n = delta.n();
        const in_comp = try gpa.alloc(bool, n);
        errdefer gpa.free(in_comp);
        const comp = try largestComponent(gpa, &delta, in_comp);
        self.* = .{ .gpa = gpa, .delta = delta, .delta_ctx = undefined, .comp = comp, .in_comp = in_comp };
        self.delta_ctx = .{ .base = adjacency(base), .delta = &self.delta };
    }

    fn deinit(p: *Prepared) void {
        p.delta.deinit();
        p.gpa.free(p.comp);
        p.gpa.free(p.in_comp);
    }

    fn op(p: *const Prepared) LinOp {
        return p.delta_ctx.op();
    }
};

/// Find the largest component of A_snap, over edges of non-zero weight. Sets
/// `mask` and returns its members, sorted. Ties go to the lowest dense index.
fn largestComponent(gpa: Allocator, d: *const Delta, mask: []bool) Error![]u32 {
    const n = d.n();
    const base = d.base;
    const nb = base.n();
    const label = try gpa.alloc(u32, n);
    defer gpa.free(label);
    const none = std.math.maxInt(u32);
    @memset(label, none);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);

    var best_label: u32 = none;
    var best_size: usize = 0;
    var next_label: u32 = 0;
    for (0..n) |start| {
        if (label[start] != none or d.deg[start] <= 0) continue;
        const l = next_label;
        next_label += 1;
        var size: usize = 0;
        label[start] = l;
        try stack.append(gpa, @intCast(start));
        while (stack.pop()) |x| {
            size += 1;
            const lo: usize = if (x < nb) @intCast(base.rowptr[x]) else 0;
            const hi: usize = if (x < nb) @intCast(base.rowptr[x + 1]) else 0;
            var p: usize = d.dptr[x];
            const pend: usize = d.dptr[x + 1];
            var k = lo;
            // Walk the base row and the delta row together; both are sorted.
            while (k < hi or p < pend) {
                const bj: u32 = if (k < hi) base.col[k] else none;
                const dj: u32 = if (p < pend) d.j[p] else none;
                const j = @min(bj, dj);
                var w: f64 = 0;
                if (bj == j) {
                    w += base.w[k];
                    k += 1;
                }
                if (dj == j) {
                    w += d.dw[p];
                    p += 1;
                }
                if (w > 0 and label[j] == none) {
                    label[j] = l;
                    try stack.append(gpa, j);
                }
            }
        }
        if (size > best_size) {
            best_size = size;
            best_label = l;
        }
    }

    const comp = try gpa.alloc(u32, best_size);
    errdefer gpa.free(comp);
    var c: usize = 0;
    for (label, mask, 0..) |l, *m, i| {
        m.* = l == best_label and l != none;
        if (m.*) {
            comp[c] = @intCast(i);
            c += 1;
        }
    }
    return comp;
}

pub const Method = enum { power, lanczos };

pub const FiedlerOptions = struct {
    method: Method = .power,
    /// Most operator applications.
    max_iter: u32 = 100_000,
    /// Power iteration: stop when the iterate moves less than this.
    /// Lanczos: stop when the eigen-residual is below this.
    tol: f64 = 1e-9,
    /// Lanczos vectors held in memory.
    lanczos_basis: u32 = 64,
    /// Previous result: reused as the starting vector, matched by vertex id.
    warm: ?*const FiedlerRun = null,
    seed: u64 = 1,
};

/// The Fiedler vector of the snapshot's largest connected component.
pub const FiedlerRun = struct {
    gpa: Allocator,
    /// Vertex ids of the component, sorted, and the vector's entry for each.
    vid: []u64,
    value: []f64,
    lambda2: f64,
    iters: u32,
    converged: bool,
    /// |S v - mu v| of the returned vector, whatever the method's own test was.
    residual: f64,
    /// Vertices in the whole graph, connected or not.
    n_vertices: usize,

    pub fn deinit(r: *FiedlerRun) void {
        r.gpa.free(r.vid);
        r.gpa.free(r.value);
    }

    pub fn valueOf(r: *const FiedlerRun, vid: u64) ?f64 {
        const i = findSorted(r.vid, vid) orelse return null;
        return r.value[i];
    }
};

/// Sort (vid, value) pairs by vid, into freshly allocated arrays.
fn sortedByVid(gpa: Allocator, d: *const Delta, comp: []const u32, v: []const f64) Allocator.Error!struct { []u64, []f64 } {
    const P = struct { vid: u64, x: f64 };
    const ps = try gpa.alloc(P, comp.len);
    defer gpa.free(ps);
    for (comp, ps) |i, *p| p.* = .{ .vid = d.vidOf(i), .x = v[i] };
    std.mem.sort(P, ps, {}, struct {
        fn less(_: void, a: P, b: P) bool {
            return a.vid < b.vid;
        }
    }.less);
    const vid = try gpa.alloc(u64, ps.len);
    errdefer gpa.free(vid);
    const val = try gpa.alloc(f64, ps.len);
    for (ps, vid, val) |p, *a, *b| {
        a.* = p.vid;
        b.* = p.x;
    }
    return .{ vid, val };
}

/// Second eigenvector of the normalized Laplacian of `s`, on its largest
/// connected component. `error.InvalidArgument` if the store is directed, holds
/// a negative weight, or the component is smaller than `min_component`.
pub fn fiedlerOf(gpa: Allocator, s: *const Snapshot, o: FiedlerOptions) Error!FiedlerRun {
    var p: Prepared = undefined;
    try p.init(gpa, s);
    defer p.deinit();
    const n = p.delta.n();
    if (p.comp.len < min_component) return error.InvalidArgument;

    const inv = try gpa.alloc(f64, n);
    defer gpa.free(inv);
    const triv = try gpa.alloc(f64, n);
    defer gpa.free(triv);
    const v = try gpa.alloc(f64, n);
    defer gpa.free(v);
    const tmp = try gpa.alloc(f64, n);
    defer gpa.free(tmp);
    const y = try gpa.alloc(f64, n);
    defer gpa.free(y);

    // Outside the component everything is zero, so the operator leaves it
    // alone. Extracting a subgraph would cost a copy of the edges.
    for (p.in_comp, p.delta.deg, inv, triv) |on, dg, *a, *b| {
        a.* = if (on) 1.0 / @sqrt(dg) else 0;
        b.* = if (on) @sqrt(dg) else 0;
    }
    normalize(triv);

    @memset(v, 0);
    var warm_ok = false;
    if (o.warm) |w| {
        for (p.comp) |i| v[i] = w.valueOf(p.delta.vidOf(i)) orelse 0; // new vertices start at 0
        projectOut(v, triv);
        warm_ok = norm(v) > 1e-9;
    }
    if (!warm_ok) {
        var prng = std.Random.DefaultPrng.init(o.seed);
        const rnd = prng.random();
        for (p.comp) |i| v[i] = rnd.float(f64) - 0.5;
    }

    const sn: ShiftedNorm = .{ .a = p.op(), .inv = inv, .tmp = tmp };
    const S = sn.op();
    const res = switch (o.method) {
        .power => try fiedler(gpa, S, triv, v, o.max_iter, o.tol),
        .lanczos => try lanczos(gpa, S, triv, v, o.lanczos_basis, o.max_iter, o.tol),
    };

    S.apply(v, y);
    projectOut(y, triv);
    const mu = dot(v, y);
    axpy(-mu, v, y);

    const sorted = try sortedByVid(gpa, &p.delta, p.comp, v);
    return .{
        .gpa = gpa,
        .vid = sorted[0],
        .value = sorted[1],
        .lambda2 = res.lambda2,
        .iters = res.iters,
        .converged = res.converged,
        .residual = norm(y),
        .n_vertices = n,
    };
}

/// Smaller components have no meaningful second eigenvector.
pub const min_component = 3;

pub const CentralityRun = struct {
    gpa: Allocator,
    vid: []u64,
    value: []f64, // unit length, non-negative
    /// Largest eigenvalue of the adjacency matrix.
    eigenvalue: f64,
    iters: u32,
    converged: bool,

    pub fn deinit(r: *CentralityRun) void {
        r.gpa.free(r.vid);
        r.gpa.free(r.value);
    }

    pub fn valueOf(r: *const CentralityRun, vid: u64) ?f64 {
        const i = findSorted(r.vid, vid) orelse return null;
        return r.value[i];
    }
};

/// Eigenvector centrality of the largest connected component: power iteration
/// on (I + A) / 2, which has the same top eigenvector as A and cannot
/// oscillate on a bipartite graph.
pub fn centralityOf(gpa: Allocator, s: *const Snapshot, o: FiedlerOptions) Error!CentralityRun {
    var p: Prepared = undefined;
    try p.init(gpa, s);
    defer p.deinit();
    const n = p.delta.n();
    if (p.comp.len == 0) return error.InvalidArgument;

    const v = try gpa.alloc(f64, n);
    defer gpa.free(v);
    const y = try gpa.alloc(f64, n);
    defer gpa.free(y);
    @memset(v, 0);
    for (p.comp) |i| v[i] = 1;
    normalize(v);

    const sa: ShiftedAdj = .{ .a = p.op() };
    const S = sa.op();
    var mu: f64 = 0;
    var it: u32 = 0;
    var converged = false;
    while (it < o.max_iter) {
        S.apply(v, y); // zero outside the component: no edge leaves it
        mu = dot(v, y);
        normalize(y);
        const change = distSq(v, y);
        @memcpy(v, y);
        it += 1;
        if (change < o.tol * o.tol) {
            converged = true;
            break;
        }
    }
    const sorted = try sortedByVid(gpa, &p.delta, p.comp, v);
    return .{
        .gpa = gpa,
        .vid = sorted[0],
        .value = sorted[1],
        .eigenvalue = 2.0 * mu - 1.0,
        .iters = it,
        .converged = converged,
    };
}
