//! kill -9 crash test.
//!
//! Each round: fork a child that writes deterministic batches and reports each
//! acknowledged batch index over a pipe; SIGKILL it at a random moment;
//! reopen the database; check that
//!   1. every acknowledged batch survived,
//!   2. no batch is half applied (last_seq lands exactly on a batch boundary),
//!   3. the recovered graph equals a model that replays the same batches,
//!   4. recovery is idempotent and the log keeps accepting writes afterwards.
//!
//! usage: crashtest [rounds=50] [seed=1] [dir=.zig-cache/crashtest] [leveled|tiered]
//! A failing round prints its seed and round number.
const std = @import("std");
const c = std.c;
const sp = @import("spectrolith");

const base_dst: u64 = 1_000_000;

var style: sp.CompactionStyle = .leveled;

/// Tiny MemGraph limit so the child flushes a segment every ~10 batches and
/// kills land inside flushes (segment write, rename, log swap) too.
const memgraph_limit: usize = 1500;

/// Tiny levels as well, so a flush every ~10 batches also triggers L0 -> L1 and
/// deeper compactions on the background thread, and kills land inside merges,
/// manifest appends and file deletions.
fn dbOptions(dir: []const u8) sp.Options {
    return .{
        .compaction_style = style,
        .path = dir,
        .memgraph_limit_bytes = memgraph_limit,
        .l0_compaction_trigger = 2,
        .l0_stop_trigger = 4,
        .size_ratio = 2,
        .level1_bytes = 4096,
        .target_segment_bytes = 1024,
    };
}

/// Op list of batch `i`. Deterministic, so the parent can rebuild any prefix.
fn batchOps(gpa: std.mem.Allocator, b: *sp.Batch, i: u64) !void {
    b.clear();
    const n = 1 + (i * 7) % 5;
    for (0..n) |k| try b.put(gpa, i, base_dst + k, @floatFromInt((i + 1) * 1000 + k));
    if (i > 0 and i % 3 == 0) try b.del(gpa, i - 1, base_dst); // exercise tombstones
}

fn seqsInBatch(i: u64) u64 {
    const n = 1 + (i * 7) % 5;
    const ops = n + @as(u64, if (i > 0 and i % 3 == 0) 1 else 0);
    return ops * 2; // undirected: every op is mirrored
}

fn childMain(gpa: std.mem.Allocator, dir: []const u8, ack_fd: c_int) noreturn {
    run(gpa, dir, ack_fd) catch c._exit(2);
    c._exit(0);
}

fn run(gpa: std.mem.Allocator, dir: []const u8, ack_fd: c_int) !void {
    const db = try sp.Db.open(gpa, dbOptions(dir));
    var b: sp.Batch = .{};
    var i: u64 = 0;
    while (i < 1_000_000) : (i += 1) {
        try batchOps(gpa, &b, i);
        try db.write(&b); // returns only once the batch is durable
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, i, .little);
        // The ack is sent *after* write returns: anything acked must survive.
        if (c.write(ack_fd, &buf, 8) != 8) return error.AckFailed;
    }
}

const Key = struct { src: u64, dst: u64 };

fn verify(gpa: std.mem.Allocator, db: *sp.Db, n_batches: u64) !void {
    // Model: replay the same batches against a plain hash map.
    var model: std.AutoHashMap(Key, f32) = .init(gpa);
    defer model.deinit();
    var b: sp.Batch = .{};
    defer b.deinit(gpa);
    for (0..n_batches) |i| {
        try batchOps(gpa, &b, i);
        for (b.ops.items) |op| {
            switch (op.kind) {
                .put => {
                    try model.put(.{ .src = op.src, .dst = op.dst }, op.weight);
                    try model.put(.{ .src = op.dst, .dst = op.src }, op.weight);
                },
                .del => {
                    _ = model.remove(.{ .src = op.src, .dst = op.dst });
                    _ = model.remove(.{ .src = op.dst, .dst = op.src });
                },
            }
        }
    }

    // Check every vertex any batch could have touched: sources 0..n and the
    // five shared destination vertices.
    var s_total: usize = 0;
    const snap = try db.snapshot();
    defer snap.release();
    for (0..n_batches + 5) |idx| {
        const v: u64 = if (idx < n_batches) idx else base_dst + (idx - n_batches);
        var it = try snap.neighbors(gpa, v);
        defer it.deinit();
        var last: ?u64 = null;
        while (it.next()) |e| {
            if (last) |l| if (e.dst <= l) return error.NotSorted;
            last = e.dst;
            const w = model.get(.{ .src = v, .dst = e.dst }) orelse return error.UnexpectedEdge;
            if (w != e.weight) return error.WrongWeight;
            s_total += 1;
        }
    }
    // Every model edge was seen exactly once, so nothing is missing.
    if (s_total != model.count()) return error.EdgeCountMismatch;
}

fn countLogs(gpa: std.mem.Allocator, dir: []const u8) usize {
    const d = gpa.dupeSentinel(u8, dir, 0) catch return 0;
    defer gpa.free(d);
    const dp = c.opendir(d) orelse return 0;
    defer _ = c.closedir(dp);
    var n: usize = 0;
    while (c.readdir(dp)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (std.mem.endsWith(u8, name, ".log")) n += 1;
    }
    return n;
}

