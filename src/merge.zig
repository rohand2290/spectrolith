//! Sorted runs and their k-way merge order, shared by neighbor scans (db.zig)
//! and compaction.
const std = @import("std");
const types = @import("types.zig");
const EdgeRec = types.EdgeRec;

/// One sorted run: a MemGraph copy or one segment's records of a vertex.
pub const Run = struct {
    recs: []const EdgeRec, // (dst asc, seq desc)
    pos: usize = 0,
};

/// Heap order: (dst asc, seq desc), so the newest version of an edge pops first.
pub fn runOrder(_: void, a: Run, b: Run) std.math.Order {
    const x = a.recs[a.pos];
    const y = b.recs[b.pos];
    if (x.dst != y.dst) return std.math.order(x.dst, y.dst);
    return std.math.order(y.seq, x.seq);
}

pub const RunHeap = std.PriorityQueue(Run, void, runOrder);
