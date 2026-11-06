//! The benchmark baseline: RocksDB through its C API, with the key
//! `src:u64 BE | dst:u64 BE` and the weight as value, which is how most people
//! would store a graph in a key-value store.
//!
//! Tuned to be a fair opponent rather than a default one: the same memtable,
//! level and file sizes as Spectrolith, the same number of background threads,
//! no compression (Spectrolith has none), a 10-bit bloom filter over the 8-byte
//! source prefix so a neighbor scan can skip files, and a 1 GiB block cache.
const std = @import("std");
const c = @import("rocksdb_c");

pub const Rocks = struct {
    gpa: std.mem.Allocator,
    db: *c.rocksdb_t,
    opts: *c.rocksdb_options_t,
    wopts: *c.rocksdb_writeoptions_t,
    ropts: *c.rocksdb_readoptions_t,
    batch: *c.rocksdb_writebatch_t,

    fn check(err: ?[*:0]u8) !void {
        if (err) |e| {
            std.debug.print("rocksdb: {s}\n", .{e});
            c.rocksdb_free(e);
            return error.RocksDb;
        }
    }

    pub fn open(gpa: std.mem.Allocator, path: []const u8, sync: bool) !Rocks {
        const o = c.rocksdb_options_create().?;
        c.rocksdb_options_set_create_if_missing(o, 1);
        c.rocksdb_options_set_compression(o, c.rocksdb_no_compression);
        c.rocksdb_options_set_write_buffer_size(o, 64 << 20);
        c.rocksdb_options_set_max_write_buffer_number(o, 2);
        c.rocksdb_options_set_level0_file_num_compaction_trigger(o, 4);
        c.rocksdb_options_set_level0_slowdown_writes_trigger(o, 8);
        c.rocksdb_options_set_level0_stop_writes_trigger(o, 12);
        c.rocksdb_options_set_target_file_size_base(o, 64 << 20);
        c.rocksdb_options_set_max_bytes_for_level_base(o, 256 << 20);
        c.rocksdb_options_set_max_bytes_for_level_multiplier(o, 10);
        c.rocksdb_options_set_max_background_jobs(o, 2); // one flush, one compaction
        c.rocksdb_options_enable_statistics(o);
        c.rocksdb_options_set_prefix_extractor(o, c.rocksdb_slicetransform_create_fixed_prefix(8));

        const t = c.rocksdb_block_based_options_create().?;
        c.rocksdb_block_based_options_set_filter_policy(t, c.rocksdb_filterpolicy_create_bloom(10));
        c.rocksdb_block_based_options_set_block_cache(t, c.rocksdb_cache_create_lru(1 << 30));
        c.rocksdb_options_set_block_based_table_factory(o, t);

        const z = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(z);
        var err: ?[*:0]u8 = null;
        const db = c.rocksdb_open(o, z, @ptrCast(&err));
        try check(err);

        const w = c.rocksdb_writeoptions_create().?;
        c.rocksdb_writeoptions_set_sync(w, @intFromBool(sync));
        return .{
            .gpa = gpa,
            .db = db.?,
            .opts = o,
            .wopts = w,
            .ropts = c.rocksdb_readoptions_create().?,
            .batch = c.rocksdb_writebatch_create().?,
        };
    }

    pub fn close(r: *Rocks) void {
        c.rocksdb_writebatch_destroy(r.batch);
        c.rocksdb_readoptions_destroy(r.ropts);
        c.rocksdb_writeoptions_destroy(r.wopts);
        c.rocksdb_close(r.db);
        c.rocksdb_options_destroy(r.opts);
    }

    fn key(src: u64, dst: u64) [16]u8 {
        var k: [16]u8 = undefined;
        std.mem.writeInt(u64, k[0..8], src, .big);
        std.mem.writeInt(u64, k[8..16], dst, .big);
        return k;
    }

    /// Both directions in one atomic batch, as Spectrolith stores them.
    pub fn put(r: *Rocks, u: u64, v: u64, w: f32) !void {
        c.rocksdb_writebatch_clear(r.batch);
        const val = std.mem.toBytes(w);
        const a = key(u, v);
        c.rocksdb_writebatch_put(r.batch, &a, a.len, &val, val.len);
        if (u != v) {
            const b = key(v, u);
            c.rocksdb_writebatch_put(r.batch, &b, b.len, &val, val.len);
        }
        var err: ?[*:0]u8 = null;
        c.rocksdb_write(r.db, r.wopts, r.batch, @ptrCast(&err));
        try check(err);
    }

    /// Sum of neighbor weights. The iterator pins a consistent view, the
    /// counterpart of Spectrolith's snapshot.
    pub fn scan(r: *Rocks, v: u64) !f64 {
        var lo: [8]u8 = undefined;
        std.mem.writeInt(u64, &lo, v, .big);
        var hi: [8]u8 = undefined;
        std.mem.writeInt(u64, &hi, v +% 1, .big);
        c.rocksdb_readoptions_set_iterate_upper_bound(r.ropts, &hi, hi.len);
        const it = c.rocksdb_create_iterator(r.db, r.ropts).?;
        defer c.rocksdb_iter_destroy(it);
        var sum: f64 = 0;
        c.rocksdb_iter_seek(it, &lo, lo.len);
        while (c.rocksdb_iter_valid(it) != 0) : (c.rocksdb_iter_next(it)) {
            var n: usize = 0;
            const p = c.rocksdb_iter_value(it, &n);
            sum += std.mem.bytesToValue(f32, p[0..4]);
        }
        return sum;
    }

    fn property(r: *Rocks, name: [*:0]const u8) u64 {
        var out: u64 = 0;
        _ = c.rocksdb_property_int(r.db, name, &out);
        return out;
    }

    /// Flush and wait for compaction to run out of work.
    pub fn settle(r: *Rocks) !void {
        const fo = c.rocksdb_flushoptions_create().?;
        defer c.rocksdb_flushoptions_destroy(fo);
        var err: ?[*:0]u8 = null;
        c.rocksdb_flush(r.db, fo, @ptrCast(&err));
        try check(err);
        while (r.property("rocksdb.compaction-pending") != 0 or
            r.property("rocksdb.num-running-compactions") != 0 or
            r.property("rocksdb.num-running-flushes") != 0)
        {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 50_000_000 };
            _ = std.c.nanosleep(&ts, null);
        }
    }

    /// Value of a ticker, from the statistics dump. Tickers are not stable
    /// numbers across releases; their names are.
    fn ticker(dump: []const u8, name: []const u8) u64 {
        var lines = std.mem.tokenizeScalar(u8, dump, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, name)) continue;
            var f = std.mem.tokenizeAny(u8, line[name.len..], " ");
            if (!std.mem.eql(u8, f.next() orelse continue, "COUNT")) continue;
            _ = f.next(); // ":"
            return std.fmt.parseInt(u64, f.next() orelse return 0, 10) catch 0;
        }
        return 0;
    }

    pub const Written = struct { wal: u64, flush: u64, compaction: u64, stall_ns: u64 };

    pub fn written(r: *Rocks) Written {
        const p = c.rocksdb_options_statistics_get_string(r.opts);
        defer c.rocksdb_free(p);
        const dump = std.mem.span(p);
        return .{
            .wal = ticker(dump, "rocksdb.wal.bytes"),
            .flush = ticker(dump, "rocksdb.flush.write.bytes"),
            .compaction = ticker(dump, "rocksdb.compact.write.bytes"),
            .stall_ns = ticker(dump, "rocksdb.stall.micros") * 1000,
        };
    }
};
