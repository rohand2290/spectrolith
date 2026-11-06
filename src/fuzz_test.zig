//! The readers of untrusted bytes: segment files, WAL files, manifests. None
//! may crash or read out of bounds, whatever they are fed. A CRC stops almost
//! all random damage at the door, so the interesting input is damage with the
//! CRCs repaired: that reaches the structural checks behind them.
//!
//! Each target runs two ways. `zig build test` drives it with a seeded mutator,
//! so the checks run everywhere. `zig build test --fuzz` drives it from Zig's
//! coverage-guided fuzzer.
const std = @import("std");
const testing = std.testing;
const sys = @import("sys.zig");
const types = @import("types.zig");
const seg_mod = @import("segment.zig");
const wal_mod = @import("wal.zig");
const version_mod = @import("version.zig");
const batch_mod = @import("batch.zig");
const Segment = seg_mod.Segment;
const Crc = std.hash.crc.@"CRC-32/ISCSI";
const gpa = testing.allocator;

const max_input = 1 << 14;

// ---- targets ------------------------------------------------------------------

/// If the parse is accepted, every offset it vouches for must be usable. In a
/// safe build a bad one traps here.
fn targetSegment(bytes: []align(8) const u8) !void {
    const p = Segment.parse(bytes) catch |err| switch (err) {
        error.Corrupt => return,
        else => return err,
    };
    var sum: u64 = 0;
    for (p.vidx) |v| {
        for (p.edges[@intCast(v.edge_off)..][0..v.degree]) |e| sum +%= e.dst;
        try testing.expect(p.bloom.len == 0 or seg_mod.bloomMayContain(p.bloom, v.vid));
    }
    std.mem.doNotOptimizeAway(sum);
}

const Sink = struct {
    ops: u64 = 0,
    pub fn applyReplay(s: *Sink, first_seq: u64, ops: []const batch_mod.Op) std.mem.Allocator.Error!void {
        std.mem.doNotOptimizeAway(first_seq);
        s.ops += ops.len;
    }
};

fn targetWal(bytes: []const u8) !void {
    var sink: Sink = .{};
    const r = wal_mod.replay(gpa, bytes, &sink) catch |err| switch (err) {
        error.Corrupt => return,
        else => return err,
    };
    try testing.expect(r.valid_len <= bytes.len);
}

fn targetManifest(bytes: []const u8) !void {
    var live: std.AutoHashMapUnmanaged(u64, u16) = .empty;
    defer live.deinit(gpa);
    var log_number: u64 = 0;
    var next_file: u64 = 0;
    var last_seq: u64 = 0;
    version_mod.replayManifest(gpa, bytes, &live, &log_number, &next_file, &last_seq) catch |err| switch (err) {
        error.Corrupt => return,
        else => return err,
    };
    var it = live.valueIterator();
    while (it.next()) |level| try testing.expect(level.* < version_mod.max_levels);
}

// ---- valid inputs to start from -----------------------------------------------

var dir_counter: std.atomic.Value(u32) = .init(0);

fn rec(dst: u64, seq: u64) types.EdgeRec {
    return .{ .dst = dst, .seq = seq, .weight = 1, .flags = 0 };
}

/// A small valid segment image, 8-aligned.
fn sampleSegment(bloom_bits: u32) ![]align(8) u8 {
    try sys.makeDir(".zig-cache");
    const n = dir_counter.fetchAdd(1, .monotonic);
    const dir = try gpa.printSentinel(".zig-cache/fuzz-{d}-{d}", .{ std.c.getpid(), n }, 0);
    defer gpa.free(dir);
    try sys.makeDir(dir);
    defer sys.rmdir(dir);

    var w = seg_mod.SegWriter.init(gpa, 1);
    defer w.deinit();
    w.bloom_bits = bloom_bits;
    try w.addVertex(5, &.{ rec(1, 9), rec(1, 3), rec(7, 4) });
    try w.addVertex(9, &.{rec(2, 6)});
    try w.addVertex(100, &.{ rec(3, 8), rec(4, 2) });
    _ = try w.finish(dir, 1);

    const path = try seg_mod.segPath(gpa, dir, 1, false);
    defer gpa.free(path);
    defer sys.unlink(path);
    const f = try sys.File.open(path, .read);
    defer f.close();
    const bytes = try f.readAll(gpa);
    defer gpa.free(bytes);
    const out = try gpa.alignedAlloc(u8, .of(u64), bytes.len);
    @memcpy(out, bytes);
    return out;
}

