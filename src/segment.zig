//! Immutable CSR segment files (`NNNNNN.seg`).
//!
//!   [SegHeader 64][VIdx * n_vertices][EdgeRec * n_edges][SegFooter 16]
//!
//! `VIdx.edge_off` is the CSR row pointer and the edge array is the column
//! array. A file is written once to `NNNNNN.seg.tmp`, fsynced, renamed, and the
//! directory fsynced, so a `.seg` file is either absent or complete. It is then
//! read through `mmap` and viewed in place as typed slices.
//!
//! The vertex bloom filter in the format is optional; this writer omits it
//! (`bloom_off == 0`) and the reader rejects segments that have one.
const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const types = @import("types.zig");
const EdgeRec = types.EdgeRec;
const Crc = std.hash.crc.@"CRC-32/ISCSI";

pub const seg_magic: u32 = 0x47535250; // "PRSG" as little-endian bytes
pub const footer_magic: u32 = 0x47535046; // "FPSG"

pub const SegHeader = extern struct {
    magic: u32 = seg_magic,
    format_version: u16 = 1,
    level: u16,
    n_vertices: u64,
    n_edges: u64,
    min_vid: u64,
    max_vid: u64,
    min_seq: u64,
    max_seq: u64,
    bloom_off: u64 = 0, // 0 when absent
};

pub const VIdx = extern struct {
    vid: u64,
    edge_off: u64, // index into the edge array
    degree: u32, // records, including history and tombstones
    _pad: u32 = 0,
};

pub const SegFooter = extern struct {
    crc_vidx: u32,
    crc_edges: u32,
    crc_bloom: u32,
    magic: u32,
};

comptime {
    std.debug.assert(@sizeOf(SegHeader) == 64);
    std.debug.assert(@sizeOf(VIdx) == 24);
    std.debug.assert(@sizeOf(SegFooter) == 16);
    // The file format is little-endian; refuse to build anywhere else.
    std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
}

pub fn segPath(gpa: Allocator, dir: []const u8, file_no: u64, tmp: bool) Allocator.Error![:0]u8 {
    return gpa.printSentinel("{s}/{d:0>6}.seg{s}", .{ dir, file_no, if (tmp) ".tmp" else "" }, 0);
}

/// Parse "000123.seg" -> 123. Anything else (including ".seg.tmp") is null.
pub fn parseSegName(name: []const u8) ?u64 {
    const suffix = ".seg";
    if (!std.mem.endsWith(u8, name, suffix)) return null;
    return std.fmt.parseInt(u64, name[0 .. name.len - suffix.len], 10) catch null;
}

/// What the manifest (phase 3) will record about a segment.
pub const Meta = struct {
    level: u16,
    n_vertices: u64,
    n_edges: u64,
    min_vid: u64,
    max_vid: u64,
    min_seq: u64,
    max_seq: u64,
};

// ---- writer -----------------------------------------------------------------

