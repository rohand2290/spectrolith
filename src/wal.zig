//! Write-ahead log: one file, a header, then framed + checksummed batches.
//!
//!   file   = "SPLWAL01" record*
//!   record = crc32c u32 | len u32 | body[len]
//!   body   = type u8 | first_seq u64 | count u32 | op*count
//!   op     = kind u8 | src u64 | dst u64 | weight f32     (little-endian)
//!
//! The CRC covers the whole body. A record is acknowledged only after it has
//! been written (and, with sync_mode .every, flushed to stable storage).
const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const types = @import("types.zig");
const batch_mod = @import("batch.zig");
const Op = batch_mod.Op;
const Crc = std.hash.crc.@"CRC-32/ISCSI";

pub const header_magic = "SPLWAL01";
const record_batch: u8 = 1;

pub const Wal = struct {
    file: sys.File,
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Length of the durable-so-far log; used to roll back a failed append.
    size: u64,

    /// Create a fresh log: header written and synced, directory entry synced.
    pub fn create(gpa: Allocator, path: [*:0]const u8, dir: [*:0]const u8) types.Error!Wal {
        const f = try sys.File.open(path, .read_write_create);
        errdefer f.close();
        try f.truncate(0);
        try f.writeAll(header_magic);
        try f.sync();
        try sys.syncDir(dir); // otherwise a crash can lose the file's directory entry
        // Reopen for append so every write lands at the end.
        f.close();
        const af = try sys.File.open(path, .append);
        return .{ .file = af, .gpa = gpa, .size = header_magic.len };
    }

    /// Continue an existing log after recovery. `valid_len` is the length of
    /// the verified prefix; anything after it (a torn tail) is cut off first.
    pub fn openExisting(gpa: Allocator, path: [*:0]const u8, valid_len: u64) types.Error!Wal {
        {
            const f = try sys.File.open(path, .read_write_create);
            defer f.close();
            if (try f.size() != valid_len) {
                try f.truncate(valid_len);
                try f.sync();
            }
        }
        const af = try sys.File.open(path, .append);
        return .{ .file = af, .gpa = gpa, .size = valid_len };
    }

    pub fn close(w: *Wal) void {
        w.file.close();
        w.buf.deinit(w.gpa);
    }

    pub fn append(w: *Wal, first_seq: u64, ops: []const Op) types.Error!void {
        try encodeRecord(&w.buf, w.gpa, first_seq, ops);
        w.file.writeAll(w.buf.items) catch |err| {
            // A short write leaves half a record at the tail. Cut it off so
            // later records are not hidden behind garbage. If even that fails
            // the caller poisons the database.
            w.file.truncate(w.size) catch {};
            return err;
        };
        w.size += w.buf.items.len;
    }

    pub fn sync(w: *Wal) types.Error!void {
        try w.file.sync();
    }
};

pub fn encodeRecord(buf: *std.ArrayList(u8), gpa: Allocator, first_seq: u64, ops: []const Op) Allocator.Error!void {
    buf.clearRetainingCapacity();
    try buf.ensureTotalCapacity(gpa, 8 + batch_mod.record_overhead + ops.len * batch_mod.op_wire_bytes);
    buf.appendNTimesAssumeCapacity(0, 8); // crc + len, filled below
    buf.appendAssumeCapacity(record_batch);
    appendInt(buf, u64, first_seq);
    appendInt(buf, u32, @intCast(ops.len));
    for (ops) |op| {
        buf.appendAssumeCapacity(@intFromEnum(op.kind));
        appendInt(buf, u64, op.src);
        appendInt(buf, u64, op.dst);
        appendInt(buf, u32, @bitCast(op.weight));
    }
    const body = buf.items[8..];
    std.mem.writeInt(u32, buf.items[0..4], Crc.hash(body), .little);
    std.mem.writeInt(u32, buf.items[4..8], @intCast(body.len), .little);
}

fn appendInt(buf: *std.ArrayList(u8), comptime T: type, v: T) void {
    var tmp: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &tmp, v, .little);
    buf.appendSliceAssumeCapacity(&tmp);
}

pub const ReplayResult = struct {
    /// Bytes of the file that verified; everything after is a torn tail.
    valid_len: u64,
    /// Highest sequence number replayed (0 if the log was empty).
    last_seq: u64,
    batches: u64,
    torn_tail: bool,
};

