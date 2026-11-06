//! Versions, version edits and the manifest.
//!
//! A `Version` is an immutable list of segments per level. Flush and
//! compaction never edit one: they build a new Version from the current one
//! plus a `VersionEdit`, make the edit durable in the manifest, and swap
//! `current`. A reader that holds a Version (through a Snapshot) therefore
//! needs no lock, and the segment files it lists stay on disk until it lets go.
//!
//! Manifest (`MANIFEST-NNNNNN`):
//!
//!   file   = "SPLMAN01" record*
//!   record = crc32c u32 | len u32 | payload[len]
//!   payload = (tag u8, value)*
//!     1 log_number u64      WALs numbered below this are obsolete
//!     2 next_file_no u64    lower bound for the next file number
//!     3 last_seq u64        highest sequence number flushed so far
//!     4 add    level u16, file_no u64
//!     5 delete level u16, file_no u64
//!
//! `CURRENT` holds the live manifest's name and is replaced with rename(2).
//! Every open writes a fresh manifest holding one record that describes the
//! whole layout, so the log does not grow across restarts.
const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const types = @import("types.zig");
const seg_mod = @import("segment.zig");
const Segment = seg_mod.Segment;
const CsrView = @import("spectral.zig").CsrView;
const Error = types.Error;
const Crc = std.hash.crc.@"CRC-32/ISCSI";

pub const max_levels = 7;

const manifest_magic = "SPLMAN01";
const tag_log_number: u8 = 1;
const tag_next_file: u8 = 2;
const tag_last_seq: u8 = 3;
const tag_add: u8 = 4;
const tag_delete: u8 = 5;

// ---- Version ----------------------------------------------------------------

pub const Version = struct {
    gpa: Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    /// L0: newest first, ranges may overlap. L1 and deeper: sorted by vertex
    /// range, pairwise disjoint; under the tiered policy they are like L0.
    levels: [max_levels][]const *Segment = @splat(&.{}),
    /// Merged CSR of this layout, built on first use and freed with it.
    view: ?*CsrView = null,
    view_mu: sys.Mutex = .{},

    /// The CSR view of this Version. The result lives as long as the Version.
    pub fn csrView(v: *Version) Error!*const CsrView {
        v.view_mu.lock();
        defer v.view_mu.unlock();
        if (v.view == null) v.view = try CsrView.build(v.gpa, v);
        return v.view.?;
    }

    pub fn ref(v: *Version) *Version {
        _ = v.refs.fetchAdd(1, .monotonic);
        return v;
    }

    /// The last reference drops the Version's reference on every segment; a
    /// segment that is obsolete and has no other holder is unlinked then.
    pub fn unref(v: *Version) void {
        if (v.refs.fetchSub(1, .acq_rel) != 1) return;
        if (v.view) |g| g.destroy();
        for (v.levels) |segs| {
            for (segs) |s| s.unref();
            v.gpa.free(segs);
        }
        v.gpa.destroy(v);
    }

    pub fn numFiles(v: *const Version, level: usize) usize {
        return v.levels[level].len;
    }

    pub fn totalFiles(v: *const Version) usize {
        var n: usize = 0;
        for (v.levels) |segs| n += segs.len;
        return n;
    }

    pub fn levelBytes(v: *const Version, level: usize) u64 {
        var n: u64 = 0;
        for (v.levels[level]) |s| n += s.bytes();
        return n;
    }

    /// Segments of `level` whose vertex range intersects [lo, hi]. The caller
    /// frees the slice; the pointers are borrowed from this Version.
    pub fn overlapping(v: *const Version, gpa: Allocator, level: usize, lo: u64, hi: u64) Allocator.Error![]*Segment {
        var out: std.ArrayList(*Segment) = .empty;
        errdefer out.deinit(gpa);
        for (v.levels[level]) |s| {
            if (s.max_vid >= lo and s.min_vid <= hi) try out.append(gpa, s);
        }
        return out.toOwnedSlice(gpa);
    }

    /// The segment of `level` (>= 1) whose range covers `vid`, if any. Ranges
    /// are disjoint, so this is one binary search.
    pub fn findCovering(v: *const Version, level: usize, vid: u64) ?*Segment {
        std.debug.assert(level >= 1);
        const Ctx = struct {
            vid: u64,
            fn cmp(c: @This(), s: *Segment) std.math.Order {
                if (c.vid < s.min_vid) return .lt;
                if (c.vid > s.max_vid) return .gt;
                return .eq;
            }
        };
        const segs = v.levels[level];
        const i = std.sort.binarySearch(*Segment, segs, Ctx{ .vid = vid }, Ctx.cmp) orelse return null;
        return segs[i];
    }
};