/// Collects vertices in ascending vid order, then writes the file in one go.
/// The whole segment is held in memory until `finish`; a flush of an N-byte
/// MemGraph therefore needs about N more bytes transiently.
pub const SegWriter = struct {
    gpa: Allocator,
    level: u16,
    vidx: std.ArrayList(VIdx) = .empty,
    edges: std.ArrayList(EdgeRec) = .empty,
    min_seq: u64 = std.math.maxInt(u64),
    max_seq: u64 = 0,

    pub fn init(gpa: Allocator, level: u16) SegWriter {
        return .{ .gpa = gpa, .level = level };
    }

    pub fn deinit(w: *SegWriter) void {
        w.vidx.deinit(w.gpa);
        w.edges.deinit(w.gpa);
    }

    /// `recs` must already be sorted by (dst asc, seq desc) and non-empty;
    /// `vid` must exceed every vid added before.
    pub fn addVertex(w: *SegWriter, vid: u64, recs: []const EdgeRec) Allocator.Error!void {
        std.debug.assert(recs.len > 0 and recs.len <= std.math.maxInt(u32));
        std.debug.assert(w.vidx.items.len == 0 or w.vidx.items[w.vidx.items.len - 1].vid < vid);
        try w.vidx.append(w.gpa, .{ .vid = vid, .edge_off = w.edges.items.len, .degree = @intCast(recs.len) });
        errdefer _ = w.vidx.pop();
        try w.edges.appendSlice(w.gpa, recs);
        for (recs) |r| {
            w.min_seq = @min(w.min_seq, r.seq);
            w.max_seq = @max(w.max_seq, r.seq);
        }
    }

    /// Write `dir/NNNNNN.seg` durably. On error nothing is left behind.
    pub fn finish(w: *SegWriter, dir: [:0]const u8, file_no: u64) types.Error!Meta {
        const nv = w.vidx.items.len;
        if (nv == 0) return error.InvalidArgument; // an empty segment is a bug upstream
        const meta: Meta = .{
            .level = w.level,
            .n_vertices = nv,
            .n_edges = w.edges.items.len,
            .min_vid = w.vidx.items[0].vid,
            .max_vid = w.vidx.items[nv - 1].vid,
            .min_seq = w.min_seq,
            .max_seq = w.max_seq,
        };
        const hdr: SegHeader = .{
            .level = meta.level,
            .n_vertices = meta.n_vertices,
            .n_edges = meta.n_edges,
            .min_vid = meta.min_vid,
            .max_vid = meta.max_vid,
            .min_seq = meta.min_seq,
            .max_seq = meta.max_seq,
        };
        const vbytes = std.mem.sliceAsBytes(w.vidx.items);
        const ebytes = std.mem.sliceAsBytes(w.edges.items);
        const footer: SegFooter = .{
            .crc_vidx = Crc.hash(vbytes),
            .crc_edges = Crc.hash(ebytes),
            .crc_bloom = 0,
            .magic = footer_magic,
        };

        const tmp_path = try segPath(w.gpa, dir, file_no, true);
        defer w.gpa.free(tmp_path);
        const final_path = try segPath(w.gpa, dir, file_no, false);
        defer w.gpa.free(final_path);

        const f = try sys.File.open(tmp_path, .read_write_create);
        var closed = false;
        errdefer {
            if (!closed) f.close();
            sys.unlink(tmp_path);
        }
        try f.truncate(0);
        try f.writeAll(std.mem.asBytes(&hdr));
        try f.writeAll(vbytes);
        try f.writeAll(ebytes);
        try f.writeAll(std.mem.asBytes(&footer));
        try f.sync();
        f.close();
        closed = true;
        try sys.rename(tmp_path, final_path);
        errdefer sys.unlink(final_path);
        try sys.syncDir(dir); // otherwise a crash can lose the directory entry
        return meta;
    }
};

// ---- reader -----------------------------------------------------------------

