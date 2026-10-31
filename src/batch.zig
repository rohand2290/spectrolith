//! A write batch: an ordered list of edge operations applied atomically.
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

pub const OpKind = enum(u8) { put = 1, del = 2 };

pub const Op = struct {
    kind: OpKind,
    src: u64,
    dst: u64,
    weight: f32,
};

/// One WAL record is limited to this many bytes, which bounds the memory a
/// corrupt length field can make recovery allocate.
pub const max_record_bytes: usize = 64 << 20;
pub const op_wire_bytes = 1 + 8 + 8 + 4;
pub const record_overhead = 1 + 8 + 4; // type, first_seq, count
pub const max_ops: usize = (max_record_bytes - record_overhead) / op_wire_bytes;

pub const Batch = struct {
    ops: std.ArrayList(Op) = .empty,

    pub fn deinit(b: *Batch, gpa: Allocator) void {
        b.ops.deinit(gpa);
    }

    pub fn clear(b: *Batch) void {
        b.ops.clearRetainingCapacity();
    }

    pub fn put(b: *Batch, gpa: Allocator, src: u64, dst: u64, weight: f32) Allocator.Error!void {
        try b.ops.append(gpa, .{ .kind = .put, .src = src, .dst = dst, .weight = weight });
    }

    pub fn del(b: *Batch, gpa: Allocator, src: u64, dst: u64) Allocator.Error!void {
        try b.ops.append(gpa, .{ .kind = .del, .src = src, .dst = dst, .weight = 0 });
    }

    pub fn len(b: *const Batch) usize {
        return b.ops.items.len;
    }
};

/// Reject what the store cannot represent. NaN and infinite weights would
/// poison every later SpMV, so they stop here.
pub fn validate(ops: []const Op) types.Error!void {
    if (ops.len > max_ops) return error.InvalidArgument;
    for (ops) |op| {
        if (op.kind == .put and !std.math.isFinite(op.weight)) return error.InvalidArgument;
    }
}
