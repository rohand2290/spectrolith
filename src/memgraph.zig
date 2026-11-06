//! In-memory write buffer: vertex id -> append-only edge list, all memory from
//! one arena. One writer appends while many readers scan under a RwLock.
const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const types = @import("types.zig");
const batch_mod = @import("batch.zig");
const EdgeRec = types.EdgeRec;

pub const MemGraph = struct {
    gpa: Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    lock: sys.RwLock = .{},
    arena: std.heap.ArenaAllocator,
    adj: std.AutoHashMapUnmanaged(u64, std.ArrayList(EdgeRec)) = .empty,
    /// Payload bytes appended (24 per record). Arena slack from list growth is
    /// not counted; the flush threshold is approximate by that much.
    bytes: usize = 0,

    pub fn create(gpa: Allocator) Allocator.Error!*MemGraph {
        const m = try gpa.create(MemGraph);
        m.* = .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
        return m;
    }

    pub fn ref(m: *MemGraph) *MemGraph {
        _ = m.refs.fetchAdd(1, .monotonic);
        return m;
    }

    pub fn unref(m: *MemGraph) void {
        if (m.refs.fetchSub(1, .acq_rel) != 1) return;
        const gpa = m.gpa;
        m.arena.deinit(); // frees every list and the map's table in one call
        gpa.destroy(m);
    }

    /// Append `ops`, giving op i the sequence number first_seq + i.
    /// Records are invisible to snapshots older than their seq, so the caller
    /// publishes `last_seq` only after this returns.
    pub fn apply(m: *MemGraph, first_seq: u64, ops: []const batch_mod.Op) Allocator.Error!void {
        m.lock.lock();
        defer m.lock.unlock();
        const a = m.arena.allocator();
        for (ops, 0..) |op, i| {
            const gop = try m.adj.getOrPut(a, op.src);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, .{
                .dst = op.dst,
                .seq = first_seq + i,
                .weight = op.weight,
                .flags = if (op.kind == .del) types.tombstone else 0,
            });
            m.bytes += @sizeOf(EdgeRec);
        }
    }

    /// Append every vertex id to `out`.
    pub fn keys(m: *MemGraph, gpa: Allocator, out: *std.ArrayList(u64)) Allocator.Error!void {
        m.lock.lockShared();
        defer m.lock.unlock();
        try out.ensureUnusedCapacity(gpa, m.adj.count());
        var it = m.adj.keyIterator();
        while (it.next()) |k| out.appendAssumeCapacity(k.*);
    }

    /// Append the records of vertex `v` with seq <= snap_seq to `out`, then
    /// sort all of `out` by (dst asc, seq desc). Copying under the shared lock
    /// means the caller can sort and merge without holding it.
    pub fn collect(m: *MemGraph, gpa: Allocator, v: u64, snap_seq: u64, out: *std.ArrayList(EdgeRec)) Allocator.Error!void {
        {
            m.lock.lockShared();
            defer m.lock.unlock();
            if (m.adj.get(v)) |list| {
                try out.ensureUnusedCapacity(gpa, list.items.len);
                for (list.items) |r| {
                    if (r.seq <= snap_seq) out.appendAssumeCapacity(r);
                }
            }
        }
        std.mem.sort(EdgeRec, out.items, {}, types.edgeLess);
    }
};