pub const Segment = struct {
    gpa: Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    file_no: u64,
    level: u16,
    min_vid: u64,
    max_vid: u64,
    min_seq: u64,
    max_seq: u64,
    map: sys.Mapping,
    vidx: []const VIdx,
    edges: []const EdgeRec,

    /// Map and fully validate `path`: lengths, magics, CRCs, then the
    /// structural invariants of the index. Corrupt input yields
    /// `error.Corrupt` and never an out-of-bounds read.
    pub fn open(gpa: Allocator, path: [*:0]const u8, file_no: u64) types.Error!*Segment {
        const f = try sys.File.open(path, .read);
        defer f.close();
        const len: usize = @intCast(try f.size());
        if (len < @sizeOf(SegHeader) + @sizeOf(SegFooter)) return error.Corrupt;
        const map = try sys.mapFile(f, len);
        errdefer sys.unmap(map);

        const hdr = try parseHeader(map);
        // Overflow-safe: expected = 64 + 24*nv + 24*ne + 16 must equal the file length.
        const vbytes_n = std.math.mul(u64, hdr.n_vertices, @sizeOf(VIdx)) catch return error.Corrupt;
        const ebytes_n = std.math.mul(u64, hdr.n_edges, @sizeOf(EdgeRec)) catch return error.Corrupt;
        var expect: u64 = @sizeOf(SegHeader);
        expect = std.math.add(u64, expect, vbytes_n) catch return error.Corrupt;
        expect = std.math.add(u64, expect, ebytes_n) catch return error.Corrupt;
        expect = std.math.add(u64, expect, @sizeOf(SegFooter)) catch return error.Corrupt;
        if (expect != len) return error.Corrupt;
        if (hdr.n_vertices == 0 or hdr.n_edges < hdr.n_vertices) return error.Corrupt;

        const voff = @sizeOf(SegHeader);
        const eoff = voff + @as(usize, @intCast(vbytes_n));
        const foff = eoff + @as(usize, @intCast(ebytes_n));
        const vb = map[voff..eoff];
        const eb = map[eoff..foff];
        var footer: SegFooter = undefined;
        @memcpy(std.mem.asBytes(&footer), map[foff..][0..@sizeOf(SegFooter)]);
        if (footer.magic != footer_magic) return error.Corrupt;
        if (footer.crc_bloom != 0) return error.Corrupt; // no bloom region exists
        if (Crc.hash(vb) != footer.crc_vidx) return error.Corrupt;
        if (Crc.hash(eb) != footer.crc_edges) return error.Corrupt;

        // 64 and 24 are multiples of 8, so both regions are 8-aligned.
        const vidx: []const VIdx = @alignCast(std.mem.bytesAsSlice(VIdx, vb));
        const edges: []const EdgeRec = @alignCast(std.mem.bytesAsSlice(EdgeRec, eb));
        try validateIndex(hdr, vidx, edges);

        const s = try gpa.create(Segment);
        s.* = .{
            .gpa = gpa,
            .file_no = file_no,
            .level = hdr.level,
            .min_vid = hdr.min_vid,
            .max_vid = hdr.max_vid,
            .min_seq = hdr.min_seq,
            .max_seq = hdr.max_seq,
            .map = map,
            .vidx = vidx,
            .edges = edges,
        };
        return s;
    }

    fn parseHeader(map: sys.Mapping) types.Error!SegHeader {
        var hdr: SegHeader = undefined;
        @memcpy(std.mem.asBytes(&hdr), map[0..@sizeOf(SegHeader)]);
        if (hdr.magic != seg_magic) return error.Corrupt;
        if (hdr.format_version != 1) return error.Corrupt;
        if (hdr.bloom_off != 0) return error.Corrupt; // not supported yet
        return hdr;
    }

    fn validateIndex(hdr: SegHeader, vidx: []const VIdx, edges: []const EdgeRec) types.Error!void {
        var next_off: u64 = 0;
        var min_seq: u64 = std.math.maxInt(u64);
        var max_seq: u64 = 0;
        for (vidx, 0..) |v, i| {
            if (i > 0 and vidx[i - 1].vid >= v.vid) return error.Corrupt;
            if (v.degree == 0 or v.edge_off != next_off) return error.Corrupt;
            const end = std.math.add(u64, v.edge_off, v.degree) catch return error.Corrupt;
            if (end > edges.len) return error.Corrupt;
            const recs = edges[@intCast(v.edge_off)..@intCast(end)];
            for (recs, 0..) |r, k| {
                if (k > 0 and !types.edgeLess({}, recs[k - 1], r)) return error.Corrupt;
                min_seq = @min(min_seq, r.seq);
                max_seq = @max(max_seq, r.seq);
            }
            next_off = end;
        }
        if (next_off != edges.len) return error.Corrupt;
        if (vidx[0].vid != hdr.min_vid or vidx[vidx.len - 1].vid != hdr.max_vid) return error.Corrupt;
        if (min_seq != hdr.min_seq or max_seq != hdr.max_seq) return error.Corrupt;
    }

    pub fn ref(s: *Segment) *Segment {
        _ = s.refs.fetchAdd(1, .monotonic);
        return s;
    }

    pub fn unref(s: *Segment) void {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        sys.unmap(s.map);
        s.gpa.destroy(s);
    }

    /// The records of `vid` in (dst asc, seq desc) order, or empty.
    pub fn lookup(s: *const Segment, vid: u64) []const EdgeRec {
        if (vid < s.min_vid or vid > s.max_vid) return &.{};
        const Ctx = struct {
            vid: u64,
            fn cmp(c: @This(), v: VIdx) std.math.Order {
                return std.math.order(c.vid, v.vid);
            }
        };
        const i = std.sort.binarySearch(VIdx, s.vidx, Ctx{ .vid = vid }, Ctx.cmp) orelse return &.{};
        const v = s.vidx[i];
        return s.edges[@intCast(v.edge_off)..][0..v.degree];
    }
};

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

fn rec(dst: u64, seq: u64, w: f32, flags: u32) EdgeRec {
    return .{ .dst = dst, .seq = seq, .weight = w, .flags = flags };
}

var test_counter: std.atomic.Value(u32) = .init(0);

fn tmpDir() ![:0]u8 {
    try sys.makeDir(".zig-cache");
    const n = test_counter.fetchAdd(1, .monotonic);
    const p = try testing.allocator.printSentinel(".zig-cache/seg-test-{d}-{d}", .{ std.c.getpid(), n }, 0);
    try sys.makeDir(p);
    return p;
}

fn cleanup(dir: [:0]u8) void {
    const names = sys.listDir(testing.allocator, dir) catch &[_][]u8{};
    for (names) |n| {
        if (std.fmt.allocPrintSentinel(testing.allocator, "{s}/{s}", .{ dir, n }, 0)) |p| {
            sys.unlink(p);
            testing.allocator.free(p);
        } else |_| {}
        testing.allocator.free(n);
    }
    if (names.len > 0) testing.allocator.free(names);
    sys.rmdir(dir);
    testing.allocator.free(dir);
}