/// Decode `bytes` (a whole log file) and call `sink.applyReplay(first_seq, ops)`
/// for each intact record.
///
/// A damaged record is a *torn tail* when it is the last thing in the file
/// (it runs to or past the end, or the rest of the file is zero fill): a crash
/// during an append produces exactly that, and the tail is discarded. A
/// damaged record with more data after it is corruption of acknowledged
/// writes, so recovery fails instead of silently dropping them.
pub fn replay(gpa: Allocator, bytes: []const u8, sink: anytype) types.Error!ReplayResult {
    var res: ReplayResult = .{ .valid_len = 0, .last_seq = 0, .batches = 0, .torn_tail = false };

    if (bytes.len < header_magic.len) {
        // Crashed while creating the file; Db treats this as an empty log.
        if (std.mem.startsWith(u8, header_magic, bytes)) return .{ .valid_len = 0, .last_seq = 0, .batches = 0, .torn_tail = bytes.len > 0 };
        return error.Corrupt;
    }
    if (!std.mem.eql(u8, bytes[0..header_magic.len], header_magic)) return error.Corrupt;

    var ops: std.ArrayList(Op) = .empty;
    defer ops.deinit(gpa);

    var off: usize = header_magic.len;
    res.valid_len = off;
    while (off < bytes.len) {
        const rest = bytes.len - off;
        const torn = struct {
            fn tail(r: *ReplayResult) ReplayResult {
                r.torn_tail = true;
                return r.*;
            }
        };
        if (rest < 8) return torn.tail(&res);
        const crc = std.mem.readInt(u32, bytes[off..][0..4], .little);
        const len: usize = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little);

        if (len < batch_mod.record_overhead or len > batch_mod.max_record_bytes) {
            // Garbage length. Only zero fill after a crash is excusable.
            if (std.mem.allEqual(u8, bytes[off..], 0)) return torn.tail(&res);
            return error.Corrupt;
        }
        const end = off + 8 + len;
        if (end > bytes.len) return torn.tail(&res); // record cut short
        const body = bytes[off + 8 .. end];
        if (Crc.hash(body) != crc) {
            if (end == bytes.len) return torn.tail(&res); // last record, half-written
            return error.Corrupt;
        }

        // The CRC matched, so a structural error now is a bug or a bad writer.
        if (body[0] != record_batch) return error.Corrupt;
        const first_seq = std.mem.readInt(u64, body[1..9], .little);
        const count: usize = std.mem.readInt(u32, body[9..13], .little);
        if ((body.len - batch_mod.record_overhead) != count * batch_mod.op_wire_bytes) return error.Corrupt;
        if (count == 0 or first_seq == 0) return error.Corrupt;
        // The next sequence number after this batch must exist too.
        const next_seq = std.math.add(u64, first_seq, count) catch return error.Corrupt;
        if (res.last_seq != 0 and first_seq != res.last_seq + 1) return error.Corrupt; // gap or overlap

        ops.clearRetainingCapacity();
        try ops.ensureTotalCapacity(gpa, count);
        var p: usize = batch_mod.record_overhead;
        for (0..count) |_| {
            const kind: batch_mod.OpKind = switch (body[p]) {
                1 => .put,
                2 => .del,
                else => return error.Corrupt,
            };
            ops.appendAssumeCapacity(.{
                .kind = kind,
                .src = std.mem.readInt(u64, body[p + 1 ..][0..8], .little),
                .dst = std.mem.readInt(u64, body[p + 9 ..][0..8], .little),
                .weight = @bitCast(std.mem.readInt(u32, body[p + 17 ..][0..4], .little)),
            });
            p += batch_mod.op_wire_bytes;
        }
        try sink.applyReplay(first_seq, ops.items);

        res.last_seq = next_seq - 1;
        res.batches += 1;
        off = end;
        res.valid_len = off;
    }
    return res;
}

// ---- tests ----------------------------------------------------------------

const Collect = struct {
    gpa: Allocator,
    seqs: std.ArrayList(u64) = .empty,
    ops: std.ArrayList(Op) = .empty,
    fn deinit(c: *Collect) void {
        c.seqs.deinit(c.gpa);
        c.ops.deinit(c.gpa);
    }
    pub fn applyReplay(c: *Collect, first_seq: u64, ops: []const Op) !void {
        try c.seqs.append(c.gpa, first_seq);
        try c.ops.appendSlice(c.gpa, ops);
    }
};

