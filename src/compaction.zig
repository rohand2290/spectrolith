//! Compaction: the policy that picks inputs, and the merge that turns them into
//! new segments while dropping versions no snapshot can still read.
//!
//! Installing the result (one VersionEdit through the manifest) is done by
//! `Db`, which owns the locks.
const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const types = @import("types.zig");
const seg_mod = @import("segment.zig");
const merge = @import("merge.zig");
const version_mod = @import("version.zig");
const Segment = seg_mod.Segment;
const Version = version_mod.Version;
const VersionSet = version_mod.VersionSet;
const EdgeRec = types.EdgeRec;
const Error = types.Error;
const max_levels = version_mod.max_levels;

/// Inputs of one compaction. The segment pointers are borrowed from the
/// Version it was picked from, which the caller keeps referenced.
pub const Compaction = struct {
    /// Source level; the output goes to `level + 1`.
    level: u16,
    /// [0]: from `level`. [1]: the segments of `level + 1` that overlap them.
    inputs: [2][]*Segment,

    pub fn deinit(c: Compaction, gpa: Allocator) void {
        gpa.free(c.inputs[0]);
        gpa.free(c.inputs[1]);
    }

    pub fn outLevel(c: Compaction) u16 {
        return c.level + 1;
    }

    /// Vertex range covered by all inputs.
    pub fn range(c: Compaction) struct { lo: u64, hi: u64 } {
        var lo: u64 = std.math.maxInt(u64);
        var hi: u64 = 0;
        for (c.inputs) |segs| for (segs) |s| {
            lo = @min(lo, s.min_vid);
            hi = @max(hi, s.max_vid);
        };
        return .{ .lo = lo, .hi = hi };
    }
};

/// Strategy interface, the same shape as `std.mem.Allocator`: a type-erased
/// pointer plus a table of functions.
pub const CompactionPolicy = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// >= 1 means the level wants compacting.
        score: *const fn (ptr: *anyopaque, v: *const Version, level: u16) f64,
        /// The next compaction to run, or null when nothing needs one.
        pick: *const fn (ptr: *anyopaque, gpa: Allocator, v: *const Version) Error!?Compaction,
        /// Inputs for compacting `level` regardless of its score, or null when
        /// it holds nothing or has nowhere to go.
        pickLevel: *const fn (ptr: *anyopaque, gpa: Allocator, v: *const Version, level: u16) Error!?Compaction,
    };

    pub fn score(p: CompactionPolicy, v: *const Version, level: u16) f64 {
        return p.vtable.score(p.ptr, v, level);
    }

    pub fn pick(p: CompactionPolicy, gpa: Allocator, v: *const Version) Error!?Compaction {
        return p.vtable.pick(p.ptr, gpa, v);
    }

    pub fn pickLevel(p: CompactionPolicy, gpa: Allocator, v: *const Version, level: u16) Error!?Compaction {
        return p.vtable.pickLevel(p.ptr, gpa, v, level);
    }

    /// Highest score over all levels that can be compacted.
    pub fn maxScore(p: CompactionPolicy, v: *const Version) f64 {
        var best: f64 = 0;
        for (0..max_levels - 1) |lvl| best = @max(best, p.score(v, @intCast(lvl)));
        return best;
    }
};

pub const LeveledParams = struct {
    l0_compaction_trigger: u32,
    size_ratio: u32,
    level1_bytes: u64,
};