// ---- VersionEdit ------------------------------------------------------------

pub const FileRef = struct { level: u16, file_no: u64 };
pub const Added = struct { level: u16, file_no: u64, seg: ?*Segment = null };

/// The difference between two Versions, plus the bookkeeping numbers the
/// manifest carries. `added[i].seg` is set on edits built at run time and null
/// on edits decoded from the manifest.
pub const VersionEdit = struct {
    log_number: ?u64 = null,
    next_file_no: ?u64 = null,
    last_seq: ?u64 = null,
    added: std.ArrayList(Added) = .empty,
    deleted: std.ArrayList(FileRef) = .empty,

    /// The edit takes its own reference on `seg`; the caller keeps theirs.
    pub fn addSegment(e: *VersionEdit, gpa: Allocator, level: u16, seg: *Segment) Allocator.Error!void {
        try e.added.ensureUnusedCapacity(gpa, 1); // so the ref below cannot leak
        e.added.appendAssumeCapacity(.{ .level = level, .file_no = seg.file_no, .seg = seg.ref() });
    }

    pub fn deleteFile(e: *VersionEdit, gpa: Allocator, level: u16, file_no: u64) Allocator.Error!void {
        try e.deleted.append(gpa, .{ .level = level, .file_no = file_no });
    }

    pub fn deinit(e: *VersionEdit, gpa: Allocator) void {
        for (e.added.items) |a| if (a.seg) |s| s.unref();
        e.added.deinit(gpa);
        e.deleted.deinit(gpa);
    }

    fn encode(e: *const VersionEdit, buf: *std.ArrayList(u8), gpa: Allocator) Allocator.Error!void {
        buf.clearRetainingCapacity();
        // Header placeholder, patched once the payload length and CRC are known.
        try buf.appendNTimes(gpa, 0, 8);
        if (e.log_number) |n| try putU64Tag(buf, gpa, tag_log_number, n);
        if (e.next_file_no) |n| try putU64Tag(buf, gpa, tag_next_file, n);
        if (e.last_seq) |n| try putU64Tag(buf, gpa, tag_last_seq, n);
        for (e.added.items) |a| try putFileTag(buf, gpa, tag_add, a.level, a.file_no);
        for (e.deleted.items) |d| try putFileTag(buf, gpa, tag_delete, d.level, d.file_no);
        const payload = buf.items[8..];
        std.mem.writeInt(u32, buf.items[0..4], Crc.hash(payload), .little);
        std.mem.writeInt(u32, buf.items[4..8], @intCast(payload.len), .little);
    }
};

fn putU64Tag(buf: *std.ArrayList(u8), gpa: Allocator, tag: u8, v: u64) Allocator.Error!void {
    try buf.append(gpa, tag);
    try buf.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u64, v)));
}

fn putFileTag(buf: *std.ArrayList(u8), gpa: Allocator, tag: u8, level: u16, file_no: u64) Allocator.Error!void {
    try buf.append(gpa, tag);
    try buf.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, level)));
    try buf.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u64, file_no)));
}