/// Recompute the footer CRCs from the regions a healthy file would have, so a
/// mutation is judged by the structural checks.
fn repairSegment(b: []u8, n_vertices: usize, n_edges: usize, has_bloom: bool) void {
    const voff = @sizeOf(seg_mod.SegHeader);
    const eoff = voff + n_vertices * @sizeOf(seg_mod.VIdx);
    const boff = eoff + n_edges * @sizeOf(types.EdgeRec);
    const foff = b.len - @sizeOf(seg_mod.SegFooter);
    std.mem.writeInt(u32, b[foff..][0..4], Crc.hash(b[voff..eoff]), .little);
    std.mem.writeInt(u32, b[foff + 4 ..][0..4], Crc.hash(b[eoff..boff]), .little);
    std.mem.writeInt(u32, b[foff + 8 ..][0..4], if (has_bloom) Crc.hash(b[boff..foff]) else 0, .little);
}

fn sampleWal(buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice(gpa, wal_mod.header_magic);
    var rb: std.ArrayList(u8) = .empty;
    defer rb.deinit(gpa);
    const ops = [_]batch_mod.Op{
        .{ .kind = .put, .src = 1, .dst = 2, .weight = 1 },
        .{ .kind = .del, .src = 3, .dst = 4, .weight = 0 },
    };
    for ([_]u64{ 1, 3, 5 }) |seq| {
        try wal_mod.encodeRecord(&rb, gpa, seq, &ops);
        try buf.appendSlice(gpa, rb.items);
    }
}

/// Walk the records of a healthy layout and fix each CRC, for bodies of fixed
/// size `rec_len` (crc + len + body) starting at `start`.
fn repairRecords(b: []u8, start: usize, rec_len: usize) void {
    var off = start;
    while (off + rec_len <= b.len) : (off += rec_len) {
        std.mem.writeInt(u32, b[off..][0..4], Crc.hash(b[off + 8 .. off + rec_len]), .little);
    }
}

fn sampleManifest(buf: *std.ArrayList(u8)) !usize {
    try buf.appendSlice(gpa, "SPLMAN01");
    // Two records: add level 1 file 7, then delete it. Tag, u16 level, u64 file.
    const rec_len = 8 + 1 + 2 + 8;
    for ([_]u8{ 4, 5 }) |tag| {
        var r: [rec_len]u8 = undefined;
        std.mem.writeInt(u32, r[4..8], rec_len - 8, .little);
        r[8] = tag;
        std.mem.writeInt(u16, r[9..11], 1, .little);
        std.mem.writeInt(u64, r[11..19], 7, .little);
        std.mem.writeInt(u32, r[0..4], Crc.hash(r[8..]), .little);
        try buf.appendSlice(gpa, &r);
    }
    return rec_len;
}

// ---- mutator ------------------------------------------------------------------

/// A handful of edits that tend to break parsers: flipped bytes, boundary
/// values written over an integer, and truncation.
fn mutate(rnd: std.Random, b: []u8) []u8 {
    const edits = 1 + rnd.uintLessThan(usize, 4);
    for (0..edits) |_| {
        const at = rnd.uintLessThan(usize, b.len);
        switch (rnd.uintLessThan(u8, 4)) {
            0 => b[at] = rnd.int(u8),
            1 => b[at] ^= @as(u8, 1) << rnd.int(u3),
            else => {
                const interesting = [_]u64{ 0, 1, 2, 0x7fffffff, 0xffffffff, std.math.maxInt(u64), std.math.maxInt(u64) - 1, 1 << 63 };
                const v = interesting[rnd.uintLessThan(usize, interesting.len)];
                const w = @min(8, b.len - at);
                var tmp: [8]u8 = undefined;
                std.mem.writeInt(u64, &tmp, v, .little);
                @memcpy(b[at..][0..w], tmp[0..w]);
            },
        }
    }
    if (rnd.uintLessThan(u8, 8) == 0) return b[0..rnd.uintLessThan(usize, b.len + 1)];
    return b;
}

// ---- seeded runs (part of every `zig build test`) -----------------------------

const rounds = 40_000;

test "corrupt segments: random mutations with repaired CRCs never crash the reader" {
    for ([_]u32{ 10, 0 }) |bits| {
        const good = try sampleSegment(bits);
        defer gpa.free(good);
        try targetSegment(good); // the sample itself parses
        _ = try Segment.parse(good);
        const work = try gpa.alignedAlloc(u8, .of(u64), good.len);
        defer gpa.free(work);
        var prng = std.Random.DefaultPrng.init(0xf022 + bits);
        const rnd = prng.random();
        for (0..rounds) |_| {
            @memcpy(work, good);
            const body = mutate(rnd, work);
            if (rnd.boolean() and body.len == work.len) repairSegment(work, 3, 6, bits != 0);
            try targetSegment(@alignCast(body));
        }
    }
}

