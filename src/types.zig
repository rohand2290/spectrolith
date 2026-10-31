const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ Io, Corrupt, InvalidArgument, Locked } || Allocator.Error;

pub const tombstone: u32 = 0x1;

/// `extern struct` pins the layout, so on-disk bytes match memory (used by
/// segments from phase 2; MemGraph stores the same record).
pub const EdgeRec = extern struct {
    dst: u64,
    seq: u64, // global sequence number, strictly increasing per write
    weight: f32,
    flags: u32, // `tombstone` marks a delete
};

comptime {
    std.debug.assert(@sizeOf(EdgeRec) == 24);
    std.debug.assert(@alignOf(EdgeRec) == 8);
}

pub const Edge = struct { dst: u64, weight: f32 };

/// Order within one vertex: dst ascending, then seq descending (newest first).
pub fn edgeLess(_: void, x: EdgeRec, y: EdgeRec) bool {
    if (x.dst != y.dst) return x.dst < y.dst;
    return x.seq > y.seq;
}