/// Bounds-checked reader over one record's payload.
const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(c: *Cursor, n: usize) Error![]const u8 {
        if (c.bytes.len - c.pos < n) return error.Corrupt;
        defer c.pos += n;
        return c.bytes[c.pos..][0..n];
    }
    fn u8_(c: *Cursor) Error!u8 {
        return (try c.take(1))[0];
    }
    fn u16_(c: *Cursor) Error!u16 {
        return std.mem.readInt(u16, (try c.take(2))[0..2], .little);
    }
    fn u64_(c: *Cursor) Error!u64 {
        return std.mem.readInt(u64, (try c.take(8))[0..8], .little);
    }
    fn done(c: *const Cursor) bool {
        return c.pos == c.bytes.len;
    }
};

fn decodeEdit(gpa: Allocator, payload: []const u8) Error!VersionEdit {
    var e: VersionEdit = .{};
    errdefer e.deinit(gpa);
    var c: Cursor = .{ .bytes = payload };
    while (!c.done()) {
        switch (try c.u8_()) {
            tag_log_number => e.log_number = try c.u64_(),
            tag_next_file => e.next_file_no = try c.u64_(),
            tag_last_seq => e.last_seq = try c.u64_(),
            tag_add, tag_delete => |tag| {
                const level = try c.u16_();
                const file_no = try c.u64_();
                if (level >= max_levels) return error.Corrupt;
                if (tag == tag_add) {
                    try e.added.append(gpa, .{ .level = level, .file_no = file_no });
                } else {
                    try e.deleted.append(gpa, .{ .level = level, .file_no = file_no });
                }
            },
            else => return error.Corrupt,
        }
    }
    return e;
}

fn segLessL0(_: void, a: *Segment, b: *Segment) bool {
    return a.file_no > b.file_no; // newest flush first
}

fn segLessRange(_: void, a: *Segment, b: *Segment) bool {
    return a.min_vid < b.min_vid;
}

/// Build the Version that results from applying `edit` to `base` (null: an
/// empty database). Every added entry must carry its segment. The result holds
/// its own reference on each segment it lists. Nothing here touches the disk.
fn applyEdit(gpa: Allocator, base: ?*const Version, edit: *const VersionEdit, overlapping_levels: bool) Error!*Version {
    const v = try gpa.create(Version);
    v.* = .{ .gpa = gpa };
    errdefer v.unref();

    for (0..max_levels) |lvl| {
        var list: std.ArrayList(*Segment) = .empty;
        errdefer {
            for (list.items) |s| s.unref();
            list.deinit(gpa);
        }
        if (base) |b| {
            for (b.levels[lvl]) |s| {
                if (isDeleted(edit, lvl, s.file_no)) continue;
                try list.append(gpa, s.ref());
            }
        }
        for (edit.added.items) |a| {
            if (a.level != lvl) continue;
            try list.append(gpa, a.seg.?.ref());
        }
        if (lvl == 0 or overlapping_levels) {
            std.mem.sort(*Segment, list.items, {}, segLessL0);
        } else {
            std.mem.sort(*Segment, list.items, {}, segLessRange);
            var i: usize = 1;
            while (i < list.items.len) : (i += 1) {
                if (list.items[i - 1].max_vid >= list.items[i].min_vid) return error.Corrupt; // overlap below L0
            }
        }
        v.levels[lvl] = try list.toOwnedSlice(gpa);
    }

    // Every deletion must name a file the base really had at that level.
    for (edit.deleted.items) |d| {
        const b = base orelse return error.Corrupt;
        var found = false;
        for (b.levels[d.level]) |s| found = found or s.file_no == d.file_no;
        if (!found) return error.Corrupt;
    }
    return v;
}

fn isDeleted(edit: *const VersionEdit, level: usize, file_no: u64) bool {
    for (edit.deleted.items) |d| {
        if (d.level == level and d.file_no == file_no) return true;
    }
    return false;
}

// ---- VersionSet -------------------------------------------------------------

pub fn manifestPath(gpa: Allocator, dir: []const u8, no: u64) Allocator.Error![:0]u8 {
    return gpa.printSentinel("{s}/MANIFEST-{d:0>6}", .{ dir, no }, 0);
}