/// Default, read-optimized policy.
pub const Leveled = struct {
    params: LeveledParams,
    /// Where the last compaction of each level ended, so the next one starts
    /// after it and every key range gets its turn.
    cursor: [max_levels]?u64 = @splat(null),

    pub fn policy(self: *Leveled) CompactionPolicy {
        return .{ .ptr = self, .vtable = &.{ .score = score, .pick = pick, .pickLevel = pickLevel } };
    }

    /// L0 by file count, deeper levels by bytes against their target. The last
    /// level has nowhere to go and never scores.
    fn score(ptr: *anyopaque, v: *const Version, level: u16) f64 {
        const self: *Leveled = @ptrCast(@alignCast(ptr));
        if (level + 1 >= max_levels) return 0;
        if (level == 0) {
            const files: f64 = @floatFromInt(v.levels[0].len);
            return files / @as(f64, @floatFromInt(self.params.l0_compaction_trigger));
        }
        const ratio: f64 = @floatFromInt(self.params.size_ratio);
        const base: f64 = @floatFromInt(self.params.level1_bytes);
        const target = base * std.math.pow(f64, ratio, @floatFromInt(level - 1));
        const have: f64 = @floatFromInt(v.levelBytes(level));
        return have / target;
    }

    fn pick(ptr: *anyopaque, gpa: Allocator, v: *const Version) Error!?Compaction {
        const self: *Leveled = @ptrCast(@alignCast(ptr));
        var best_level: u16 = 0;
        var best: f64 = 0;
        for (0..max_levels - 1) |lvl| {
            const s = score(ptr, v, @intCast(lvl));
            if (s > best) {
                best = s;
                best_level = @intCast(lvl);
            }
        }
        if (best < 1) return null;
        return pickLevel(self, gpa, v, best_level);
    }

    /// Inputs for compacting `level` into `level + 1` regardless of score
    /// (manual compaction). L0 takes every segment; deeper levels take one
    /// segment, rotating through the level, plus what it overlaps below.
    fn pickLevel(ptr: *anyopaque, gpa: Allocator, v: *const Version, level: u16) Error!?Compaction {
        const self: *Leveled = @ptrCast(@alignCast(ptr));
        if (level + 1 >= max_levels) return null;
        const src = v.levels[level];
        if (src.len == 0) return null;

        const in0: []*Segment = blk: {
            if (level == 0) break :blk try gpa.dupe(*Segment, src);
            var idx: usize = 0;
            if (self.cursor[level]) |after| {
                for (src, 0..) |s, i| {
                    if (s.min_vid > after) {
                        idx = i;
                        break;
                    }
                }
            }
            self.cursor[level] = src[idx].max_vid;
            const one = try gpa.alloc(*Segment, 1);
            one[0] = src[idx];
            break :blk one;
        };
        errdefer gpa.free(in0);

        var lo: u64 = std.math.maxInt(u64);
        var hi: u64 = 0;
        for (in0) |s| {
            lo = @min(lo, s.min_vid);
            hi = @max(hi, s.max_vid);
        }
        const in1 = try v.overlapping(gpa, level + 1, lo, hi);
        return .{ .level = level, .inputs = .{ in0, in1 } };
    }
};

/// Write-optimized policy. Every level holds up to T overlapping sorted runs,
/// one file each. A full level is merged whole into one new run on the level
/// below, without touching what is already there, so each record is rewritten
/// once per level instead of about T times. The price is reads, which may have
/// to look at every run of every level.
pub const Tiered = struct {
    params: LeveledParams,

    pub fn policy(self: *Tiered) CompactionPolicy {
        return .{ .ptr = self, .vtable = &.{ .score = score, .pick = pick, .pickLevel = pickLevel } };
    }

    fn score(ptr: *anyopaque, v: *const Version, level: u16) f64 {
        const self: *Tiered = @ptrCast(@alignCast(ptr));
        if (level + 1 >= max_levels) return 0;
        const limit = if (level == 0) self.params.l0_compaction_trigger else self.params.size_ratio;
        return @as(f64, @floatFromInt(v.levels[level].len)) / @as(f64, @floatFromInt(limit));
    }

    fn pick(ptr: *anyopaque, gpa: Allocator, v: *const Version) Error!?Compaction {
        var best_level: u16 = 0;
        var best: f64 = 0;
        for (0..max_levels - 1) |lvl| {
            const s = score(ptr, v, @intCast(lvl));
            if (s > best) {
                best = s;
                best_level = @intCast(lvl);
            }
        }
        if (best < 1) return null;
        return pickLevel(ptr, gpa, v, best_level);
    }

    fn pickLevel(_: *anyopaque, gpa: Allocator, v: *const Version, level: u16) Error!?Compaction {
        if (level + 1 >= max_levels or v.levels[level].len == 0) return null;
        const in0 = try gpa.dupe(*Segment, v.levels[level]);
        errdefer gpa.free(in0);
        return .{ .level = level, .inputs = .{ in0, try gpa.alloc(*Segment, 0) } };
    }
};

/// No segment outside the inputs, at the output level or below, overlaps the
/// compaction's range: nothing older than the inputs can exist for these
/// vertices. Under the tiered policy the output level itself can hold older
/// runs, which is why it is checked too.
pub fn isBottom(v: *const Version, comp: Compaction, lo: u64, hi: u64) bool {
    for (comp.outLevel()..max_levels) |lvl| {
        next: for (v.levels[lvl]) |s| {
            if (s.max_vid < lo or s.min_vid > hi) continue;
            for (comp.inputs[1]) |input| if (input == s) continue :next;
            return false;
        }
    }
    return true;
}