test "corrupt logs: random mutations with repaired CRCs never crash replay" {
    var good: std.ArrayList(u8) = .empty;
    defer good.deinit(gpa);
    try sampleWal(&good);
    const start = wal_mod.header_magic.len;
    const rec_len = (good.items.len - start) / 3;
    const work = try gpa.alloc(u8, good.items.len);
    defer gpa.free(work);
    var prng = std.Random.DefaultPrng.init(0xf023);
    const rnd = prng.random();
    for (0..rounds) |_| {
        @memcpy(work, good.items);
        const body = mutate(rnd, work);
        if (rnd.boolean()) repairRecords(body, start, rec_len);
        try targetWal(body);
    }
}

test "corrupt manifests: random mutations with repaired CRCs never crash replay" {
    var good: std.ArrayList(u8) = .empty;
    defer good.deinit(gpa);
    const rec_len = try sampleManifest(&good);
    const work = try gpa.alloc(u8, good.items.len);
    defer gpa.free(work);
    var prng = std.Random.DefaultPrng.init(0xf024);
    const rnd = prng.random();
    for (0..rounds) |_| {
        @memcpy(work, good.items);
        const body = mutate(rnd, work);
        if (rnd.boolean()) repairRecords(body, 8, rec_len);
        try targetManifest(body);
    }
}

// ---- coverage-guided runs (`zig build test --fuzz`) ---------------------------

// Random bytes almost never satisfy a CRC, which would leave the fuzzer stuck at
// the checksum compare. These fix the CRCs of whatever layout the input claims,
// so its coverage guidance can reach the checks behind them. The raw
// path without repair stays too: a CRC mismatch has to be survived as well.

fn repairClaimedSegment(b: []u8) void {
    if (b.len < @sizeOf(seg_mod.SegHeader) + @sizeOf(seg_mod.SegFooter)) return;
    const nv = std.mem.readInt(u64, b[16..24], .little);
    const ne = std.mem.readInt(u64, b[24..32], .little);
    const room = b.len - @sizeOf(seg_mod.SegHeader) - @sizeOf(seg_mod.SegFooter);
    if (nv > room / 24 or ne > room / 24 or (nv + ne) * 24 > room) return;
    const has_bloom = std.mem.readInt(u64, b[56..64], .little) != 0;
    repairSegment(b, @intCast(nv), @intCast(ne), has_bloom);
}

fn repairClaimedRecords(b: []u8, start: usize) void {
    var off = start;
    while (off + 8 <= b.len) {
        const len: usize = std.mem.readInt(u32, b[off + 4 ..][0..4], .little);
        if (len > b.len - off - 8) return;
        std.mem.writeInt(u32, b[off..][0..4], Crc.hash(b[off + 8 .. off + 8 + len]), .little);
        off += 8 + len;
    }
}

fn fuzzSegment(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [max_input]u8 align(8) = undefined;
    const n = smith.sliceWithHash(&buf, 0x5e6);
    if (smith.valueWithHash(bool, 0x5e7)) repairClaimedSegment(buf[0..n]);
    try targetSegment(buf[0..n]);
}

fn fuzzWal(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const n = smith.sliceWithHash(&buf, 0xa1);
    if (smith.valueWithHash(bool, 0xa2)) repairClaimedRecords(buf[0..n], wal_mod.header_magic.len);
    try targetWal(buf[0..n]);
}

fn fuzzManifest(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const n = smith.sliceWithHash(&buf, 0x3a);
    if (smith.valueWithHash(bool, 0x3b)) repairClaimedRecords(buf[0..n], 8);
    try targetManifest(buf[0..n]);
}

test "fuzz segment reader" {
    const good = try sampleSegment(10);
    defer gpa.free(good);
    try testing.fuzz({}, fuzzSegment, .{ .corpus = &.{good} });
}

test "fuzz WAL parser" {
    var good: std.ArrayList(u8) = .empty;
    defer good.deinit(gpa);
    try sampleWal(&good);
    try testing.fuzz({}, fuzzWal, .{ .corpus = &.{good.items} });
}

test "fuzz manifest parser" {
    var good: std.ArrayList(u8) = .empty;
    defer good.deinit(gpa);
    _ = try sampleManifest(&good);
    try testing.fuzz({}, fuzzManifest, .{ .corpus = &.{good.items} });
}