fn parseManifestName(name: []const u8) ?u64 {
    const prefix = "MANIFEST-";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    return std.fmt.parseInt(u64, name[prefix.len..], 10) catch null;
}

/// What `VersionSet.recover` found besides the layout.
pub const Recovered = struct {
    vs: VersionSet,
    /// Highest sequence number any flush recorded.
    last_seq: u64,
    /// WAL numbers still on disk, ascending. Those below `vs.log_number` are
    /// obsolete; the caller deletes them.
    wal_nos: []u64,

    pub fn deinit(r: *Recovered, gpa: Allocator) void {
        gpa.free(r.wal_nos);
        r.vs.deinit();
    }
};

pub const VersionSet = struct {
    gpa: Allocator,
    dir: [:0]const u8, // borrowed
    /// The live Version. Replaced only inside `logAndApply`, under both
    /// `apply_mu` and the caller's `mu`; read under either.
    current: *Version,
    /// Serializes `logAndApply`, so flush and compaction install one at a time.
    apply_mu: sys.Mutex = .{},
    next_file_no: std.atomic.Value(u64),
    /// WALs numbered below this are obsolete. Guarded by `apply_mu`.
    log_number: u64,
    /// Levels below L0 may overlap (the tiered policy).
    overlapping_levels: bool,
    manifest: ?sys.File = null,
    manifest_no: u64 = 0,
    manifest_size: u64 = 0,
    buf: std.ArrayList(u8) = .empty,
    /// Set when the manifest may hold a record that memory does not (a failed
    /// fsync cannot be retried safely). Nothing more is installed; reopening
    /// recovers from whatever reached disk.
    broken: std.atomic.Value(bool) = .init(false),

    pub fn newFileNumber(vs: *VersionSet) u64 {
        return vs.next_file_no.fetchAdd(1, .monotonic);
    }

    pub fn isBroken(vs: *const VersionSet) bool {
        return vs.broken.load(.acquire);
    }

    pub fn deinit(vs: *VersionSet) void {
        if (vs.manifest) |f| f.close();
        vs.buf.deinit(vs.gpa);
        vs.current.unref();
    }

    /// Rebuild the level layout from `CURRENT` and the manifest it names, open
    /// and validate every segment it lists, and delete files nothing refers to
    /// (unfinished `.seg.tmp`, segments from a flush or compaction that never
    /// reached the manifest). Does not write a manifest: call `startManifest`
    /// once the WALs are replayed.
    ///
    /// A directory with segments but no `CURRENT` (written before manifests
    /// existed) is adopted as an all-L0 layout.
    ///
    /// The policy is not recorded: a store with overlapping deep levels opened
    /// as leveled is refused with `error.InvalidArgument`. The other way round
    /// is fine, since disjoint levels are a special case of overlapping ones.
    pub fn recover(gpa: Allocator, dir: [:0]const u8, overlapping_levels: bool) Error!Recovered {
        var seg_nos: std.ArrayList(u64) = .empty;
        defer seg_nos.deinit(gpa);
        var wal_nos: std.ArrayList(u64) = .empty;
        errdefer wal_nos.deinit(gpa);
        var max_no: u64 = 0;
        {
            const names = try sys.listDir(gpa, dir);
            defer {
                for (names) |n| gpa.free(n);
                gpa.free(names);
            }
            for (names) |name| {
                if (seg_mod.parseSegName(name)) |n| {
                    try seg_nos.append(gpa, n);
                    max_no = @max(max_no, n);
                } else if (parseWalName(name)) |n| {
                    try wal_nos.append(gpa, n);
                    max_no = @max(max_no, n);
                } else if (parseManifestName(name)) |n| {
                    max_no = @max(max_no, n);
                } else if (std.mem.endsWith(u8, name, ".seg.tmp") or std.mem.eql(u8, name, "CURRENT.tmp")) {
                    const p = try gpa.printSentinel("{s}/{s}", .{ dir, name }, 0);
                    defer gpa.free(p);
                    sys.unlink(p);
                }
            }
        }
        std.mem.sort(u64, wal_nos.items, {}, std.sort.asc(u64));

        // file_no -> level of every live segment.
        var live: std.AutoHashMapUnmanaged(u64, u16) = .empty;
        defer live.deinit(gpa);
        var log_number: u64 = 0;
        var next_file_no: u64 = 0;
        var last_seq: u64 = 0;
        var adopted = false;

        const cur_path = try gpa.printSentinel("{s}/CURRENT", .{dir}, 0);
        defer gpa.free(cur_path);
        if (try sys.File.openOptional(cur_path, .read)) |cf| {
            const name_bytes = blk: {
                defer cf.close();
                break :blk try cf.readAll(gpa);
            };
            defer gpa.free(name_bytes);
            const name = std.mem.trimEnd(u8, name_bytes, "\n");
            const mno = parseManifestName(name) orelse return error.Corrupt;
            const mpath = try manifestPath(gpa, dir, mno);
            defer gpa.free(mpath);
            const mf = (try sys.File.openOptional(mpath, .read)) orelse return error.Corrupt;
            const bytes = blk: {
                defer mf.close();
                break :blk try mf.readAll(gpa);
            };
            defer gpa.free(bytes);
            try replayManifest(gpa, bytes, &live, &log_number, &next_file_no, &last_seq);
        } else {
            adopted = true;
            for (seg_nos.items) |n| try live.put(gpa, n, 0);
        }

        // Open what the manifest lists.
        var edit: VersionEdit = .{};
        defer edit.deinit(gpa);
        var it = live.iterator();
        while (it.next()) |kv| {
            const file_no = kv.key_ptr.*;
            const level = kv.value_ptr.*;
            const p = try seg_mod.segPath(gpa, dir, file_no, false);
            defer gpa.free(p);
            // A listed segment that is gone is lost data, not garbage.
            if (try sys.File.openOptional(p, .read)) |probe| probe.close() else return error.Corrupt;
            const seg = try Segment.open(gpa, p, file_no);
            defer seg.unref(); // the edit holds its own reference
            if (seg.level != level) return error.Corrupt; // header and manifest disagree
            try edit.addSegment(gpa, level, seg);
            if (adopted) last_seq = @max(last_seq, seg.max_seq);
        }
        if (!overlapping_levels) {
            for (edit.added.items, 0..) |a, i| {
                if (a.level == 0) continue;
                for (edit.added.items[i + 1..]) |b| {
                    if (b.level == a.level and a.seg.?.max_vid >= b.seg.?.min_vid and
                        b.seg.?.max_vid >= a.seg.?.min_vid) return error.InvalidArgument;
                }
            }
        }
        const version = try applyEdit(gpa, null, &edit, overlapping_levels);
        errdefer version.unref();

        // Garbage: segment files the manifest does not list.
        for (seg_nos.items) |n| {
            if (live.contains(n)) continue;
            const p = try seg_mod.segPath(gpa, dir, n, false);
            defer gpa.free(p);
            sys.unlink(p);
        }

        return .{
            .vs = .{
                .gpa = gpa,
                .dir = dir,
                .current = version,
                .next_file_no = .init(@max(next_file_no, max_no + 1)),
                .log_number = log_number,
                .overlapping_levels = overlapping_levels,
            },
            .last_seq = last_seq,
            .wal_nos = try wal_nos.toOwnedSlice(gpa),
        };
    }

    /// Write a fresh manifest that describes the current layout in one record,
    /// make it the live one, and delete the older manifests.
    pub fn startManifest(vs: *VersionSet, last_seq: u64) Error!void {
        const gpa = vs.gpa;
        const no = vs.newFileNumber();
        const path = try manifestPath(gpa, vs.dir, no);
        defer gpa.free(path);

        var snap: VersionEdit = .{};
        defer snap.deinit(gpa);
        snap.log_number = vs.log_number;
        snap.next_file_no = vs.next_file_no.load(.monotonic);
        snap.last_seq = last_seq;
        for (vs.current.levels, 0..) |segs, lvl| {
            for (segs) |s| try snap.addSegment(gpa, @intCast(lvl), s);
        }
        var rec: std.ArrayList(u8) = .empty;
        defer rec.deinit(gpa);
        try snap.encode(&rec, gpa);

        {
            const f = try sys.File.open(path, .read_write_create);
            defer f.close();
            errdefer sys.unlink(path);
            try f.truncate(0);
            try f.writeAll(manifest_magic);
            try f.writeAll(rec.items);
            try f.sync();
        }
        // Switch CURRENT only after the manifest is complete on disk.
        const cur_tmp = try gpa.printSentinel("{s}/CURRENT.tmp", .{vs.dir}, 0);
        defer gpa.free(cur_tmp);
        const cur = try gpa.printSentinel("{s}/CURRENT", .{vs.dir}, 0);
        defer gpa.free(cur);
        const content = try std.fmt.allocPrint(gpa, "MANIFEST-{d:0>6}\n", .{no});
        defer gpa.free(content);
        try sys.replaceFileDurably(cur_tmp, cur, vs.dir, content);

        const af = try sys.File.open(path, .append);
        if (vs.manifest) |old| old.close();
        vs.manifest = af;
        vs.manifest_no = no;
        vs.manifest_size = manifest_magic.len + rec.items.len;

        // Older manifests are garbage now.
        const names = sys.listDir(gpa, vs.dir) catch return;
        defer {
            for (names) |n| gpa.free(n);
            gpa.free(names);
        }
        for (names) |name| {
            const n = parseManifestName(name) orelse continue;
            if (n == no) continue;
            const p = manifestPath(gpa, vs.dir, n) catch continue;
            defer gpa.free(p);
            sys.unlink(p);
        }
    }

    /// Make `edit` durable in the manifest, then install the Version it
    /// produces as `current`. Segments the edit deletes become obsolete: their
    /// files go away when the last older Version or snapshot lets go.
    ///
    /// Errors before the manifest is touched leave everything unchanged. If the
    /// manifest write itself fails the set is `broken` (see `isBroken`) and the
    /// caller must not delete files the edit mentions.
    pub fn logAndApply(vs: *VersionSet, edit: *VersionEdit, mu: *sys.Mutex) Error!void {
        vs.apply_mu.lock();
        defer vs.apply_mu.unlock();
        if (vs.isBroken()) return error.Io;

        edit.next_file_no = vs.next_file_no.load(.monotonic);
        const base = vs.current;
        const next = try applyEdit(vs.gpa, base, edit, vs.overlapping_levels);
        errdefer next.unref();

        try vs.appendRecord(edit);

        mu.lock();
        vs.current = next;
        mu.unlock();

        for (edit.deleted.items) |d| {
            for (base.levels[d.level]) |s| {
                if (s.file_no == d.file_no) s.markObsolete();
            }
        }
        if (edit.log_number) |n| vs.log_number = n;
        base.unref();
    }

    fn appendRecord(vs: *VersionSet, edit: *const VersionEdit) Error!void {
        const f = vs.manifest orelse return error.Io;
        try edit.encode(&vs.buf, vs.gpa);
        f.writeAll(vs.buf.items) catch {
            // A short write leaves half a record; cut it off so the next
            // record does not land behind garbage in the middle of the file.
            f.truncate(vs.manifest_size) catch vs.broken.store(true, .release);
            vs.broken.store(true, .release);
            return error.Io;
        };
        f.sync() catch {
            vs.broken.store(true, .release);
            return error.Io;
        };
        vs.manifest_size += vs.buf.items.len;
    }
};