pub const MergeStats = struct {
    bytes_read: u64 = 0,
    /// The part of `bytes_read` that came down from the source level.
    bytes_from_above: u64 = 0,
    bytes_written: u64 = 0,
    records_in: u64 = 0,
    records_out: u64 = 0,
};

pub const MergeParams = struct {
    out_level: u16,
    /// Smallest sequence number any live snapshot reads at.
    oldest_snap: u64,
    is_bottom: bool,
    /// Close an output segment, at a vertex boundary, once it holds this many
    /// bytes of records.
    target_bytes: u64,
    bloom_bits: u32,
};

/// Decide which records of one vertex survive. `runs` yields the vertex's
/// records from every input in (dst asc, seq desc) order. Survivors are
/// appended to `kept`, in the same order.
///
/// A record is dropped only if no live snapshot can ever read it:
///  - shadowed: a newer version of the same edge is already visible to the
///    oldest snapshot, so every snapshot sees that one or something newer;
///  - a tombstone at the bottom that the oldest snapshot already sees past:
///    nothing is left below for it to hide. Above the bottom it must stay, or
///    an older copy of the edge deeper down would come back.
pub fn collectSurvivors(
    gpa: Allocator,
    heap: *merge.RunHeap,
    oldest_snap: u64,
    is_bottom: bool,
    kept: *std.ArrayList(EdgeRec),
    stats: *MergeStats,
) Allocator.Error!void {
    var prev_dst: ?u64 = null;
    var newer_seq: u64 = std.math.maxInt(u64);
    while (heap.pop()) |popped| {
        var r = popped;
        const e = r.recs[r.pos];
        r.pos += 1;
        // Pushing back after a pop never needs to grow the queue.
        if (r.pos < r.recs.len) heap.push(gpa, r) catch unreachable;

        stats.records_in += 1;
        if (prev_dst == null or prev_dst.? != e.dst) { // first (newest) version of this edge
            prev_dst = e.dst;
            newer_seq = std.math.maxInt(u64);
        }
        const shadowed = newer_seq <= oldest_snap;
        const dead_tombstone = (e.flags & types.tombstone) != 0 and e.seq <= oldest_snap and is_bottom;
        newer_seq = e.seq;
        if (shadowed or dead_tombstone) continue;
        try kept.append(gpa, e);
    }
}

/// Merge the inputs into new segments at `p.out_level`, appending each opened
/// output to `outputs`. Outputs are durable files not yet listed in any
/// manifest; on error the caller drops whatever is in `outputs`.
pub fn mergeInputs(
    gpa: Allocator,
    dir: [:0]const u8,
    vs: *VersionSet,
    comp: Compaction,
    p: MergeParams,
    outputs: *std.ArrayList(*Segment),
    stats: *MergeStats,
) Error!void {
    var all: std.ArrayList(*Segment) = .empty;
    defer all.deinit(gpa);
    try all.appendSlice(gpa, comp.inputs[0]);
    try all.appendSlice(gpa, comp.inputs[1]);
    const cursors = try gpa.alloc(usize, all.items.len);
    defer gpa.free(cursors);
    @memset(cursors, 0);
    for (all.items) |s| stats.bytes_read += s.bytes();
    for (comp.inputs[0]) |s| stats.bytes_from_above += s.bytes();

    var heap: merge.RunHeap = .empty;
    defer heap.deinit(gpa);
    var kept: std.ArrayList(EdgeRec) = .empty;
    defer kept.deinit(gpa);
    var w = seg_mod.SegWriter.init(gpa, p.out_level);
    defer w.deinit();
    w.bloom_bits = p.bloom_bits;

    while (true) {
        // Next vertex: the smallest vid any input has not yet consumed.
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
        kept.clearRetainingCapacity();
        try collectSurvivors(gpa, &heap, p.oldest_snap, p.is_bottom, &kept, stats);
        if (kept.items.len == 0) continue; // every record of this vertex was garbage

        // Split only between vertices, so L1 and deeper stay disjoint. A
        // vertex bigger than the target simply gets a segment to itself.
        if (w.vidx.items.len > 0 and w.edgeBytes() >= p.target_bytes) {
            try finishOutput(gpa, dir, vs, &w, outputs, stats);
        }
        try w.addVertex(vid, kept.items);
        stats.records_out += kept.items.len;
    }
    if (w.vidx.items.len > 0) try finishOutput(gpa, dir, vs, &w, outputs, stats);
}