fn removeDir(gpa: std.mem.Allocator, dir: []const u8) void {
    const d = gpa.dupeSentinel(u8, dir, 0) catch return;
    defer gpa.free(d);
    if (c.opendir(d)) |dp| {
        // Collect first: unlinking while iterating is unspecified.
        var names: std.ArrayList([:0]u8) = .empty;
        defer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        while (c.readdir(dp)) |ent| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const p = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, name }, 0) catch continue;
            names.append(gpa, p) catch gpa.free(p);
        }
        _ = c.closedir(dp);
        for (names.items) |p| _ = c.unlink(p);
    }
    _ = c.rmdir(d);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const rounds: u32 = if (args.len > 1) try std.fmt.parseInt(u32, args[1], 10) else 50;
    const seed: u64 = if (args.len > 2) try std.fmt.parseInt(u64, args[2], 10) else 1;
    const root: []const u8 = if (args.len > 3) args[3] else ".zig-cache/crashtest";
    if (args.len > 4) style = std.meta.stringToEnum(sp.CompactionStyle, args[4]) orelse return error.Usage;

    {
        const rz = try gpa.dupeSentinel(u8, ".zig-cache", 0);
        defer gpa.free(rz);
        _ = c.mkdir(rz, 0o755);
        const z = try gpa.dupeSentinel(u8, root, 0);
        defer gpa.free(z);
        _ = c.mkdir(z, 0o755);
    }

    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();

    var total_acked: u64 = 0;
    var total_recovered: u64 = 0;
    var mid_flush: u32 = 0;
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        const dir = try std.fmt.allocPrint(gpa, "{s}/round-{d}", .{ root, round });
        defer gpa.free(dir);
        defer removeDir(gpa, dir);
        removeDir(gpa, dir); // leftovers from an earlier aborted run

        var fds: [2]c.fd_t = undefined;
        if (c.pipe(&fds) != 0) return error.PipeFailed;

        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            _ = c.close(fds[0]);
            childMain(std.heap.smp_allocator, dir, fds[1]);
        }
        _ = c.close(fds[1]);

        // Log-spaced delay, 8 ms to ~1 s. Each fsync takes milliseconds, so
        // anything much shorter dies before the first ack; this range lands in
        // creation, appends, flushes and compactions.
        const delay_us: u64 = 8000 + rnd.uintLessThan(u64, @as(u64, 1) << @intCast(14 + rnd.uintLessThan(u6, 7)));
        var ts: c.timespec = .{ .sec = @intCast(delay_us / 1_000_000), .nsec = @intCast((delay_us % 1_000_000) * 1000) };
        _ = c.nanosleep(&ts, null);
        _ = c.kill(pid, .KILL);

        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
        if ((status & 0x7f) != 9) {
            std.debug.print("FAIL seed={d} round={d}: child exited on its own (status {d}) instead of being killed\n", .{ seed, round, status });
            return error.ChildFailed;
        }

        // More than one log at the kill: rotated, but the flush had not finished.
        if (countLogs(gpa, dir) > 1) mid_flush += 1;

        // Drain acks. The write end is closed (child dead, ours closed) so read hits EOF.
        var acked: u64 = 0; // number of acknowledged batches
        while (true) {
            var buf: [8]u8 = undefined;
            var got: usize = 0;
            while (got < 8) {
                const n = c.read(fds[0], buf[got..].ptr, 8 - got);
                if (n <= 0) break;
                got += @intCast(n);
            }
            if (got < 8) break;
            const idx = std.mem.readInt(u64, &buf, .little);
            if (idx != acked) return error.AckOutOfOrder;
            acked += 1;
        }
        _ = c.close(fds[0]);

        const fail = struct {
            fn at(s: u64, r: u32, comptime fmt: []const u8, a: anytype) error{CrashTestFailed} {
                std.debug.print("FAIL seed={d} round={d}: " ++ fmt ++ "\n", .{ s, r } ++ a);
                return error.CrashTestFailed;
            }
        }.at;

        // Recover.
        const db = sp.Db.open(gpa, dbOptions(dir)) catch |err| return fail(seed, round, "reopen failed: {s}", .{@errorName(err)});
        const last = db.lastSeq();
        const segs = db.segmentCount();

        // last_seq must land exactly on a batch boundary (atomicity).
        var j: u64 = 0;
        var sum: u64 = 0;
        while (sum < last) : (j += 1) sum += seqsInBatch(j);
        if (sum != last) return fail(seed, round, "last_seq {d} is inside a batch (acked {d})", .{ last, acked });

        if (j < acked) return fail(seed, round, "LOST ACKNOWLEDGED WRITES: acked {d} batches, recovered {d}", .{ acked, j });
        if (j > acked + 1) return fail(seed, round, "recovered {d} batches but only {d} were acked", .{ j, acked });

        verify(gpa, db, j) catch |err| return fail(seed, round, "content mismatch after recovery: {s}", .{@errorName(err)});
        db.close();

        // Recovery is idempotent, and the log accepts writes after it.
        {
            const db2 = try sp.Db.open(gpa, dbOptions(dir));
            if (db2.lastSeq() != last) return fail(seed, round, "second recovery changed last_seq", .{});
            var b: sp.Batch = .{};
            defer b.deinit(gpa);
            try batchOps(gpa, &b, j);
            try db2.write(&b);
            db2.close();
            const db3 = try sp.Db.open(gpa, dbOptions(dir));
            defer db3.close();
            if (db3.lastSeq() != last + seqsInBatch(j)) return fail(seed, round, "write after recovery was lost", .{});
            verify(gpa, db3, j + 1) catch |err| return fail(seed, round, "content mismatch after write-after-recovery: {s}", .{@errorName(err)});
        }

        total_acked += acked;
        total_recovered += j;
        std.debug.print("round {d:>3}: killed after {d:>6} us, acked {d:>5}, recovered {d:>5}, segments {d:>2}{s}\n", .{
            round, delay_us, acked, j, segs, if (j > acked) "  (+1 unacked batch survived)" else "",
        });
    }
    std.debug.print("PASS: {d} rounds ({d} killed mid-flush), {d} acknowledged batches, 0 lost (seed {d})\n", .{ rounds, mid_flush, total_acked, seed });
}