/// Replay every record of a manifest into the live set. A torn final record
/// (the crash interrupted its append) is dropped: it was never acknowledged.
/// Damage anywhere else is `Corrupt`.
pub fn replayManifest(
    gpa: Allocator,
    bytes: []const u8,
    live: *std.AutoHashMapUnmanaged(u64, u16),
    log_number: *u64,
    next_file_no: *u64,
    last_seq: *u64,
) Error!void {
    if (bytes.len < manifest_magic.len or !std.mem.eql(u8, bytes[0..manifest_magic.len], manifest_magic)) {
        return error.Corrupt;
    }
    var pos: usize = manifest_magic.len;
    while (pos < bytes.len) {
        if (bytes.len - pos < 8) break; // torn header
        const crc = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        const len = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        const end = pos + 8 + @as(usize, len);
        if (end > bytes.len) break; // torn payload
        const payload = bytes[pos + 8 .. end];
        if (Crc.hash(payload) != crc) {
            if (end == bytes.len) break; // torn: the last record is partial garbage
            return error.Corrupt; // damage with acknowledged records after it
        }
        var e = try decodeEdit(gpa, payload);
        defer e.deinit(gpa);
        if (e.log_number) |n| log_number.* = @max(log_number.*, n);
        if (e.next_file_no) |n| next_file_no.* = @max(next_file_no.*, n);
        if (e.last_seq) |n| last_seq.* = @max(last_seq.*, n);
        for (e.deleted.items) |d| {
            const have = live.get(d.file_no) orelse return error.Corrupt;
            if (have != d.level) return error.Corrupt;
            _ = live.remove(d.file_no);
        }
        for (e.added.items) |a| {
            const gop = try live.getOrPut(gpa, a.file_no);
            if (gop.found_existing) return error.Corrupt;
            gop.value_ptr.* = a.level;
        }
        pos = end;
    }
}