fn writeSample(dir: [:0]const u8, file_no: u64) !Meta {
    var w = SegWriter.init(testing.allocator, 0);
    defer w.deinit();
    try w.addVertex(5, &.{ rec(1, 9, 1.5, 0), rec(1, 3, 1.0, 0), rec(7, 4, 2.0, types.tombstone) });
    try w.addVertex(9, &.{rec(2, 6, 0.5, 0)});
    try w.addVertex(100, &.{ rec(3, 8, 3.0, 0), rec(4, 2, 4.0, 0) });
    return w.finish(dir, file_no);
}

test "write, reopen and look up" {
    const dir = try tmpDir();
    defer cleanup(dir);
    const meta = try writeSample(dir, 7);
    try testing.expectEqual(@as(u64, 3), meta.n_vertices);
    try testing.expectEqual(@as(u64, 6), meta.n_edges);
    try testing.expectEqual(@as(u64, 2), meta.min_seq);
    try testing.expectEqual(@as(u64, 9), meta.max_seq);

    const path = try segPath(testing.allocator, dir, 7, false);
    defer testing.allocator.free(path);
    const seg = try Segment.open(testing.allocator, path, 7);
    defer seg.unref();

    const r5 = seg.lookup(5);
    try testing.expectEqual(@as(usize, 3), r5.len);
    try testing.expectEqual(@as(u64, 9), r5[0].seq); // newest first within a dst
    try testing.expect(r5[2].flags & types.tombstone != 0);
    try testing.expectEqual(@as(usize, 1), seg.lookup(9).len);
    try testing.expectEqual(@as(usize, 2), seg.lookup(100).len);
    try testing.expectEqual(@as(usize, 0), seg.lookup(6).len); // gap
    try testing.expectEqual(@as(usize, 0), seg.lookup(0).len); // below range
    try testing.expectEqual(@as(usize, 0), seg.lookup(101).len); // above range
}

test "no .tmp file is left after finish" {
    const dir = try tmpDir();
    defer cleanup(dir);
    _ = try writeSample(dir, 1);
    const names = try sys.listDir(testing.allocator, dir);
    defer {
        for (names) |n| testing.allocator.free(n);
        testing.allocator.free(names);
    }
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqual(@as(?u64, 1), parseSegName(names[0]));
    try testing.expectEqual(@as(?u64, null), parseSegName("000001.seg.tmp"));
}

fn patchByte(path: [*:0]const u8, off: usize, xor: u8) !void {
    const f = try sys.File.open(path, .read);
    const bytes = try f.readAll(testing.allocator);
    f.close();
    defer testing.allocator.free(bytes);
    bytes[off] ^= xor;
    const w = try sys.File.open(path, .read_write_create);
    defer w.close();
    try w.truncate(0);
    try w.writeAll(bytes);
}

test "corrupt segments are rejected, never read out of bounds" {
    const dir = try tmpDir();
    defer cleanup(dir);
    _ = try writeSample(dir, 1);
    const path = try segPath(testing.allocator, dir, 1, false);
    defer testing.allocator.free(path);

    const f = try sys.File.open(path, .read);
    const total: usize = @intCast(try f.size());
    f.close();

    // Flip every byte in turn: each must be caught (CRC, magic, or structure).
    // Exception: the header's `level` (bytes 6..8) is advisory, covered by no
    // CRC; the manifest in phase 3 is the source of truth for levels.
    for (0..total) |i| {
        if (i == 6 or i == 7) continue;
        try patchByte(path, i, 0x5a);
        try testing.expectError(error.Corrupt, Segment.open(testing.allocator, path, 1));
        try patchByte(path, i, 0x5a); // restore
    }
    const ok = try Segment.open(testing.allocator, path, 1);
    ok.unref();
}

test "truncated and garbage files are rejected" {
    const dir = try tmpDir();
    defer cleanup(dir);
    _ = try writeSample(dir, 1);
    const path = try segPath(testing.allocator, dir, 1, false);
    defer testing.allocator.free(path);

    const f = try sys.File.open(path, .read_write_create);
    defer f.close();
    const total = try f.size();
    var cut: u64 = 0;
    while (cut < total) : (cut += 13) {
        try f.truncate(cut);
        // Reopen each time: the file is shorter than the mapping logic expects.
        try testing.expectError(error.Corrupt, Segment.open(testing.allocator, path, 1));
    }
}
