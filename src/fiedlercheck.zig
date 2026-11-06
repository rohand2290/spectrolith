//! Numerical check, first half: load an edge list so the graph ends up spread
//! across compacted segments and live MemGraphs, solve on a snapshot, and write
//! what that snapshot sees plus the answer. scripts/check_fiedler.py solves the
//! exported graph with scipy.sparse.linalg.eigsh and compares.
//!
//! usage: fiedlercheck <edges.tsv> <workdir> [mem_percent=5] [method=lanczos]
const std = @import("std");
const c = std.c;
const sp = @import("spectrolith");
const util = @import("benchutil.zig");
const spectral = sp.spectral;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.Usage;
    const work = args[2];
    const mem_percent: usize = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 5;
    const method: spectral.Method = if (args.len > 4 and std.mem.eql(u8, args[4], "power")) .power else .lanczos;

    const edges = try util.loadEdges(gpa, args[1]);
    defer gpa.free(edges);
    util.shuffle(edges, 42);
    try util.mkdir(gpa, work);

    const dbdir = try std.fmt.allocPrint(gpa, "{s}/db", .{work});
    defer gpa.free(dbdir);
    const db = try sp.Db.open(gpa, .{
        .path = dbdir,
        .sync_mode = .none,
        .memgraph_limit_bytes = 16 << 20,
        .level1_bytes = 64 << 20,
    });
    defer db.close();

    const in_mem = edges.len * mem_percent / 100;
    const on_disk = edges[0 .. edges.len - in_mem];
    var b: sp.Batch = .{};
    defer b.deinit(gpa);
    const load = struct {
        fn run(d: *sp.Db, a: std.mem.Allocator, batch: *sp.Batch, es: []const util.InputEdge) !void {
            var i: usize = 0;
            while (i < es.len) {
                batch.clear();
                const end = @min(i + 4096, es.len);
                for (es[i..end]) |e| try batch.put(a, e.u, e.v, e.w);
                try d.write(batch);
                i = end;
            }
        }
    }.run;
    try load(db, gpa, &b, on_disk);
    try db.flush();
    try db.waitForCompaction();
    try load(db, gpa, &b, edges[on_disk.len..]); // stays in memory

    const snap = try db.snapshot();
    defer snap.release();
    const base = try snap.csrView();
    var delta = try spectral.Delta.build(gpa, base, snap);
    defer delta.deinit();

    var run = try spectral.fiedlerOf(gpa, snap, .{
        .method = method,
        .tol = 1e-10,
        .lanczos_basis = 128,
        .max_iter = 2_000_000,
    });
    defer run.deinit();

    // Export the graph as the snapshot sees it, through the public read path.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var w = std.Io.Writer.Allocating.fromArrayList(gpa, &out);
    defer w.deinit();
    var n_edges: u64 = 0;
    for (0..delta.n()) |i| {
        const vid = delta.vidOf(i);
        var it = try snap.neighbors(gpa, vid);
        defer it.deinit();
        while (it.next()) |e| {
            try w.writer.print("{d} {d} {d}\n", .{ vid, e.dst, e.weight });
            n_edges += 1;
        }
    }
    const ep = try std.fmt.allocPrint(gpa, "{s}/edges.tsv", .{work});
    defer gpa.free(ep);
    try util.writeFile(gpa, ep, w.written());

    w.clearRetainingCapacity();
    for (run.vid, run.value) |v, x| try w.writer.print("{d} {e}\n", .{ v, x });
    const fp = try std.fmt.allocPrint(gpa, "{s}/fiedler.tsv", .{work});
    defer gpa.free(fp);
    try util.writeFile(gpa, fp, w.written());

    w.clearRetainingCapacity();
    try w.writer.print(
        "{{\"lambda2\":{e},\"iters\":{d},\"converged\":{},\"residual\":{e},\"n_lcc\":{d},\"n\":{d},\"directed_edges\":{d},\"base_edges\":{d},\"delta_triples\":{d},\"new_vertices\":{d}}}\n",
        .{ run.lambda2, run.iters, run.converged, run.residual, run.vid.len, delta.n(), n_edges, base.edges(), delta.i.len, delta.ext_vid.len },
    );
    const sp2 = try std.fmt.allocPrint(gpa, "{s}/summary.json", .{work});
    defer gpa.free(sp2);
    try util.writeFile(gpa, sp2, w.written());
    std.debug.print("{s}", .{w.written()});
}