fn finishOutput(
    gpa: Allocator,
    dir: [:0]const u8,
    vs: *VersionSet,
    w: *seg_mod.SegWriter,
    outputs: *std.ArrayList(*Segment),
    stats: *MergeStats,
) Error!void {
    const file_no = vs.newFileNumber();
    _ = try w.finish(dir, file_no);
    const path = try seg_mod.segPath(gpa, dir, file_no, false);
    defer gpa.free(path);
    errdefer sys.unlink(path);
    const seg = try Segment.open(gpa, path, file_no); // re-validates what we wrote
    errdefer seg.unref();
    try outputs.append(gpa, seg);
    stats.bytes_written += seg.bytes();
    w.reset();
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

fn rec(dst: u64, seq: u64, flags: u32) EdgeRec {
    return .{ .dst = dst, .seq = seq, .weight = 1, .flags = flags };
}

fn survivors(runs: []const []const EdgeRec, oldest: u64, bottom: bool) ![]EdgeRec {
    var heap: merge.RunHeap = .empty;
    defer heap.deinit(testing.allocator);
    for (runs) |recs| try heap.push(testing.allocator, .{ .recs = recs });
    var kept: std.ArrayList(EdgeRec) = .empty;
    errdefer kept.deinit(testing.allocator);
    var st: MergeStats = .{};
    try collectSurvivors(testing.allocator, &heap, oldest, bottom, &kept, &st);
    return kept.toOwnedSlice(testing.allocator);
}

test "shadowed versions are dropped only once the oldest snapshot sees the newer one" {
    // edge 5 has versions at seq 9, 6, 3
    const run = [_]EdgeRec{ rec(5, 9, 0), rec(5, 6, 0), rec(5, 3, 0) };
    {
        const k = try survivors(&.{&run}, 10, false); // everyone sees seq 9
        defer testing.allocator.free(k);
        try testing.expectEqual(@as(usize, 1), k.len);
        try testing.expectEqual(@as(u64, 9), k[0].seq);
    }
    {
        const k = try survivors(&.{&run}, 7, false); // a snapshot at 7 reads seq 6
        defer testing.allocator.free(k);
        try testing.expectEqual(@as(usize, 2), k.len);
        try testing.expectEqual(@as(u64, 9), k[0].seq);
        try testing.expectEqual(@as(u64, 6), k[1].seq);
    }
    {
        const k = try survivors(&.{&run}, 2, false); // a snapshot at 2 reads nothing, but 9/6/3 are all newer
        defer testing.allocator.free(k);
        try testing.expectEqual(@as(usize, 3), k.len);
    }
}

test "a tombstone is kept above the bottom and dropped at it" {
    const run = [_]EdgeRec{ rec(5, 9, types.tombstone), rec(5, 3, 0), rec(6, 4, 0) };
    {
        const k = try survivors(&.{&run}, 10, false);
        defer testing.allocator.free(k);
        try testing.expectEqual(@as(usize, 2), k.len); // tombstone(5) + edge 6; put(5) shadowed
        try testing.expect(k[0].flags & types.tombstone != 0);
        try testing.expectEqual(@as(u64, 6), k[1].dst);
    }
    {
        const k = try survivors(&.{&run}, 10, true);
        defer testing.allocator.free(k);
        try testing.expectEqual(@as(usize, 1), k.len); // only edge 6 remains
        try testing.expectEqual(@as(u64, 6), k[0].dst);
    }
    {
        // A snapshot older than the delete still needs to see past it.
        const k = try survivors(&.{&run}, 5, true);
        defer testing.allocator.free(k);
        try testing.expectEqual(@as(usize, 3), k.len);
    }
}

test "records merge across runs in (dst, seq desc) order" {
    const a = [_]EdgeRec{ rec(1, 8, 0), rec(3, 2, 0) };
    const b = [_]EdgeRec{ rec(1, 5, 0), rec(2, 6, 0) };
    const k = try survivors(&.{ &a, &b }, 100, false);
    defer testing.allocator.free(k);
    try testing.expectEqual(@as(usize, 3), k.len);
    try testing.expectEqual(@as(u64, 1), k[0].dst);
    try testing.expectEqual(@as(u64, 8), k[0].seq);
    try testing.expectEqual(@as(u64, 2), k[1].dst);
    try testing.expectEqual(@as(u64, 3), k[2].dst);
}