fn buildLog(gpa: Allocator, out: *std.ArrayList(u8), n_batches: usize, rec_ends: *std.ArrayList(usize)) !void {
    var rec: std.ArrayList(u8) = .empty;
    defer rec.deinit(gpa);
    try out.appendSlice(gpa, header_magic);
    var seq: u64 = 1;
    for (0..n_batches) |i| {
        const ops = [_]Op{
            .{ .kind = .put, .src = i, .dst = i + 100, .weight = 0.5 },
            .{ .kind = .del, .src = i + 1, .dst = i + 2, .weight = 0 },
        };
        try encodeRecord(&rec, gpa, seq, &ops);
        try out.appendSlice(gpa, rec.items);
        try rec_ends.append(gpa, out.items.len);
        seq += ops.len;
    }
}

test "a record whose sequence numbers run off the end of u64 is refused" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var rb: std.ArrayList(u8) = .empty;
    defer rb.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, header_magic);
    const ops = [_]Op{.{ .kind = .put, .src = 1, .dst = 2, .weight = 1 }};
    try encodeRecord(&rb, std.testing.allocator, std.math.maxInt(u64), &ops); // CRC is valid
    try buf.appendSlice(std.testing.allocator, rb.items);
    var sink: Collect = .{ .gpa = std.testing.allocator };
    defer sink.deinit();
    try std.testing.expectError(error.Corrupt, replay(std.testing.allocator, buf.items, &sink));
    try std.testing.expectEqual(@as(usize, 0), sink.ops.items.len);
}

test "wal: round trip" {
    const gpa = std.testing.allocator;
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(gpa);
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(gpa);
    try buildLog(gpa, &log, 5, &ends);

    var sink: Collect = .{ .gpa = gpa };
    defer sink.deinit();
    const res = try replay(gpa, log.items, &sink);
    try std.testing.expectEqual(@as(u64, 10), res.last_seq);
    try std.testing.expectEqual(@as(u64, 5), res.batches);
    try std.testing.expectEqual(@as(u64, log.items.len), res.valid_len);
    try std.testing.expect(!res.torn_tail);
    try std.testing.expectEqual(@as(usize, 10), sink.ops.items.len);
    try std.testing.expectEqual(@as(f32, 0.5), sink.ops.items[0].weight);
    try std.testing.expectEqual(batch_mod.OpKind.del, sink.ops.items[1].kind);
}

test "wal: truncation at every byte recovers exactly the whole records" {
    const gpa = std.testing.allocator;
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(gpa);
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(gpa);
    try buildLog(gpa, &log, 4, &ends);

    for (header_magic.len..log.items.len + 1) |cut| {
        var sink: Collect = .{ .gpa = gpa };
        defer sink.deinit();
        const res = try replay(gpa, log.items[0..cut], &sink);
        var whole: u64 = 0;
        var valid: usize = header_magic.len;
        for (ends.items) |e| if (e <= cut) {
            whole += 1;
            valid = e;
        };
        try std.testing.expectEqual(whole, res.batches);
        try std.testing.expectEqual(@as(u64, valid), res.valid_len);
        try std.testing.expectEqual(cut != valid, res.torn_tail);
    }
}

test "wal: bad CRC on the last record is a torn tail, in the middle is corruption" {
    const gpa = std.testing.allocator;
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(gpa);
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(gpa);
    try buildLog(gpa, &log, 3, &ends);

    // Flip a bit inside the last record: torn tail, first two records survive.
    {
        const copy = try gpa.dupe(u8, log.items);
        defer gpa.free(copy);
        copy[ends.items[2] - 3] ^= 0x10;
        var sink: Collect = .{ .gpa = gpa };
        defer sink.deinit();
        const res = try replay(gpa, copy, &sink);
        try std.testing.expectEqual(@as(u64, 2), res.batches);
        try std.testing.expect(res.torn_tail);
    }
    // Flip a bit inside the first record: acknowledged data is damaged.
    {
        const copy = try gpa.dupe(u8, log.items);
        defer gpa.free(copy);
        copy[ends.items[0] - 3] ^= 0x10;
        var sink: Collect = .{ .gpa = gpa };
        defer sink.deinit();
        try std.testing.expectError(error.Corrupt, replay(gpa, copy, &sink));
    }
}

test "wal: garbage input never crashes" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    var buf: [512]u8 = undefined;
    for (0..2000) |_| {
        r.bytes(&buf);
        const n = r.uintLessThan(usize, buf.len);
        if (r.boolean()) @memcpy(buf[0..header_magic.len], header_magic);
        var sink: Collect = .{ .gpa = gpa };
        defer sink.deinit();
        _ = replay(gpa, buf[0..n], &sink) catch {};
    }
}