fn parseWalName(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, "wal-") or !std.mem.endsWith(u8, name, ".log")) return null;
    return std.fmt.parseInt(u64, name[4 .. name.len - 4], 10) catch null;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "edit encoding round-trips" {
    var e: VersionEdit = .{ .log_number = 7, .next_file_no = 99, .last_seq = 12345 };
    defer e.deinit(testing.allocator);
    try e.added.append(testing.allocator, .{ .level = 0, .file_no = 3 });
    try e.added.append(testing.allocator, .{ .level = 2, .file_no = 4 });
    try e.deleted.append(testing.allocator, .{ .level = 1, .file_no = 5 });
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try e.encode(&buf, testing.allocator);

    const len = std.mem.readInt(u32, buf.items[4..8], .little);
    try testing.expectEqual(buf.items.len - 8, len);
    var d = try decodeEdit(testing.allocator, buf.items[8..]);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 7), d.log_number);
    try testing.expectEqual(@as(?u64, 99), d.next_file_no);
    try testing.expectEqual(@as(?u64, 12345), d.last_seq);
    try testing.expectEqual(@as(usize, 2), d.added.items.len);
    try testing.expectEqual(@as(u16, 2), d.added.items[1].level);
    try testing.expectEqual(@as(u64, 5), d.deleted.items[0].file_no);
}

test "decoding rejects every truncation and unknown tags" {
    var e: VersionEdit = .{ .log_number = 7, .last_seq = 1 };
    defer e.deinit(testing.allocator);
    try e.added.append(testing.allocator, .{ .level = 3, .file_no = 3 });
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try e.encode(&buf, testing.allocator);
    const payload = buf.items[8..];
    for (1..payload.len) |cut| {
        // A cut inside a field fails; a cut on a field boundary is a valid
        // shorter edit. Either way nothing may crash or read out of bounds.
        if (decodeEdit(testing.allocator, payload[0..cut])) |ok| {
            var d = ok;
            d.deinit(testing.allocator);
        } else |err| try testing.expectEqual(error.Corrupt, err);
    }
    try testing.expectError(error.Corrupt, decodeEdit(testing.allocator, &.{ 9, 0 }));
    // level out of range
    try testing.expectError(error.Corrupt, decodeEdit(testing.allocator, &.{ tag_add, 200, 0, 1, 0, 0, 0, 0, 0, 0, 0 }));
}
